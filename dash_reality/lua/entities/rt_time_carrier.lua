AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Frozen NPC Carrier"
ENT.Spawnable = false

if SERVER then
    -- An invisible rigid box sized to the frozen NPC; the Physgun grabs it like any prop.
    function ENT:Initialize()
        local mins = self.RT_Mins or Vector(-16, -16, 0)
        local maxs = self.RT_Maxs or Vector(16, 16, 72)

        self:SetModel("models/hunter/blocks/cube025x025x025.mdl")

        -- PhysicsInitBox only yields the model-sized cube for traces; a convex mesh plus custom collisions
        -- makes the whole NPC-sized box hittable, which is what the Physgun's trace needs.
        local verts = {
            Vector(mins.x, mins.y, mins.z), Vector(mins.x, mins.y, maxs.z),
            Vector(mins.x, maxs.y, mins.z), Vector(mins.x, maxs.y, maxs.z),
            Vector(maxs.x, mins.y, mins.z), Vector(maxs.x, mins.y, maxs.z),
            Vector(maxs.x, maxs.y, mins.z), Vector(maxs.x, maxs.y, maxs.z),
        }
        if not self:PhysicsInitConvex(verts) then return end

        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)
        self:EnableCustomCollisions(true)
        self:DrawShadow(false)
        self:SetUseType(SIMPLE_USE)

        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            phys:SetMass(85)
            phys:Wake()
        end
    end

    -- Use the native carry controller, with the engine's pickup policy and an
    -- explicit reach check: PickupObject itself bypasses both distance and mass.
    function ENT:Use(ply)
        if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() or ply:InVehicle()
            or not IsValid(self.RT_NPC) or not DashReality.IsTimeFrozen(self)
            or self:IsPlayerHolding() then return end
        local allowed = GetConVar("sv_playerpickupallowed")
        if allowed and not allowed:GetBool() then return end
        local eye = ply:GetShootPos()
        if self:NearestPoint(eye):DistToSqr(eye) > 96 * 96 then return end
        local ok, result = pcall(gamemode.Call, "AllowPlayerPickup", ply, self)
        if not ok or result == false then return end
        local phys = self:GetPhysicsObject()
        if not IsValid(phys) then return end
        local wasMoving = phys:IsMotionEnabled()
        phys:EnableMotion(true)
        phys:Wake()
        local called = pcall(ply.PickupObject, ply, self)
        timer.Simple(0, function()
            if IsValid(self) and IsValid(phys) and not self:IsPlayerHolding() and not wasMoving then
                phys:EnableMotion(false)
            end
        end)
        if not called and IsValid(phys) and not wasMoving then phys:EnableMotion(false) end
    end

    hook.Add("OnPlayerPhysicsDrop", "DashReality.FrozenCarrierUse", function(_, ent)
        if not IsValid(ent) or ent:GetClass() ~= "rt_time_carrier" then return end
        timer.Simple(0, function()
            if not IsValid(ent) or ent:IsPlayerHolding() or not IsValid(ent.RT_NPC)
                or not DashReality.IsTimeFrozen(ent) then return end
            local phys = ent:GetPhysicsObject()
            if not IsValid(phys) then return end
            phys:SetVelocity(vector_origin)
            phys:AddAngleVelocity(-phys:GetAngleVelocity())
            phys:EnableMotion(false)
        end)
    end)
else
    function ENT:Draw() end
end
