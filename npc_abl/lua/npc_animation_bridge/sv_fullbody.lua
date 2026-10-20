local Lab = NPCAnimationBridge
if Lab.FullBody then Lab.FullBody.Shutdown() end

local FullBody = {}
Lab.FullBody = FullBody
local active = {}
local count = 0
local closing = false

local function rememberInputs(handle, poses)
	handle.poseOriginals, handle.poseApplied = handle.poseOriginals or {}, handle.poseApplied or {}
	for name in pairs(poses) do
		if handle.poseOriginals[name] == nil then
			local value = handle.entity:GetPoseParameter(name)
			if not Lab.Catalog.IsFinite(value) or math.abs(value) > 1000000 then error("pose_snapshot_unavailable") end
			handle.poseOriginals[name] = value
		end
	end
end

local function applyInputs(handle, poses)
	for name, value in pairs(poses) do
		handle.entity:SetPoseParameter(name, value)
		handle.poseApplied[name] = handle.entity:GetPoseParameter(name)
	end
	if next(poses) and type(handle.entity.InvalidateBoneCache) == "function" then handle.entity:InvalidateBoneCache() end
end

local function current(handle)
	if type(handle) ~= "table" or active[handle.entity] ~= handle then
		return false, "not_owned"
	end
	local entity = handle.entity
	if not IsValid(entity) then return false, "entity_removed" end
	if entity:Health() <= 0 then return false, "actor_dead" end
	if entity:GetModel() ~= handle.model then return false, "model_changed" end
	if handle.clip and entity:GetSequence() ~= handle.clip.sequence then
		return false, "sequence_preempted"
	end
	return true
end

function FullBody.Release(handle, reason)
	if type(handle) ~= "table" or active[handle.entity] ~= handle then
		return false, "not_owned"
	end
	active[handle.entity] = nil
	if Lab.Layers then Lab.Layers.StopForBase(handle,"base_released") end
	count = count - 1
	handle.finished = true
	handle.reason = reason or "cancelled"
	local entity = handle.entity
	if IsValid(entity) and entity:GetModel() == handle.model
		and (not handle.clip or entity:GetSequence() == handle.clip.sequence) then
		local restored, restoreError = pcall(function()
			local changed = false
			for name, value in pairs(handle.poseOriginals or {}) do
				local applied = handle.poseApplied[name]
				local currentValue = entity:GetPoseParameter(name)
				if applied and Lab.Catalog.IsFinite(currentValue) and math.abs(currentValue-applied) < .0001 then
					entity:SetPoseParameter(name,value); changed=true
				end
			end
			if changed and type(entity.InvalidateBoneCache) == "function" then entity:InvalidateBoneCache() end
		end)
		if not restored then handle.restoreError=tostring(restoreError):sub(1,2048) end
	end
	if Lab.PoseSync then Lab.PoseSync.Stop(handle) end
	if handle.onRelease then
		local ok, error = pcall(handle.onRelease, handle, handle.reason)
		if not ok then handle.callbackError = tostring(error):sub(1, 2048) end
	end
	return true
end

function FullBody.Acquire(entity, owner, onRelease)
	if closing then return nil, "module_shutting_down" end
	if not Lab.Catalog.IsActor(entity) or not entity:IsNextBot() then
		return nil, "nextbot_owner_required"
	end
	if type(owner) ~= "table" or (onRelease ~= nil and type(onRelease) ~= "function") then
		return nil, "invalid_owner"
	end
	if entity:Health() <= 0 then return nil, "actor_dead" end
	if active[entity] then return nil, "actor_busy" end
	if count >= 64 then return nil, "capacity_reached" end
	for _, name in ipairs({"ResetSequence", "SetCycle", "GetCycle", "SetPlaybackRate", "FrameAdvance"}) do
		if type(entity[name]) ~= "function" then return nil, "fullbody_unavailable" end
	end
	local handle = {entity = entity, model = entity:GetModel(), owner = owner,
		onRelease = onRelease, lastUpdate = CurTime(), changes = 0, advances = 0}
	active[entity] = handle
	count = count + 1
	return handle
end

function FullBody.Play(handle, request)
	local valid, reason = current(handle)
	if not valid then
		if reason ~= "not_owned" then FullBody.Release(handle, reason) end
		return nil, reason
	end
	local clip, failure, contract
	if type(request) == "table" and request.controller ~= nil then
		contract, failure = Lab.Controllers.ResolveSequence(handle.entity, request)
		if contract then clip = contract.clip end
	else
		clip, failure = Lab.Catalog.Resolve(handle.entity, request)
	end
	if not clip then return nil, failure end
	if clip.gesture or Lab.Catalog.BaseReason(clip) then
		return nil, "absolute_sequence_required"
	end
	local rate = request.rate or 1
	local cycle = request.cycle or 0
	if not Lab.Catalog.IsFinite(rate) or rate < 0 or rate > 4
		or not Lab.Catalog.IsFinite(cycle) or cycle < 0 or cycle >= 1 then
		return nil, "invalid_options"
	end
	local entity = handle.entity
	local inputs, inputFailure
	if contract then
		inputs = contract.inputs
	else
		inputs, inputFailure = Lab.Controllers.Resolve(entity, request)
	end
	if not inputs then return nil, inputFailure end
	local poses = inputs.poses
	local wrote, writeError = pcall(function()
	rememberInputs(handle, poses)
	if not handle.clip or handle.clip.sequence ~= clip.sequence or request.restart == true then
		if Lab.Layers then Lab.Layers.StopForBase(handle,"base_sequence_changed") end
		local previous = handle.clip
		if request.keepPhase == true and previous and previous.flags % 2 == 1 and clip.flags % 2 == 1 then
			cycle = math.max(0, math.min(entity:GetCycle(), 0.999999))
		end
		entity:ResetSequence(clip.sequence)
		entity:SetCycle(cycle)
		handle.changes = handle.changes + 1
	end
	entity:SetPlaybackRate(rate)
	applyInputs(handle, poses)
	end)
	if not wrote then
		handle.writeError = tostring(writeError):sub(1, 2048)
		FullBody.Release(handle, "playback_write_failed")
		return nil, "playback_write_failed"
	end
	handle.inputUpdates = (handle.inputUpdates or 0) + 1
	handle.clip = clip
	handle.controller = contract and contract.controller or nil
	handle.rate = rate
	handle.lastUpdate = CurTime()
	if Lab.PoseSync then
		local synced, syncReason = Lab.PoseSync.Publish(handle, poses)
		if not synced then FullBody.Release(handle, syncReason) return nil, syncReason end
	end
	return clip
end

-- Cooperating owner can change blend/aim inputs without resetting sequence or
-- advancing animation time. Movement projection never moves or turns the actor.
function FullBody.UpdateInputs(handle, request)
	local valid, reason = current(handle)
	if not valid then
		if reason ~= "not_owned" then FullBody.Release(handle, reason) end
		return nil, reason
	end
	if not handle.clip then return nil, "sequence_required" end
	local inputs, failure
	if handle.controller then
		if type(request) ~= "table" then return nil, "invalid_poses" end
		local contract
		contract, failure = Lab.Controllers.ResolveSequence(handle.entity, {
			sequence=handle.clip.label, controller=handle.controller, poses=request.poses, movement=request.movement
		})
		if contract then inputs=contract.inputs end
	else
		inputs, failure = Lab.Controllers.Resolve(handle.entity, request)
	end
	if not inputs then return nil, failure end
	local wrote, writeError = pcall(function()
		rememberInputs(handle, inputs.poses)
		applyInputs(handle, inputs.poses)
	end)
	if not wrote then
		handle.writeError = tostring(writeError):sub(1, 2048)
		FullBody.Release(handle, "pose_write_failed")
		return nil, "pose_write_failed"
	end
	handle.lastUpdate = CurTime()
	handle.inputUpdates = (handle.inputUpdates or 0) + 1
	if Lab.PoseSync then
		local synced, syncReason = Lab.PoseSync.Publish(handle, inputs.poses)
		if not synced then FullBody.Release(handle, syncReason) return nil, syncReason end
	end
	return inputs
end

function FullBody.Jump(handle, request)
	local valid, reason = current(handle)
	if not valid then
		if reason ~= "not_owned" then FullBody.Release(handle, reason) end
		return nil, reason
	end
	local entity = handle.entity
	if entity.SCPhysgunHeld then return nil, "actor_held" end
	if not entity.loco or type(entity.loco.Jump) ~= "function"
		or type(entity.loco.IsOnGround) ~= "function" then return nil, "jump_unavailable" end
	if not entity.loco:IsOnGround() then return nil, "actor_airborne" end
	local clip, failure = FullBody.Play(handle, request)
	if not clip then return nil, failure end
	local playback = {}
	for name, value in pairs(request) do playback[name] = value end
	playback.restart, playback.keepPhase, playback.cycle = true, false, 0
	handle.clip = nil
	local succeeded = pcall(entity.loco.Jump, entity.loco)
	if not succeeded then
		FullBody.Release(handle, "native_jump_failed")
		return nil, "native_jump_failed"
	end
	clip, failure = FullBody.Play(handle, playback)
	if not clip then
		if not handle.finished then FullBody.Release(handle, failure) end
		return nil, failure
	end
	return clip
end

function FullBody.Advance(handle)
	local valid, reason = current(handle)
	if not valid then
		if reason ~= "not_owned" then FullBody.Release(handle, reason) end
		return false, reason
	end
	local tick = engine.TickCount()
	if handle.lastTick == tick then return false, "already_advanced" end
	local advanced, advanceError = pcall(handle.entity.FrameAdvance, handle.entity)
	if not advanced then
		handle.writeError = tostring(advanceError):sub(1, 2048)
		FullBody.Release(handle, "frame_advance_failed")
		return false, "frame_advance_failed"
	end
	handle.lastTick = tick
	handle.lastUpdate = CurTime()
	handle.advances = handle.advances + 1
	if Lab.Layers then
		local checked,synced,layerReason=pcall(Lab.Layers.SyncForBase,handle)
		if not checked or not synced then handle.layerFailure=not checked and "layer_update_failed" or layerReason end
	end
	return true
end

function FullBody.Update()
	for _, handle in pairs(active) do
		local valid, reason = current(handle)
		if valid and CurTime() - handle.lastUpdate > 1 then valid, reason = false, "owner_timeout" end
		if not valid then FullBody.Release(handle, reason) end
	end
	if Lab.PoseSync then Lab.PoseSync.Flush() end
end

function FullBody.GetActiveCount() return count end

function FullBody.IsOwned(entity) return active[entity] ~= nil end

function FullBody.IsHandleOwned(handle)
	return type(handle) == "table" and active[handle.entity] == handle and current(handle) == true
end

function FullBody.GetStatus(entity)
	local handle = active[entity]
	if not handle then return {schema = 1, active = false} end
	local valid, reason = current(handle)
	return {schema = 1, active = true, valid = valid, reason = reason,
		model = handle.model, sequence = handle.clip and handle.clip.sequence,
		rate = handle.rate, changes = handle.changes, advances = handle.advances,
		inputUpdates = handle.inputUpdates or 0,
		controllerBound = handle.controller ~= nil,
		layerFailure = handle.layerFailure,
		updateAge = math.max(0, CurTime() - handle.lastUpdate)}
end

function FullBody.Shutdown()
	closing = true
	for _, handle in pairs(active) do FullBody.Release(handle, "module_reload") end
	hook.Remove("Think", "NPCAnimationBridge.FullBodyLifecycle")
end

hook.Add("Think", "NPCAnimationBridge.FullBodyLifecycle", FullBody.Update)
