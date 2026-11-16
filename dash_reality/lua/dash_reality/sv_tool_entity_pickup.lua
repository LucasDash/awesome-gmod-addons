-- Extend native +use pickup to passive tool entities. The engine still chooses
-- the use target; the carry controller, dropping and constraints stay native.
local RT = DashReality
local entityUse = FindMetaTable("Entity").Use
local attempts = setmetatable({}, {__mode = "k"})
local checkingUse = false
local maxDistance = 96
local maxMass = 100 -- Sandbox balloons intentionally have a mass of 100 kg.

local function eligible(ply, ent)
    if not RT.Bool("rt_tool_entity_pickup") or not IsValid(ply) or not ply:IsPlayer()
        or not ply:Alive() or ply:InVehicle() or not IsValid(ent) or not ent:IsScripted()
        or ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsWeapon() or ent:IsVehicle()
        or ent.Use ~= entityUse or ent.PhysgunDisabled or IsValid(ent:GetParent())
        or ent:IsPlayerHolding() or ent:GetMoveType() ~= MOVETYPE_VPHYSICS
        or ent:GetSolid() ~= SOLID_VPHYSICS or ent:GetPhysicsObjectCount() ~= 1 then return false end

    -- Built-in gmod_ tool entities do not all set a creator; other scripted
    -- entities must have a player creator to avoid affecting map-owned devices.
    local creator = ent:GetCreator()
    if string.sub(ent:GetClass(), 1, 5) ~= "gmod_"
        and (not IsValid(creator) or not creator:IsPlayer()) then return false end
    if ent:NearestPoint(ply:GetShootPos()):DistToSqr(ply:GetShootPos()) > maxDistance * maxDistance then return false end

    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) or not phys:IsMotionEnabled() or not phys:IsMoveable()
        or phys:HasGameFlag(FVPHYSICS_NO_PLAYER_PICKUP) then return false end
    local mass = phys:GetMass()
    return mass > 0 and mass <= maxMass
end

local function pickupPermitted(ply, ent)
    local enabled = GetConVar("sv_playerpickupallowed")
    if enabled and not enabled:GetBool() then return false end

    -- CPPI implementations may protect use and pickup independently.
    for _, name in ipairs({"CPPICanUse", "CPPICanPickup"}) do
        if isfunction(ent[name]) then
            local ok, result = pcall(ent[name], ent, ply)
            if not ok or result == false then return false end
        end
    end

    local okPickup, pickupResult = pcall(hook.Run, "AllowPlayerPickup", ply, ent)
    return okPickup and pickupResult ~= false
end

local function usePermitted(ply, ent)
    -- PlayerUse may be vetoed by a hook that runs after ours. Recheck once
    -- during the original input tick, while KeyPressed is still accurate.
    checkingUse = true
    local okUse, useResult = pcall(hook.Run, "PlayerUse", ply, ent)
    checkingUse = false
    return okUse and useResult ~= false
end

hook.Add("PlayerUse", "DashReality.ToolEntityPickup", function(ply, ent)
    if checkingUse or attempts[ply] or not ply:KeyPressed(IN_USE) or not eligible(ply, ent) then return end
    attempts[ply] = true
    if not usePermitted(ply, ent) then return end
    timer.Simple(0, function()
        if not eligible(ply, ent) or not ply:KeyDown(IN_USE) or ply:GetUseEntity() ~= ent then return end
        if pickupPermitted(ply, ent) and eligible(ply, ent) then ply:PickupObject(ent) end
    end)
end)

hook.Add("KeyRelease", "DashReality.ToolEntityPickup", function(ply, key)
    if key == IN_USE then attempts[ply] = nil end
end)
