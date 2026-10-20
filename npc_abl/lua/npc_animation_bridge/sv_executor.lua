local Lab = NPCAnimationBridge
if Lab.Executor then Lab.Executor.Shutdown() end

local Executor = {}
Lab.Executor = Executor
local active = {}
local activeCount = 0
local nextToken = 0
local closed = false
local methods = {
	"AddLayeredSequence", "IsValidLayer", "GetLayerSequence", "RemoveLayer",
	"SetLayerCycle", "SetLayerWeight", "SetLayerPlaybackRate",
	"SetLayerLooping", "SetLayerAutokill", "SetLayerBlendIn", "SetLayerBlendOut"
}

local function supportsOverlay(entity)
	for _, name in ipairs(methods) do
		if type(entity[name]) ~= "function" then return false end
	end
	return true
end

local function ownsLayer(handle)
	local entity = handle.entity
	return IsValid(entity) and entity:GetModel() == handle.model
		and entity:IsValidLayer(handle.layer)
		and entity:GetLayerSequence(handle.layer) == handle.sequence
end

local function cleanupLayer(handle)
	local ok, owned = pcall(ownsLayer, handle)
	if not ok then handle.cleanupError = tostring(owned):sub(1, 2048) return end
	if not owned then return end
	-- Continue to removal even if either blend write fails. Never remove a layer
	-- after another sequence or model has taken its place.
	for _, name in ipairs({"SetLayerBlendIn", "SetLayerBlendOut", "SetLayerWeight", "RemoveLayer"}) do
		local checked, stillOwned = pcall(ownsLayer, handle)
		if not checked then handle.cleanupError = tostring(stillOwned):sub(1, 2048) return end
		if not stillOwned then return end
		local succeeded, error
		if name == "RemoveLayer" then
			succeeded, error = pcall(handle.entity[name], handle.entity, handle.layer)
		else
			succeeded, error = pcall(handle.entity[name], handle.entity, handle.layer, 0)
		end
		if not succeeded then handle.cleanupError = tostring(error):sub(1, 2048) end
	end
end

local function finish(handle, reason)
	if active[handle.entity] ~= handle then return false, "not_owned" end
	active[handle.entity] = nil
	activeCount = activeCount - 1
	handle.reason = reason
	handle.finished = true
	cleanupLayer(handle)
	return true
end

function Executor.StartOverlay(entity, request)
	if closed then return nil, "module_shutting_down" end
	local clip, reason = Lab.Catalog.Resolve(entity, request)
	if not clip then return nil, reason end
	local controlledSeconds
	local compositionSeconds
	if request.composition==true then
		local owned
		if Lab.Layers then owned,compositionSeconds=Lab.Layers.CanStartOverlay(entity,clip,request.compositionContext) end
		if not owned then return nil,"base_layer_not_owned" end
		if not Lab.Catalog.IsFinite(compositionSeconds) or compositionSeconds<.1 or compositionSeconds>30 then return nil,"invalid_options" end
	end
	if request.controlled == true then
		local owned
		if request.preview == true and Lab.Preview and Lab.Preview.CanStartControlledOverlay then
			owned, controlledSeconds = Lab.Preview.CanStartControlledOverlay(entity, clip)
		end
		if not owned then return nil, "controller_preview_not_owned" end
		if not Lab.Catalog.IsFinite(controlledSeconds) or controlledSeconds < .1 or controlledSeconds > 30 then
			return nil, "invalid_controller_duration"
		end
		local base=Lab.Catalog.BaseReason(clip)
		if base then return nil,base end
	end
	if request.preview == true then
		local failure = Lab.Catalog.PreviewReason(clip)
		if failure and not controlledSeconds then return nil, failure end
	end
	if not clip.gesture and not compositionSeconds and not (request.preview == true and entity.NABPreviewActive ~= nil) then
		return nil, "gesture_activity_required"
	end
	if not supportsOverlay(entity) then return nil, "server_overlay_unavailable" end
	if active[entity] then return nil, "actor_busy" end
	if activeCount >= 64 then return nil, "capacity_reached" end
	local cycle = request.cycle or 0
	local weight = request.weight or 1
	local rate = request.rate or 1
	local priority = request.priority or 0
	local blendIn = request.blendIn or 0
	local blendOut = request.blendOut or 0
	if not Lab.Catalog.IsFinite(cycle) or cycle < 0 or cycle >= 1
		or not Lab.Catalog.IsFinite(weight) or weight < 0 or weight > 1
		or not Lab.Catalog.IsFinite(rate) or rate < 0.1 or rate > 4
		or not Lab.Catalog.IsFinite(priority) or priority < 0 or priority > 15 or priority % 1 ~= 0
		or not Lab.Catalog.IsFinite(blendIn) or blendIn < 0 or blendIn > 2
		or not Lab.Catalog.IsFinite(blendOut) or blendOut < 0 or blendOut > 2 then
		return nil, "invalid_options"
	end
	if not controlledSeconds and not compositionSeconds and (not Lab.Catalog.IsFinite(clip.duration) or clip.duration <= 0) then
		return nil, "duration_unavailable"
	end
	local duration = controlledSeconds or compositionSeconds or clip.duration * (1 - cycle) / rate
	if duration > 30 then return nil, "duration_limit" end
	nextToken = nextToken + 1
	local handle = {
		token = nextToken,
		entity = entity,
		model = clip.model,
		sequence = clip.sequence,
		label = clip.label,
		startedAt = CurTime(),
		expiresAt = CurTime() + duration,
		weight = weight, currentWeight = blendIn > 0 and 0 or weight,
		blendIn = math.min(blendIn, duration / 2), blendOut = math.min(blendOut, duration / 2),
		finished = false
	}
	-- Reserve ownership before engine writes so a reentrant start cannot allocate
	-- a second layer on this actor while initialization is still in progress.
	active[entity] = handle
	activeCount = activeCount + 1
	local wrote, writeError = pcall(function()
		local layer = entity:AddLayeredSequence(clip.sequence, priority)
		if not Lab.Catalog.IsFinite(layer) or layer < 0 or layer % 1 ~= 0 then return end
		handle.layer = layer
		if not entity:IsValidLayer(layer) then return end
		if handle.finished or closed then return end
		entity:SetLayerAutokill(layer, false)
		entity:SetLayerLooping(layer, false)
		entity:SetLayerCycle(layer, cycle)
		entity:SetLayerBlendIn(layer, 0)
		entity:SetLayerBlendOut(layer, 0)
		entity:SetLayerWeight(layer, blendIn > 0 and 0 or weight)
		entity:SetLayerPlaybackRate(layer, rate)
		handle.initialized = true
	end)
	if not wrote or not handle.initialized or active[entity] ~= handle then
		if active[entity] == handle then
			finish(handle, not wrote and "overlay_write_failed" or "layer_creation_failed")
		elseif handle.layer ~= nil then cleanupLayer(handle) end
		if not wrote then
			return nil, "overlay_write_failed", {writeError = tostring(writeError):sub(1,2048), cleanupError = handle.cleanupError}
		end
		return nil, "layer_creation_failed"
	end
	return handle
end

function Executor.FadeOut(handle, seconds)
	if type(handle) ~= "table" or active[handle.entity] ~= handle then return false, "not_owned" end
	if not Lab.Catalog.IsFinite(seconds) or seconds < 0 or seconds > 2 then return false, "invalid_blend" end
	if seconds == 0 then return finish(handle, "cancelled") end
	if not handle.stopAt then
		handle.stopStarted = CurTime()
		handle.stopAt = math.min(handle.expiresAt, CurTime() + seconds)
		handle.stopWeight = handle.currentWeight
	end
	return true
end

local function ease(value)
	value = math.max(0, math.min(1, value))
	return value * value * (3 - 2 * value)
end

function Executor.Cancel(handle)
	if type(handle) ~= "table" then return false, "invalid_handle" end
	return finish(handle, "cancelled")
end

function Executor.Update()
	for entity, handle in pairs(active) do
		local ok, error = pcall(function()
		if not IsValid(entity) then
			finish(handle, "entity_removed")
		elseif entity:GetModel() ~= handle.model then
			finish(handle, "model_changed")
		elseif type(entity.Health) == "function" and entity:Health() <= 0 then
			finish(handle, "actor_dead")
		elseif not ownsLayer(handle) then
			finish(handle, "layer_lost")
		elseif CurTime() >= (handle.stopAt or handle.expiresAt) then
			finish(handle, handle.stopAt and "cancelled" or "completed")
		else
			local now = CurTime()
			local incoming = handle.blendIn > 0 and ease((now - handle.startedAt) / handle.blendIn) or 1
			local outgoing = handle.blendOut > 0 and ease((handle.expiresAt - now) / handle.blendOut) or 1
			local weight = handle.weight * math.min(incoming, outgoing)
			if handle.stopAt then
				weight = math.min(weight, handle.stopWeight * ease((handle.stopAt - now) / (handle.stopAt - handle.stopStarted)))
			end
			handle.currentWeight = weight
			entity:SetLayerWeight(handle.layer, weight)
		end
		end)
		if not ok then
			handle.writeError = tostring(error):sub(1,2048)
			finish(handle, "overlay_update_failed")
		end
	end
end

function Executor.GetActiveCount()
	return activeCount
end

function Executor.IsHandleOwned(handle)
	if type(handle) ~= "table" or active[handle.entity] ~= handle then return false end
	local ok, owned = pcall(ownsLayer, handle)
	return ok and owned == true
end

-- Detached observation only: callers never receive the mutable playback handle.
function Executor.GetStatus(entity)
	local handle = active[entity]
	if not handle then return {schema = 1, active = false} end
	local ok, owned = pcall(ownsLayer, handle)
	return {schema = 1, active = true, valid = ok and owned or false,
		failure = not ok and "layer_query_failed" or nil,
		failureDetails = not ok and tostring(owned):sub(1,2048) or nil,
		model = handle.model, sequence = handle.sequence, label = handle.label,
		layer = handle.layer, weight = handle.currentWeight,
		blendIn = handle.blendIn, blendOut = handle.blendOut,
		stopping = handle.stopAt ~= nil,
		remaining = math.max(0, (handle.stopAt or handle.expiresAt) - CurTime())}
end

function Executor.Shutdown()
	closed = true
	for _, handle in pairs(active) do finish(handle, "shutdown") end
	hook.Remove("Think", "NPCAnimationBridge.Executor")
	hook.Remove("EntityRemoved", "NPCAnimationBridge.Executor")
end

hook.Add("Think", "NPCAnimationBridge.Executor", Executor.Update)
hook.Add("EntityRemoved", "NPCAnimationBridge.Executor", function(entity)
	local handle = active[entity]
	if handle then finish(handle, "entity_removed") end
end)
