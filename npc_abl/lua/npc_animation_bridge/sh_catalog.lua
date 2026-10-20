NPCAnimationBridge = NPCAnimationBridge or {}
NPCAnimationBridge.API_VERSION = 1
local Catalog = {}
NPCAnimationBridge.Catalog = Catalog

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function Catalog.IsActor(entity)
	return IsValid(entity) and not entity:IsPlayer() and (entity:IsNPC() or entity:IsNextBot())
end

local function describeSequence(entity, sequence)
	local info = entity:GetSequenceInfo(sequence)
	if type(info) ~= "table" or type(info.label) ~= "string" then
		return nil, "sequence_metadata_unavailable"
	end
	return {
		model = entity:GetModel(), sequence = sequence, label = info.label,
		activity = info.activity, activityName = info.activityname or "",
		flags = info.flags or 0, numblends = info.numblends or 1,
		duration = entity:SequenceDuration(sequence),
		gesture = string.sub(info.activityname or "", 1, 12) == "ACT_GESTURE_"
	}
end

function Catalog.Resolve(entity, request)
	if not Catalog.IsActor(entity) then return nil, "unsupported_actor" end
	if type(request) ~= "table" then return nil, "invalid_request" end
	local sequence
	if type(request.sequence) == "string" and request.sequence ~= "" then
		sequence = entity:LookupSequence(request.sequence)
	elseif finite(request.activity) and request.activity >= 0 and request.activity % 1 == 0 then
		sequence = entity:SelectWeightedSequence(request.activity)
	else
		return nil, "sequence_or_activity_required"
	end
	if not finite(sequence) or sequence < 0 or sequence >= entity:GetSequenceCount() then
		return nil, "sequence_unavailable"
	end
	local clip, reason = describeSequence(entity, sequence)
	if not clip then return nil, reason end
	if request.activity ~= nil and (not finite(request.activity) or clip.activity ~= request.activity) then
		return nil, "activity_mismatch"
	end
	return clip
end

function Catalog.Describe(entity)
	if not Catalog.IsActor(entity) then return nil, "unsupported_actor" end
	local parameters = {}
	for _, name in ipairs({"move_x", "move_y", "move_yaw"}) do
		local parameter = entity:LookupPoseParameter(name)
		if finite(parameter) and parameter >= 0 then parameters[#parameters + 1] = name end
	end
	return {
		model = entity:GetModel(),
		class = entity:GetClass(),
		sequenceCount = entity:GetSequenceCount(),
		movementParameters = parameters,
		serverOverlay = SERVER and type(entity.AddLayeredSequence) == "function"
			and type(entity.RemoveLayer) == "function" or false
	}
end

Catalog.IsFinite = finite

function Catalog.BaseReason(info)
	if not info then return nil end
	local flags=info.flags or 0
	if not finite(flags) or flags<0 or flags>4294967295 or flags%1~=0 then return "invalid_sequence_metadata" end
	if math.floor(flags/4)%2==1 then return "additive_sequence_requires_base_motion" end
	if math.floor(flags/16384)%2==1 then return "world_sequence_requires_base_motion" end
	if math.floor(flags/512)%2==1 then return "local_sequence_requires_context" end
end

function Catalog.PreviewReason(info)
	local base=Catalog.BaseReason(info)
	if base then return base end
	-- STUDIO_CYCLEPOSE: cycle is supplied by a pose controller, not elapsed time.
	if info and (math.floor((info.flags or 0) / 128) % 2 == 1 or (info.numblends or 1) > 1) then
		return "pose_driven_sequence_requires_controller"
	end
end

local function timedPreview(clip, rate, cycle)
	local reason = Catalog.PreviewReason(clip)
	if reason then return nil, reason end
	if not finite(clip.duration) or clip.duration <= 0 then return nil, "duration_unavailable" end
	local remaining = clip.duration * (1 - cycle) / rate
	if remaining > 30 then return nil, "duration_limit" end
	clip.rate, clip.cycle, clip.remainingSeconds = rate, cycle, remaining
	return clip
end

function Catalog.ListSequences(entity, options)
	if not IsValid(entity) or type(entity.GetModel) ~= "function"
		or type(entity.GetSequenceCount) ~= "function" or type(entity.GetSequenceInfo) ~= "function"
		or type(entity.SequenceDuration) ~= "function" then return nil, "model_entity_required" end
	if options == nil then options = {} end
	if type(options) ~= "table" then return nil, "invalid_options" end
	local offset = options.offset == nil and 0 or options.offset
	local limit = options.limit == nil and 128 or options.limit
	local rate = options.rate == nil and 1 or options.rate
	local cycle = options.cycle == nil and 0 or options.cycle
	if not finite(offset) or offset < 0 or offset > 65536 or offset % 1 ~= 0
		or not finite(limit) or limit < 1 or limit > 512 or limit % 1 ~= 0
		or not finite(rate) or rate < .1 or rate > 4
		or not finite(cycle) or cycle < 0 or cycle >= 1 then return nil, "invalid_options" end
	local success, result, failure = pcall(function()
		local model, count = entity:GetModel(), entity:GetSequenceCount()
		if type(model) ~= "string" or not finite(count) or count < 0 or count > 65536 or count % 1 ~= 0 then
			return nil, "sequence_metadata_unavailable"
		end
		local last = math.min(count, offset + limit)
		local page = {schema = 1, model = model, sequenceCount = count, offset = offset, limit = limit, entries = {}}
		for sequence = offset, last - 1 do
			local clip, reason = describeSequence(entity, sequence)
			if not clip then return nil, reason end
			local allowed, previewReason = timedPreview(clip, rate, cycle)
			clip.timedPreview, clip.previewReason = allowed ~= nil, previewReason
			page.entries[#page.entries + 1] = clip
		end
		if entity:GetModel() ~= model or entity:GetSequenceCount() ~= count then return nil, "model_changed_during_query" end
		if last < count then page.nextOffset = last end
		return page
	end)
	if not success then return nil, "sequence_query_failed" end
	return result, failure
end

-- Read-only clip policy on the actor's CURRENT model. Does not check native
-- preview ownership, authorize playback, swap models, or freeze the actor.
function Catalog.ResolvePreview(entity, request)
	if type(request) ~= "table" then return nil, "invalid_request" end
	local rate, cycle = request.rate or 1, request.cycle or 0
	if not finite(rate) or rate < 0.1 or rate > 4
		or not finite(cycle) or cycle < 0 or cycle >= 1 then
		return nil, "invalid_options"
	end
	local clip, reason = Catalog.Resolve(entity, request)
	if not clip then return nil, reason end
	return timedPreview(clip, rate, cycle)
end

-- Explicit diagnostic duration; controller/cycle tracks need not have a usable
-- timed sequence duration. Authoritative preview ownership is checked separately.
function Catalog.ResolveControlledPreview(entity, request)
	if type(request) ~= "table" then return nil, "invalid_request" end
	local rate, cycle, seconds = request.rate or 1, request.cycle or 0, request.seconds
	if not finite(rate) or rate < .1 or rate > 4 or not finite(cycle) or cycle < 0 or cycle >= 1 then
		return nil, "invalid_options"
	end
	if not finite(seconds) or seconds < .1 or seconds > 30 then return nil, "invalid_preview_duration" end
	if request.controller == nil then return nil, "controller_mapping_required" end
	local resolved, reason = NPCAnimationBridge.Controllers.ResolveSequence(entity, request)
	if not resolved then return nil, reason end
	if resolved.baseRequired then return nil, resolved.baseReason end
	resolved.clip.rate, resolved.clip.cycle, resolved.clip.remainingSeconds = rate, cycle, seconds
	return resolved
end
