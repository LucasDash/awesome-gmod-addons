local Bridge = NPCAnimationBridge
if Bridge.Preview then Bridge.Preview.Shutdown() end
local Preview = {}
Bridge.Preview = Preview
local active = {}
local closed = false

local function attempt(context, step, callback)
    local ok, value = pcall(callback)
    if not ok then
        context.cleanupErrors = context.cleanupErrors or {}
        if #context.cleanupErrors < 16 then
            context.cleanupErrors[#context.cleanupErrors+1] = {step=step, details=tostring(value):sub(1,512)}
        end
    end
    return ok, value
end

local function current(context)
    if closed or context.finished or active[context.entity] ~= context
        or context.entity.NABPreviewActive ~= context then error("preview_start_preempted") end
end

local function supported(entity)
    return Bridge.Catalog.IsActor(entity) and entity:IsNPC()
        and entity:GetClass():sub(1, 4) == "npc_"
        and not entity.IsVJBaseSNPC and not entity.IsDrGNextbot and not entity.IsZBaseNPC
end

-- Inspect the current playback model before freezing AI or creating a visual.
local function plan(entity, request)
    if request.controller ~= nil then return Bridge.Catalog.ResolveControlledPreview(entity,request) end
    local clip, reason=Bridge.Catalog.ResolvePreview(entity,request)
    if not clip then return nil,reason end
    return {clip=clip}
end

local function applyInputs(context, poses)
    local entity=context.entity
    context.poseOriginals,context.poseApplied=context.poseOriginals or {},context.poseApplied or {}
    for name,value in pairs(poses) do
        if context.poseOriginals[name]==nil then
            local original=entity:GetPoseParameter(name)
            if not Bridge.Catalog.IsFinite(original) or math.abs(original)>1000000 then error("pose_snapshot_unavailable") end
            context.poseOriginals[name]=original
        end
        entity:SetPoseParameter(name,value)
        context.poseApplied[name]=entity:GetPoseParameter(name)
        if not Bridge.Catalog.IsFinite(context.poseApplied[name]) or math.abs(context.poseApplied[name])>1000000 then error("pose_value_unavailable") end
    end
    if next(poses) and type(entity.InvalidateBoneCache)=="function" then entity:InvalidateBoneCache() end
end

local function finish(context, reason)
    local entity = context.entity
    if active[entity] ~= context then return false, "not_owned" end
    active[entity] = nil
    context.finished, context.reason = true, reason
    if context.overlay then attempt(context, "overlay", function() Bridge.Executor.Cancel(context.overlay) end) end
    if context.controller and Bridge.PoseSync then attempt(context,"pose_sync",function() Bridge.PoseSync.Stop(context) end) end
    if not IsValid(entity) or entity.NABPreviewActive ~= context then return true end
    -- Retain the marker until cleanup ends: Play rejects reentrant acquisition
    -- while engine callbacks are restoring this actor, even with active cleared.
    local function clean(step, callback)
        if IsValid(entity) and entity.NABPreviewActive == context then return attempt(context, step, callback) end
        return false
    end
    if context.visual then clean("carrier", function() Bridge.Carrier.Remove(context) end) end
    clean("neutral_color", function() entity:SetNW2Bool("NPCAnimationBridge.NeutralColor", false) end)
    local queried, model = clean("model_query", function() return entity:GetModel() end)
    if context.controller and queried and model==context.playbackModel then
        clean("poses",function()
            if entity:GetSequence()~=context.poseSequence then return end
            local changed=false
            for name,value in pairs(context.poseOriginals or {}) do
                local present=entity:GetPoseParameter(name)
                local applied=context.poseApplied[name]
                if applied and Bridge.Catalog.IsFinite(present) and math.abs(present-applied)<.0001 then
                    entity:SetPoseParameter(name,value); changed=true
                end
            end
            if changed and type(entity.InvalidateBoneCache)=="function" then entity:InvalidateBoneCache() end
        end)
    end
    for slot, material in pairs(context.materialOverrides) do
        clean("material", function()
            if entity:GetSubMaterial(slot) == material.applied then entity:SetSubMaterial(slot, material.previous) end
        end)
    end
    if queried and model == context.playbackModel and context.changedModel then
        clean("model", function() entity:SetModel(context.model) end)
    end
    local restored, originalModel = clean("restored_model_query", function() return entity:GetModel()==context.model end)
    if context.changedModel and context.modelAttempted and restored and originalModel then
        clean("skin", function() entity:SetSkin(context.skin) end)
        for id, value in pairs(context.bodygroups) do clean("bodygroup", function() entity:SetBodygroup(id, value) end) end
        clean("hull", function() entity:SetCollisionBounds(context.minimum, context.maximum) end)
        clean("sequence", function()
            local sequence = entity:LookupSequence(context.sequence)
            if sequence >= 0 then entity:ResetSequence(sequence) entity:SetCycle(context.cycle) end
        end)
        clean("rate", function() entity:SetPlaybackRate(context.rate) end)
        if context.originalPoses then clean("original_poses",function()
            for name,value in pairs(context.originalPoses) do entity:SetPoseParameter(name,value) end
            if type(entity.InvalidateBoneCache)=="function" then entity:InvalidateBoneCache() end
        end) end
    end
    local checked, frozen = clean("freeze_query", function()
        local schedule=entity:GetCurrentSchedule()
        return entity:Health()>0 and entity:GetNPCState()==NPC_STATE_SCRIPT
            and (schedule==SCHED_NPC_FREEZE or
                (context.freezeStarted and not context.freezeScheduled and schedule==context.schedule))
    end)
    if checked and frozen then
        clean("schedule", function() entity:ClearSchedule() end)
        clean("npc_state", function() if entity:GetNPCState()==NPC_STATE_SCRIPT then entity:SetNPCState(context.npcState) end end)
    end
    if entity.NABPreviewActive == context then entity.NABPreviewActive = nil end
    return true
end

local function play(entity, request, owner)
    if not supported(entity) then return nil, "native_npc_required" end
    if active[entity] or entity.NABPreviewActive ~= nil or Bridge.FullBody.IsOwned(entity)
        or Bridge.Executor.GetStatus(entity).active then return nil, "actor_busy" end
    if entity:Health() <= 0 or entity:GetNPCState() == NPC_STATE_SCRIPT then
        return nil, "actor_dead_or_scripted"
    end
    if type(request) ~= "table" or type(request.sequence) ~= "string"
        or #request.sequence < 1 or #request.sequence > 128 then return nil, "invalid_sequence" end
    local model = request.model or entity:GetModel()
    -- Source normalizes model paths; ownership comparisons must use the same form.
    if type(model) == "string" then model = model:lower() end
    local blend = request.blend or 0.2
    if not Bridge.Catalog.IsFinite(blend) or blend < 0 or blend > 2 then return nil, "invalid_blend" end
    local rate, cycle = request.rate or 1, request.cycle or 0
    if not Bridge.Catalog.IsFinite(rate) or rate < 0.1 or rate > 4
        or not Bridge.Catalog.IsFinite(cycle) or cycle < 0 or cycle >= 1 then
        return nil, "invalid_options"
    end
    if type(model) ~= "string" or #model > 240 or not model:match("^models/[%w_%.%-%/]+%.mdl$")
        or not util.IsValidModel(model) then return nil, "invalid_playback_model" end
    local resolved
    if model == entity:GetModel() then
        local failure
        resolved,failure=plan(entity,request)
        if not resolved then return nil,failure end
    end
    if request.preserveAppearance == true and model ~= entity:GetModel() then
        local ok, failure = Bridge.Carrier.Check(entity)
        if not ok then return nil, failure end
        if entity:GetModelScale() ~= 1 then return nil, "carrier_scaled_model_requires_adapter" end
    end
    local minimum, maximum = entity:GetCollisionBounds()
    local context = {entity = entity, owner = owner, model = entity:GetModel(), skin = entity:GetSkin(),
        bodygroups = {}, minimum = minimum, maximum = maximum, sequence = entity:GetSequenceName(entity:GetSequence()),
        cycle = entity:GetCycle(), rate = entity:GetPlaybackRate(), npcState = entity:GetNPCState(), schedule = entity:GetCurrentSchedule(),
        playbackModel = model, changedModel = model ~= entity:GetModel(), materialOverrides = {}, blend = blend,
        originalSubmaterials = {}}
    local originalMaterials = entity:GetMaterials()
    for slot = 0, #originalMaterials - 1 do
        local material = entity:GetSubMaterial(slot)
        if material ~= "" then context.originalSubmaterials[slot] = material end
    end
    for _, group in ipairs(entity:GetBodyGroups()) do
        context.bodygroups[group.id] = entity:GetBodygroup(group.id)
    end
    if request.controller~=nil and context.changedModel then
        local count=entity:GetNumPoseParameters()
        if not Bridge.Catalog.IsFinite(count) or count<0 or count>128 or count%1~=0 then error("pose_snapshot_unavailable") end
        context.originalPoses={}
        for index=0,count-1 do
            local name=entity:GetPoseParameterName(index)
            local value=entity:GetPoseParameter(name)
            if type(name)~="string" or #name<1 or #name>96 or not Bridge.Catalog.IsFinite(value) or math.abs(value)>1000000 then error("pose_snapshot_unavailable") end
            context.originalPoses[name]=value
        end
    end
    active[entity] = context
    entity.NABPreviewActive = context
    current(context)
    entity:SetNW2Bool("NPCAnimationBridge.NeutralColor", context.changedModel)
    if context.changedModel then
        current(context)
        context.modelAttempted = true
        entity:SetModel(model)
        current(context)
        entity:SetCollisionBounds(context.minimum, context.maximum)
        local failure
        resolved,failure=plan(entity,request)
        if not resolved then finish(context,failure) return nil,failure end
        if request.preserveAppearance == true then
            local ok, failure = Bridge.Carrier.Check(entity)
            if not ok then finish(context, failure) return nil, failure end
            local visual, error = Bridge.Carrier.Create(context)
            if not visual then finish(context, error) return nil, error end
        end
        -- Only the known citizen-sheet equivalent; never map arbitrary custom UVs.
        local available = {}
        for _, path in ipairs(originalMaterials) do available[path] = true end
        for index, path in ipairs(entity:GetMaterials()) do
            local native = path:gsub("/players_sheet$", "/citizen_sheet")
            if native ~= path and available[native] then
                local slot = index - 1
                context.materialOverrides[slot] = {previous = entity:GetSubMaterial(slot), applied = native}
                entity:SetSubMaterial(slot, native)
            end
        end
    end
    context.clip,context.controller=resolved.clip,resolved.controller
    context.previewSeconds=resolved.clip.remainingSeconds
    current(context)
    context.freezeStarted = true
    entity:SetNPCState(NPC_STATE_SCRIPT)
    current(context)
    entity:SetSchedule(SCHED_NPC_FREEZE)
    context.freezeScheduled = true
    current(context)
    if context.controller then
        context.poseSequence=entity:GetSequence()
        applyInputs(context,resolved.inputs.poses)
    end
    local overlay, reason = Bridge.Executor.StartOverlay(entity, {
        sequence = request.sequence, rate = rate, cycle = cycle,
        weight = 1, priority = 15, preview = true, controlled=context.controller~=nil, blendIn = blend, blendOut = blend
    })
    if not overlay then finish(context, reason) return nil, reason end
    context.overlay = overlay
    if context.finished or closed or active[entity] ~= context then
        Bridge.Executor.Cancel(overlay)
        error("preview_start_preempted")
    end
    if context.controller then
        local synced,syncReason=Bridge.PoseSync.PublishPreview(context,resolved.inputs.poses)
        if not synced then finish(context,syncReason); return nil,syncReason end
    end
    return context
end

function Preview.CanStartControlledOverlay(entity, clip)
    local context=active[entity]
    return context~=nil and not context.finished and context.controller~=nil and context.overlay==nil
        and entity.NABPreviewActive==context and entity:GetModel()==context.playbackModel
        and context.clip.sequence==clip.sequence and entity:GetNPCState()==NPC_STATE_SCRIPT
        and entity:GetCurrentSchedule()==SCHED_NPC_FREEZE, context and context.previewSeconds
end

function Preview.IsControllerOwned(context)
    if type(context)~="table" or active[context.entity]~=context or context.finished or not context.controller then return false end
    local e=context.entity
    return IsValid(e) and e.NABPreviewActive==context and e:GetModel()==context.playbackModel
        and e:GetSequence()==context.poseSequence and e:GetNPCState()==NPC_STATE_SCRIPT
        and e:GetCurrentSchedule()==SCHED_NPC_FREEZE and Bridge.Executor.IsHandleOwned(context.overlay)
end

function Preview.UpdateInputs(entity, request, owner)
    local context=active[entity]
    if not context then return nil,"not_playing" end
    if owner~=nil and context.owner~=owner then return nil,"not_owned" end
    if not context.controller then return nil,"controller_preview_required" end
    local publicationFailed=false
    local ok, result, reason=pcall(function()
        if not Preview.IsControllerOwned(context) then return nil,"controller_preempted" end
        if type(request)~="table" then return nil,"invalid_poses" end
        local resolved,failure=Bridge.Controllers.ResolveSequence(entity,{
            sequence=context.clip.label,controller=context.controller,poses=request.poses,movement=request.movement
        })
        if not resolved then return nil,failure end
        applyInputs(context,resolved.inputs.poses)
        local synced,syncReason=Bridge.PoseSync.PublishPreview(context,resolved.inputs.poses)
        if not synced then publicationFailed=true; return nil,syncReason end
        return resolved.inputs
    end)
    if not ok then context.writeError=tostring(result):sub(1,2048); finish(context,"pose_write_failed"); return nil,"pose_write_failed" end
    if reason=="controller_preempted" or publicationFailed then finish(context,reason) end
    return result,reason
end

function Preview.Play(entity, request, owner)
    if closed then return nil, "module_shutting_down" end
    local previous = active[entity]
    local ok, result, reason = pcall(play, entity, request, owner)
    if ok then return result, reason end
    local context = active[entity]
    if context and context ~= previous then
        context.writeError = tostring(result):sub(1,2048)
        finish(context, "preview_write_failed")
    end
    local errors = {}
    for i, entry in ipairs(context and context.cleanupErrors or {}) do
        errors[i] = {step=entry.step, details=entry.details}
    end
    return nil, "preview_write_failed", {writeError=tostring(result):sub(1,2048), cleanupErrors=errors}
end

function Preview.FadeOut(entity, owner)
    local context = active[entity]
    if not context then return false, "not_playing" end
    if owner ~= nil and context.owner ~= owner then return false, "not_owned" end
    return Bridge.Executor.FadeOut(context.overlay, context.blend)
end

function Preview.Stop(entity, owner)
    local context = active[entity]
    if not context then return false, "not_playing" end
    if owner ~= nil and context.owner ~= owner then return false, "not_owned" end
    return finish(context, "cancelled")
end

function Preview.GetStatus(entity)
    local context = active[entity]
    if not context then return {schema = 1, active = false} end
    local valid = IsValid(entity)
    local visual = IsValid(context.visual)
    local ok, overlay = pcall(Bridge.Executor.GetStatus, entity)
    local checked, actorValid = pcall(function()
        return valid and entity:Health()>0 and entity:GetModel()==context.playbackModel
            and entity:GetNPCState()==NPC_STATE_SCRIPT and entity:GetCurrentSchedule()==SCHED_NPC_FREEZE
            and (not context.controller or Preview.IsControllerOwned(context))
    end)
    return {schema = 1, active = true,
        valid = checked and actorValid and ok
            and (context.visual == nil or visual) and overlay.active and overlay.valid,
        failure = (not ok or not checked) and "preview_query_failed" or nil,
        failureDetails = not ok and tostring(overlay):sub(1,2048) or not checked and tostring(actorValid):sub(1,2048) or nil,
        originalModel = context.model, playbackModel = context.playbackModel,
        changedModel = context.changedModel, carrier = context.visual ~= nil,
        controlled = context.controller ~= nil,
        visualValid = visual, visualIndex = visual and context.visual:EntIndex() or nil,
        overlay = ok and overlay or nil}
end

function Preview.GetActiveCount()
    local count = 0
    for _ in pairs(active) do count = count + 1 end
    return count
end

function Preview.Update()
    for entity, context in pairs(active) do
        local ok, error = pcall(function()
        if not IsValid(entity) then finish(context, "entity_removed")
        elseif entity:Health() <= 0 then finish(context, "actor_dead")
        elseif entity:GetModel() ~= context.playbackModel then finish(context, "model_changed")
        elseif context.visual and not IsValid(context.visual) then finish(context, "carrier_visual_removed")
        elseif entity:GetNPCState() ~= NPC_STATE_SCRIPT or entity:GetCurrentSchedule() ~= SCHED_NPC_FREEZE then
            finish(context, "npc_preempted")
        elseif context.overlay.finished then finish(context, context.overlay.reason) end
        if context.controller and active[entity]==context and not Preview.IsControllerOwned(context) then finish(context,"controller_preempted") end
        end)
        if not ok then context.writeError=tostring(error):sub(1,2048); finish(context,"preview_update_failed") end
    end
end

function Preview.Shutdown()
    closed = true
    for _, context in pairs(active) do finish(context, "module_reload") end
    hook.Remove("Think", "NPCAnimationBridge.Preview")
    hook.Remove("EntityRemoved", "NPCAnimationBridge.Preview")
    hook.Remove("PlayerDisconnected", "NPCAnimationBridge.Preview")
    hook.Remove("EntityTakeDamage", "NPCAnimationBridge.Preview")
end

hook.Add("Think", "NPCAnimationBridge.Preview", Preview.Update)
hook.Add("EntityTakeDamage", "NPCAnimationBridge.Preview", function(entity, damage)
    local context = active[entity]
    if not context then return end
    local amount = damage:GetDamage()
    if Bridge.Catalog.IsFinite(amount) and amount > 0 then finish(context, "actor_damaged") end
end)
hook.Add("EntityRemoved", "NPCAnimationBridge.Preview", function(entity)
    if active[entity] then finish(active[entity], "entity_removed") end
end)
hook.Add("PlayerDisconnected", "NPCAnimationBridge.Preview", function(owner)
    for _, context in pairs(active) do
        if context.owner == owner then finish(context, "owner_disconnected") end
    end
end)
