-- A render-only offset for airborne crouching; never modifies movement or bones.
local enabled = CreateClientConVar("rt_crouch_visual", "0", true, false, "Smooth airborne crouch model position")
local state = setmetatable({}, {__mode = "k"})
local changed = setmetatable({}, {__mode = "k"})
local function restore(ply)
    local origin = changed[ply]
    if not origin then return end
    changed[ply] = nil
    if IsValid(ply) and ply:GetRenderOrigin():DistToSqr(origin) < 0.01 then ply:SetRenderOrigin() end
end

hook.Add("PrePlayerDraw", "DashReality.CrouchVisual", function(ply)
    if not enabled:GetBool() or not IsValid(ply) or not ply:Alive() or ply:InVehicle() then
        state[ply] = nil
        return
    end
    local pos = ply:GetPos()
    -- Do not take over an origin already displaced by another renderer.
    if ply:GetRenderOrigin():DistToSqr(pos) > 0.01 then
        state[ply] = nil
        return
    end
    local target = 0
    if not ply:OnGround() and ply:Crouching() then
        local _, stand = ply:GetHull()
        local _, duck = ply:GetHullDuck()
        local depth = math.Clamp(stand.z - duck.z, 0, 36)
        local tr = util.TraceLine({start = pos, endpos = pos - Vector(0, 0, depth), filter = ply, mask = MASK_PLAYERSOLID})
        target = -depth * tr.Fraction
    end
    local offset = Lerp(math.Clamp(FrameTime() * 12, 0, 1), state[ply] or 0, target)
    if math.abs(offset) < 0.05 then state[ply] = nil return end
    state[ply] = offset
    local origin = pos + Vector(0, 0, offset)
    ply:SetRenderOrigin(origin)
    changed[ply] = origin
end)

hook.Add("PostPlayerDraw", "DashReality.CrouchVisual", function(ply)
    restore(ply)
end)
-- Another PrePlayerDraw hook can cancel the draw and suppress PostPlayerDraw.
hook.Add("PostRender", "DashReality.CrouchVisual", function()
    for ply in pairs(changed) do restore(ply) end
end)
