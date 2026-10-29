local Bridge = NPCAnimationBridge
if Bridge.Appearance then Bridge.Appearance.Shutdown() end
local Appearance = {}
Bridge.Appearance = Appearance
local candidates = setmetatable({}, {__mode = "k"})
local installed = {}
local rendering = {}
local failures = {}
local neutral = Vector(1, 1, 1)
local function playerColor() return neutral end

local function restore(entity)
    if IsValid(entity) and entity.GetPlayerColor == playerColor then entity.GetPlayerColor = nil end
    installed[entity] = nil
end

local function discover(entity)
    if IsValid(entity) and entity:IsNPC() then candidates[entity] = true end
end

local function restoreRender(entity)
    local context = rendering[entity]
    if context then Bridge.CarrierPose.Detach(context.pose) end
    if context and IsValid(entity) and entity.RenderOverride == context.render then
        entity.RenderOverride = context.previous
    end
    rendering[entity] = nil
end

local function manageVisual(entity)
    local visual = entity:GetNW2Entity("NPCAnimationBridge.Visual")
    local valid = IsValid(visual) and visual:GetParent() == entity
        and visual:GetNW2Bool("NPCAnimationBridge.Visual", false)
    if not valid then
        if rendering[entity] then restoreRender(entity) end
        failures[entity] = nil
        return
    end
    local sourceModel, targetModel = entity:GetModel(), visual:GetModel()
    if not sourceModel or sourceModel == "" or not targetModel or targetModel == "" then return end
    local current = rendering[entity]
    if current and current.visual == visual and current.sourceModel == sourceModel
        and current.targetModel == targetModel and current.pose.failure then
        local details = current.pose.failure
        restoreRender(entity)
        visual:SetNoDraw(true)
        failures[entity] = {visual = visual, sourceModel = sourceModel, targetModel = targetModel,
            reason = "carrier_pose_update_failed", details = details}
        chat.AddText("[NPC Animation Bridge] Appearance transfer unavailable: carrier_pose_update_failed")
        return
    end
    local failure = failures[entity]
    if failure and failure.visual == visual and failure.sourceModel == sourceModel and failure.targetModel == targetModel then
        if not failure.retryAt then return end
        if RealTime() >= failure.retryUntil or failure.attempts >= 20 then
            failure.retryAt = nil
            chat.AddText("[NPC Animation Bridge] Appearance transfer unavailable: " .. tostring(failure.reason))
            return
        end
        if RealTime() < failure.retryAt then return end
    else failure = nil end
    if rendering[entity] and rendering[entity].visual == visual
        and rendering[entity].sourceModel == sourceModel and rendering[entity].targetModel == targetModel then return end
    if rendering[entity] then restoreRender(entity) end
    local context = {previous = entity.RenderOverride}
    context.visual = visual
    context.sourceModel, context.targetModel = sourceModel, targetModel
    context.pose, context.failure = Bridge.CarrierPose.Attach(entity, visual)
    if not context.pose then
        local pending = context.failure == "carrier_bone_names_not_ready"
        failures[entity] = {visual = visual, sourceModel = sourceModel, targetModel = targetModel, reason = context.failure,
            attempts = (failure and failure.attempts or 0) + 1,
            retryUntil = pending and (failure and failure.retryUntil or RealTime() + 2) or nil,
            retryAt = pending and RealTime() + .1 or nil}
        visual:SetNoDraw(true)
        if not pending then chat.AddText("[NPC Animation Bridge] Appearance transfer unavailable: " .. tostring(context.failure)) end
        return
    end
    visual:SetNoDraw(false)
    failures[entity] = nil
    context.render = function(actor)
        local child = actor:GetNW2Entity("NPCAnimationBridge.Visual")
        if IsValid(child) and child:GetParent() == actor then
            -- The visible child's pose callback updates the carrier bones.
        elseif context.previous then context.previous(actor)
        else actor:DrawModel() end
    end
    rendering[entity] = context
    entity.RenderOverride = context.render
end

-- Detached client observation; server lease validity does not prove rendering.
function Appearance.GetStatus(entity)
    if not IsValid(entity) then return {schema = 1, available = false} end
    local context, failure = rendering[entity], failures[entity]
    local visual = entity:GetNW2Entity("NPCAnimationBridge.Visual")
    return {schema = 1, available = true, candidate = candidates[entity] == true,
        active = context ~= nil, failure = failure and failure.reason or nil,
        failure_details = failure and failure.details or nil,
        pose_updates = context and context.pose.updates or nil,
        readiness_pending = failure ~= nil and failure.retryAt ~= nil,
        attempts = failure and failure.attempts or nil,
        mapping = context and table.Copy(context.pose.mapping) or nil,
        render_owned = context ~= nil and entity.RenderOverride == context.render,
        source_model = entity:GetModel(), visual_valid = IsValid(visual),
        visual_model = IsValid(visual) and visual:GetModel() or nil,
        visual_nodraw = IsValid(visual) and visual:GetNoDraw() or false,
        visual_parent_matches = IsValid(visual) and visual:GetParent() == entity or false}
end

function Appearance.Update()
    for entity in pairs(candidates) do
        if not IsValid(entity) then candidates[entity] = nil installed[entity] = nil rendering[entity] = nil
        else
            manageVisual(entity)
            if entity:GetNW2Bool("NPCAnimationBridge.NeutralColor", false) then
                -- Respect a colour provider installed by another addon.
                if entity.GetPlayerColor == nil then entity.GetPlayerColor = playerColor installed[entity] = true end
            elseif installed[entity] then restore(entity) end
        end
    end
end

function Appearance.Shutdown()
    for entity in pairs(installed) do restore(entity) end
    for entity in pairs(rendering) do restoreRender(entity) end
    for _, failure in pairs(failures) do if IsValid(failure.visual) then failure.visual:SetNoDraw(false) end end
    hook.Remove("Think", "NPCAnimationBridge.Appearance")
    hook.Remove("NetworkEntityCreated", "NPCAnimationBridge.Appearance")
    hook.Remove("EntityRemoved", "NPCAnimationBridge.Appearance")
end

for _, entity in ipairs(ents.GetAll()) do discover(entity) end
hook.Add("NetworkEntityCreated", "NPCAnimationBridge.Appearance", discover)
hook.Add("EntityRemoved", "NPCAnimationBridge.Appearance", function(entity)
    if rendering[entity] then restoreRender(entity) end
    installed[entity] = nil candidates[entity] = nil rendering[entity] = nil failures[entity] = nil
end)
hook.Add("Think", "NPCAnimationBridge.Appearance", Appearance.Update)
