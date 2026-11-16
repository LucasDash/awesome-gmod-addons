-- Identity recognition for built-in Source NPCs. Profiles supply faction and
-- CLASS names; no model, NPC entity class or weapon determines a faction.
local D = DashReality
if D.IdentityFaction and D.IdentityFaction.Shutdown then D.IdentityFaction.Shutdown() end

local active = setmetatable({}, {__mode = "k"})
local links = setmetatable({}, {__mode = "k"})
local npcStates = D.IdentityNPCStates or setmetatable({}, {__mode = "k"})
D.IdentityNPCStates = npcStates
local classFactions = {}
for _, profile in ipairs(D.IdentityProfiles) do
    for _, name in ipairs(profile.classifications or {}) do
        local class = _G[name]
        if isnumber(class) and profile.faction then classFactions[class] = profile.faction end
    end
end
local priority = 50
local stopped = false

local function nativeNPC(ent)
    return IsValid(ent) and ent:IsNPC() and not ent:IsScripted()
end

local function faction(ent)
    local explicit = active[ent]
    if explicit then return explicit end
    if not nativeNPC(ent) then return nil end
    local ok, class = pcall(ent.Classify, ent)
    return ok and classFactions[class] or nil
end

local function restore(observer, target)
    local records = links[observer]
    local old = records and records[target]
    if not old then return end
    records[target] = nil
    if IsValid(observer) and IsValid(target) then
        local disposition, currentPriority = observer:Disposition(target)
        -- Preserve subsequent relationship changes, including a changed priority.
        if disposition == D_LI and currentPriority == priority then
            observer:AddEntityRelationship(target, old.disposition, old.priority)
        end
    end
    if not next(records) then links[observer] = nil end
end

local function removeAffected(actor)
    for observer, records in pairs(links) do
        if observer == actor then
            for target in pairs(records) do restore(observer, target) end
        elseif records[actor] then
            restore(observer, actor)
        end
    end
end

local function consider(observer, target)
    if observer == target or not nativeNPC(observer) or not IsValid(target)
        or not (active[observer] or active[target]) then return end
    local group = faction(observer)
    if not group or group ~= faction(target) then return end
    local records = links[observer]
    if records and records[target] then return end
    local previous, oldPriority = observer:Disposition(target)
    if previous == D_LI or not isnumber(previous) or not isnumber(oldPriority) then return end
    records = records or setmetatable({}, {__mode = "k"})
    links[observer] = records
    records[target] = {disposition = previous, priority = oldPriority}
    observer:AddEntityRelationship(target, D_LI, priority)
    if observer:Disposition(target) == D_LI and observer:GetEnemy() == target then
        observer:SetEnemy(NULL)
    end
end

local function refresh(actor)
    removeAffected(actor)
    if not IsValid(actor) then return end
    -- Work is paid only when an identity changes or a relevant actor spawns.
    for _, other in ipairs(ents.GetAll()) do
        if nativeNPC(other) then consider(other, actor) end
        if nativeNPC(actor) and (nativeNPC(other) or active[other]) then consider(actor, other) end
    end
end

hook.Add("DashRealityIdentityChanged", "DashReality.IdentityFaction", function(actor, id, enabled)
    local profile = D.IdentityProfilesById[id or ""]
    active[actor] = enabled and profile and profile.faction or nil
    refresh(actor)
end)

-- Tools use the same server-side permission check and profile data as the menu.
function D.ApplyActorIdentity(requester, actor, id, recognize)
    if not D.CanManageIdentity(requester) or not IsValid(actor) then return false, "Not permitted." end
    if actor:IsPlayer() then return D.ApplyIdentity(actor, id, recognize, requester) end
    if not nativeNPC(actor) or actor:Health() <= 0 then return false, "Select a living native NPC or player." end
    local profile = D.IdentityProfilesById[id or ""]
    if not profile then return false, "Unknown identity." end
    npcStates[actor] = {id = id, recognizeFaction = recognize == true}
    actor:SetNW2String("DashReality.Identity", id)
    hook.Run("DashRealityIdentityChanged", actor, id, recognize == true)
    return true
end

function D.ClearActorIdentity(requester, actor)
    if not D.CanManageIdentity(requester) or not IsValid(actor) then return false, "Not permitted." end
    if actor:IsPlayer() then return D.ClearIdentity(actor) end
    if not npcStates[actor] then return false, "This NPC has no Dash Reality identity." end
    npcStates[actor] = nil
    actor:SetNW2String("DashReality.Identity", "")
    hook.Run("DashRealityIdentityChanged", actor, nil, false)
    return true
end

hook.Add("OnEntityCreated", "DashReality.IdentityFaction", function(ent)
    if not next(active) or not IsValid(ent) then return end
    local class = ent:GetClass()
    if not string.StartWith(class, "npc_") and not string.StartWith(class, "monster_") then return end
    timer.Simple(0, function()
        if stopped or not nativeNPC(ent) then return end
        for actor in pairs(active) do
            consider(ent, actor)
            if nativeNPC(actor) then consider(actor, ent) end
        end
    end)
end)
hook.Add("PlayerDisconnected", "DashReality.IdentityFaction", function(actor)
    active[actor] = nil
    removeAffected(actor)
end)
hook.Add("EntityRemoved", "DashReality.IdentityFaction", function(actor)
    active[actor] = nil
    npcStates[actor] = nil
    removeAffected(actor)
end)
hook.Add("OnNPCKilled", "DashReality.IdentityFaction", function(npc)
    if not npcStates[npc] then return end
    npcStates[npc] = nil
    npc:SetNW2String("DashReality.Identity", "")
    active[npc] = nil
    removeAffected(npc)
end)

local function shutdown()
    stopped = true
    for observer, records in pairs(links) do
        for target in pairs(records) do restore(observer, target) end
    end
    for _, event in ipairs({"DashRealityIdentityChanged", "OnEntityCreated", "PlayerDisconnected", "EntityRemoved", "OnNPCKilled", "ShutDown"}) do
        hook.Remove(event, "DashReality.IdentityFaction")
    end
end
hook.Add("ShutDown", "DashReality.IdentityFaction", shutdown)
D.IdentityFaction = {Shutdown = shutdown}

-- Restore recognition after an addon refresh without discarding certificates.
for actor, state in pairs(D.IdentityStates) do
    local profile = D.IdentityProfilesById[state.id or ""]
    if IsValid(actor) and state.recognizeFaction and profile then active[actor] = profile.faction end
end
for actor, state in pairs(npcStates) do
    local profile = D.IdentityProfilesById[state.id or ""]
    if IsValid(actor) and state.recognizeFaction and profile then active[actor] = profile.faction end
end
for actor in pairs(active) do refresh(actor) end
