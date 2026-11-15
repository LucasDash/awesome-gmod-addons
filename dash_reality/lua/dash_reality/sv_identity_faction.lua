-- Optional native NPC recognition. Relationship priority is not exposed by GMod;
-- restore the observed disposition when our temporary relationship is removed.
local D = DashReality
local old = D.IdentityFaction
if old and old.Shutdown then old.Shutdown() end

local active = setmetatable({}, {__mode = "k"})
local owned = setmetatable({}, {__mode = "k"})
local combine = {npc_combine_s = true, npc_metropolice = true}
local priority = 50

local function restore(ply)
    local records = owned[ply]
    if records then
        for npc, previous in pairs(records) do
            if IsValid(npc) and IsValid(ply) and npc:Disposition(ply) == D_LI then
                npc:AddEntityRelationship(ply, previous, priority)
            end
        end
    end
    owned[ply] = nil
    active[ply] = nil
end

local function consider(npc, ply)
    if not IsValid(npc) or not IsValid(ply) or not active[ply]
        or not npc:IsNPC() or not combine[npc:GetClass()] then return end
    local records = owned[ply]
    if records[npc] ~= nil then return end
    local previous = npc:Disposition(ply)
    if previous == D_LI then return end
    records[npc] = previous
    npc:AddEntityRelationship(ply, D_LI, priority)
    if npc:Disposition(ply) == D_LI and npc:GetEnemy() == ply then npc:SetEnemy(NULL) end
end

hook.Add("DashRealityIdentityChanged", "DashReality.IdentityFaction", function(ply, id, enabled)
    restore(ply)
    if id ~= "combine" or not enabled then return end
    active[ply] = true
    owned[ply] = setmetatable({}, {__mode = "k"})
    for _, npc in ipairs(ents.FindByClass("npc_combine_s")) do consider(npc, ply) end
    for _, npc in ipairs(ents.FindByClass("npc_metropolice")) do consider(npc, ply) end
end)

hook.Add("OnEntityCreated", "DashReality.IdentityFaction", function(npc)
    if not next(active) or not IsValid(npc) or not combine[npc:GetClass()] then return end
    timer.Simple(0, function()
        if not IsValid(npc) then return end
        for ply in pairs(active) do consider(npc, ply) end
    end)
end)
hook.Add("PlayerDisconnected", "DashReality.IdentityFaction", restore)
hook.Add("ShutDown", "DashReality.IdentityFaction", function()
    for ply in pairs(active) do restore(ply) end
end)
D.IdentityFaction = {Shutdown = function()
    for ply in pairs(active) do restore(ply) end
    hook.Remove("DashRealityIdentityChanged", "DashReality.IdentityFaction")
    hook.Remove("OnEntityCreated", "DashReality.IdentityFaction")
    hook.Remove("PlayerDisconnected", "DashReality.IdentityFaction")
    hook.Remove("ShutDown", "DashReality.IdentityFaction")
end}
