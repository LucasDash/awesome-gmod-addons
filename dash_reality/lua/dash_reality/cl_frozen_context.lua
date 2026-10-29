-- Keep Sandbox's normal property menu for a time-frozen NPC. The server-side
-- carrier is not always traceable on the client, so resolve only this addon's
-- parented, frozen actors against the cursor ray before opening the menu.
local RT = DashReality
if RT.StopFrozenContext then RT.StopFrozenContext() end
hook.Remove("InitPostEntity", "RealityTools.FrozenContext")

local enabled = true
local previous, wrapper
local carriers, nextScan = {}, 0

local function frozenChild(carrier)
    if not IsValid(carrier) or carrier:IsDormant() or carrier:GetClass() ~= "rt_time_carrier" then return end
    for _, child in ipairs(carrier:GetChildren()) do
        if IsValid(child) and not child:IsDormant() and child:GetParent() == carrier and child:GetNW2Bool("RT_TimeFrozen", false)
            and (child:IsNPC() or child.IsNextBot and child:IsNextBot()) then
            return child
        end
    end
end

local function traceFilter(ply, carrier, npc)
    local view = ply:GetViewEntity()
    if not IsValid(view) then view = ply end
    local filter = { view, carrier, npc }
    local vehicle = ply:GetVehicle()
    if view == ply and IsValid(vehicle) and (not vehicle:IsVehicle() or not vehicle:GetThirdPersonMode()) then
        filter[#filter + 1] = vehicle
        for _, follower in ipairs(ents.FindByClass("phys_bone_follower")) do filter[#filter + 1] = follower end
    end
    return filter
end

local function visible(ply, start, point, carrier, npc)
    local data = { start = start, endpos = point, filter = traceFilter(ply, carrier, npc), mask = MASK_SOLID }
    local tr = util.TraceLine(data)
    if tr.Hit or tr.StartSolid or tr.AllSolid then return false end
    -- Match the stock menu's fallback for entities such as debris.
    data.mask = MASK_ALL
    tr = util.TraceLine(data)
    if tr.Hit or tr.StartSolid or tr.AllSolid then return false end
    return true, tr
end

local function resolve(start, direction, oldEntity, oldTrace)
    local ply = LocalPlayer()
    if not IsValid(ply) then return oldEntity, oldTrace end
    local now = RealTime()
    if now >= nextScan then carriers = ents.FindByClass("rt_time_carrier") nextScan = now + .25 end
    if #carriers == 0 then return oldEntity, oldTrace end

    local ray = direction * 1024
    local best
    for _, carrier in ipairs(carriers) do
        local npc = frozenChild(carrier)
        if IsValid(npc) then
            local point, normal, fraction = util.IntersectRayWithOBB(start, ray, npc:GetPos(), npc:GetAngles(), npc:OBBMins(), npc:OBBMaxs())
            if point and fraction and fraction >= 0 and fraction <= 1 and (not best or fraction < best.fraction) then
                best = { carrier = carrier, npc = npc, point = point, normal = normal, fraction = fraction }
            end
        end
    end
    if not best then return oldEntity, oldTrace end
    local clear, tr = visible(ply, start, best.point, best.carrier, best.npc)
    if not clear then return oldEntity, oldTrace end

    -- The normal menu and property receivers see the actual NPC. No property
    -- is added, intercepted, sent or authorized by this resolver.
    tr.Entity, tr.Hit, tr.HitWorld, tr.HitNonWorld = best.npc, true, false, true
    tr.StartPos, tr.HitPos, tr.HitNormal, tr.Fraction = start, best.point, best.normal, best.fraction
    tr.Normal, tr.StartSolid, tr.AllSolid = direction, false, false
    return best.npc, tr
end

local function install()
    if not enabled or not properties or not isfunction(properties.GetHovered) or wrapper then return end
    previous = properties.GetHovered
    wrapper = function(start, direction)
        local ent, tr = previous(start, direction)
        if not enabled then return ent, tr end
        return resolve(start, direction, ent, tr)
    end
    properties.GetHovered = wrapper
end

function RT.StopFrozenContext()
    enabled = false
    hook.Remove("InitPostEntity", "DashReality.FrozenContext")
    hook.Remove("ContactIK.CarryVisualEntity", "DashReality.FrozenCarryVisual")
    if properties and properties.GetHovered == wrapper then properties.GetHovered = previous end
    carriers = {}
end

hook.Add("InitPostEntity", "DashReality.FrozenContext", install)
-- Expose the visible body for any contact-pose provider that understands the
-- generic carrier contract; keep the physical entity and permissions native.
hook.Add("ContactIK.CarryVisualEntity", "DashReality.FrozenCarryVisual", function(_, carrier)
    return frozenChild(carrier)
end)
install()
