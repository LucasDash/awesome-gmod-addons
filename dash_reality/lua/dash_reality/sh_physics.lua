-- Dash Reality physics library: units, mass, link solvers and impulse application.
--
-- Conventions (shared with functional_hands, so both addons agree):
--   * Positions and velocities stay in Source units (SU) and SU/s.
--   * Mass is in kg. Impulse is in kg*SU/s, which is exactly what
--     PhysObj:ApplyForceOffset expects.
--   * Stiffness (kg/s^2) and damping (kg/s) do not depend on the length unit,
--     so SI values can be used as-is.
--   * Forces given in Newtons are converted with P.NewtonsToSource.
--
-- Everything in the "Solvers" section is pure math (no engine calls) so it can be
-- unit-tested outside Garry's Mod; see tests/physics_spec.lua.

DashReality = DashReality or RealityTools or {}
local RT = DashReality
RT.Physics = RT.Physics or {}
local P = RT.Physics

P.Version = 1

-- 0.0254 m per SU, the documented VPhysics inertia convention (not the 16 SU/ft map-art one).
P.MetersPerSU = 0.0254

P.Defaults = {
    referenceMass = 80,                  -- kg of a Citizen-sized body
    referenceVolume = 32 * 32 * 72,      -- SU^3 of the Citizen hull
    minMass = 1,
    maxMass = 20000,
    stiffness = 600,                     -- kg/s^2, a firm but stretchy rope
    damping = nil,                       -- nil = critically damped for the reduced mass
    maxForce = 4000,                     -- N; an unbounded pull is what made stretched ropes "pop"
    maxDeltaSpeed = 6,                   -- m/s of speed change per tick
    baumgarte = 0.2,                     -- fraction of rigid-rope stretch corrected per tick
}

function P.ToMeters(su) return su * P.MetersPerSU end
function P.ToSource(meters) return meters / P.MetersPerSU end
-- N = kg*m/s^2, so in kg*SU/s^2 the same force is N / lambda.
function P.NewtonsToSource(newtons) return newtons / P.MetersPerSU end

------------------------------------------------------------------------------
-- Vector helpers
------------------------------------------------------------------------------

function P.ClampVector(v, limit)
    local length = v:Length()
    if length > limit and length > 0 then return v * (limit / length) end
    return v
end

-- Returns the unit direction and the length; a zero vector yields `fallback` (or a zero vector).
function P.Direction(v, fallback)
    local length = v:Length()
    if length < 1e-6 then return fallback or (v * 0), 0 end
    return v * (1 / length), length
end

------------------------------------------------------------------------------
-- Solvers (pure math)
------------------------------------------------------------------------------

local function cfg(opts, key)
    local value = opts and opts[key]
    if value == nil then return P.Defaults[key] end
    return value
end

-- Spring-damper between two endpoints, integrated implicitly so large stiffness never explodes.
-- `error` is the vector the pair should close (target - current, from A toward B's position),
-- `relativeVelocity` is vB - vA. Returns the impulse applied to B (A receives its negative).
function P.SolveSpring(error, relativeVelocity, inverseA, inverseB, dt, stiffness, damping)
    local inverse = math.max(inverseA, 0) + math.max(inverseB, 0)
    if inverse <= 0 then return error * 0 end
    local mass = 1 / inverse
    stiffness = stiffness or P.Defaults.stiffness
    damping = damping or 2 * math.sqrt(stiffness * mass)
    local denominator = 1 + damping * dt / mass + stiffness * dt * dt / mass
    local force = (error * stiffness - relativeVelocity * (damping + stiffness * dt)) / denominator
    return force * dt
end

-- A rope between points A and B. It only ever pulls: a slack or compressed rope returns no impulse.
--   a, b      : { pos = Vector, vel = Vector, inverseMass = number }
--   length    : rest length in SU
--   opts      : stiffness (kg/s^2, nil/<=0 = rigid), damping, maxForce (N), maxDeltaSpeed (m/s), baumgarte
-- Returns a table:
--   impulse  : on B, along A->B direction reversed (toward A); A gets -impulse
--   dvA, dvB : resulting velocity changes (SU/s)
--   stretch  : current length minus rest length (SU)
--   tension  : estimated rope tension (N)
--   taut     : whether the rope was loaded
function P.SolveRope(a, b, length, dt, opts)
    local zero = a.pos * 0
    local result = { impulse = zero, dvA = zero, dvB = zero, stretch = 0, tension = 0, taut = false }

    local inverse = math.max(a.inverseMass, 0) + math.max(b.inverseMass, 0)
    local axis, distance = P.Direction(b.pos - a.pos)
    local stretch = distance - length
    result.stretch = stretch
    if inverse <= 0 or distance < 1e-6 or stretch <= 0 then return result end

    local mass = 1 / inverse
    local normalSpeed = (b.vel - a.vel):Dot(axis)
    local stiffness = cfg(opts, "stiffness")
    local magnitude -- impulse along +axis acting on B; a pulling rope makes this negative

    if stiffness and stiffness > 0 then
        local damping = cfg(opts, "damping") or 2 * math.sqrt(stiffness * mass)
        local denominator = 1 + damping * dt / mass + stiffness * dt * dt / mass
        magnitude = -((stiffness * stretch + (damping + stiffness * dt) * normalSpeed) / denominator) * dt
    else
        -- Rigid: cancel separating speed and bleed off the stretch over a few ticks (Baumgarte).
        magnitude = -(normalSpeed + cfg(opts, "baumgarte") * stretch / dt) / inverse
    end

    -- Ropes cannot push, and an NPC approaching its anchor needs no braking.
    if magnitude > 0 then magnitude = 0 end

    local cap = P.NewtonsToSource(cfg(opts, "maxForce")) * dt
    local speedCap = P.ToSource(cfg(opts, "maxDeltaSpeed")) * mass
    magnitude = -math.min(-magnitude, cap, speedCap)

    local impulse = axis * magnitude
    result.impulse = impulse
    result.dvB = impulse * b.inverseMass
    result.dvA = -impulse * a.inverseMass
    result.tension = P.ToMeters(-magnitude / dt)
    result.taut = magnitude < 0
    return result
end

------------------------------------------------------------------------------
-- Mass
------------------------------------------------------------------------------

local function hullVolume(ent)
    local size = ent:OBBMaxs() - ent:OBBMins()
    return math.abs(size.x * size.y * size.z)
end

local function physicsMass(ent)
    local total = 0
    for bone = 0, math.min(ent:GetPhysicsObjectCount(), 128) - 1 do
        local phys = ent:GetPhysicsObjectNum(bone)
        if IsValid(phys) then total = total + phys:GetMass() end
    end
    return total
end

-- Bodies moved by engine locomotion rather than VPhysics: NPCs, NextBots and players.
function P.IsLiving(ent)
    return IsValid(ent) and (ent:IsNPC() or ent:IsPlayer() or ent:IsNextBot())
end

-- NPCs and players have no VPhysics weight worth using, so their mass is a reference body scaled by
-- hull volume. Physics props use their real mass. Override with P.SetMass.
function P.GetMass(ent, bone)
    if not IsValid(ent) then return math.huge end
    local weight = ent.DR_Weight
    if weight then return weight.modified end

    local d = P.Defaults
    if P.IsLiving(ent) or ent:GetPhysicsObjectCount() == 0 then
        local scaled = d.referenceMass * hullVolume(ent) / d.referenceVolume
        -- RT.Float is absent when the offline spec loads this file; the multiplier is a dashboard setting.
        if RT.Float then scaled = scaled * RT.Float("rt_phys_npc_mass_scale") end
        return math.Clamp(scaled, d.minMass, d.maxMass)
    end
    if bone then
        local phys = ent:GetPhysicsObjectNum(bone)
        if IsValid(phys) then return phys:GetMass() end
    end
    return math.Clamp(physicsMass(ent), d.minMass, d.maxMass)
end

-- 1/mass for a solver endpoint. World, pinned physics objects and time-frozen NPCs are immovable (0).
function P.InverseMass(ent, bone)
    if not IsValid(ent) or ent:IsWorld() then return 0 end
    if ent:GetNW2Bool("RT_TimeFrozen") then return 0 end
    if not P.IsLiving(ent) then
        local phys = ent:GetPhysicsObjectNum(bone or 0)
        if not IsValid(phys) or not phys:IsMotionEnabled() then return 0 end
    end
    return 1 / math.max(P.GetMass(ent, bone), P.Defaults.minMass)
end

-- Mass felt at a point on a rigid body: lever arms make an off-centre push act heavier-or-lighter
-- than the body's mass (ported from functional_hands F.PointMass). `localAnchor` is in the physobj's space.
function P.PointMass(phys, localAnchor)
    local mass = phys:GetMass()
    -- GetInertia is kg*m^2; lever arms are in SU.
    local inertia = phys:GetInertia() / (P.MetersPerSU * P.MetersPerSU)
    local smallest = math.max(math.min(inertia.x, inertia.y, inertia.z), 1e-6)
    local lever = localAnchor - phys:GetMassCenter()
    return 1 / (1 / math.max(mass, 1e-6) + lever:LengthSqr() / smallest)
end

if SERVER then
    -- Original/Modified weight, after Improved Weight: the original is remembered so it can be restored,
    -- and the modified value is networked for tooltips and survives duplication.
    local function remember(ent)
        if not ent.DR_Weight then
            local base = P.GetMass(ent)
            ent.DR_Weight = { original = base, modified = base }
            ent:SetNW2Float("DR_OriginalMass", base)
            ent:SetNW2Float("DR_Mass", base)
        end
        return ent.DR_Weight
    end

    function P.SetMass(ent, kg)
        if not IsValid(ent) or not isnumber(kg) or kg ~= kg then return false end
        kg = math.Clamp(kg, P.Defaults.minMass, P.Defaults.maxMass)
        -- Read the real mass before the override takes effect, or "original" would capture the override.
        local weight = ent.DR_Weight
        if not weight then
            local base = P.GetMass(ent)
            weight = { original = base, modified = base }
            ent.DR_Weight = weight
            ent:SetNW2Float("DR_OriginalMass", base)
        end
        local ratio = kg / math.max(weight.modified, 1e-6)
        weight.modified = kg
        ent:SetNW2Float("DR_Mass", kg)
        -- Props keep their VPhysics mass in step so collisions and Physgun weight agree with the solver.
        if not P.IsLiving(ent) then
            for bone = 0, math.min(ent:GetPhysicsObjectCount(), 128) - 1 do
                local phys = ent:GetPhysicsObjectNum(bone)
                if IsValid(phys) then phys:SetMass(math.Clamp(phys:GetMass() * ratio, 0.05, 50000)) end
            end
        end
        if duplicator and duplicator.StoreEntityModifier then
            duplicator.StoreEntityModifier(ent, "dr_mass", { Mass = kg })
        end
        return true
    end

    function P.RestoreMass(ent)
        local weight = IsValid(ent) and ent.DR_Weight
        if not weight then return false end
        P.SetMass(ent, weight.original)
        ent.DR_Weight = nil
        ent:SetNW2Float("DR_Mass", 0)
        ent:SetNW2Float("DR_OriginalMass", 0)
        if duplicator and duplicator.ClearEntityModifier then duplicator.ClearEntityModifier(ent, "dr_mass") end
        return true
    end

    if duplicator and duplicator.RegisterEntityModifier then
        duplicator.RegisterEntityModifier("dr_mass", function(_, ent, data)
            if IsValid(ent) and data and data.Mass then P.SetMass(ent, data.Mass) end
        end)
    end

    --------------------------------------------------------------------------
    -- Applying impulses
    --------------------------------------------------------------------------

    -- Adds `dv` (SU/s) to a body.
    --  * Players take SetVelocity (which adds).
    --  * A body leaving the ground (dv.z > 1) takes engine velocity: NPC locomotion rewrites the velocity
    --    of grounded NPCs every think, so the lift has to clear FL_ONGROUND or it is cancelled the same tick.
    --  * A grounded NPC pushed sideways cannot be moved through velocity at all (verified live), so the
    --    horizontal part is stored as "carry" velocity and integrated against world collision in P.StepCarry.
    function P.AddVelocity(ent, dv)
        if not IsValid(ent) then return end
        if ent:IsPlayer() then
            ent:SetVelocity(dv) -- Player:SetVelocity adds
            return
        end
        if dv.z > 1 then
            ent:RemoveFlags(FL_ONGROUND)
            ent:SetLocalVelocity(ent:GetVelocity() + dv)
        elseif ent:IsOnGround() then
            ent.DR_CarryVel = (ent.DR_CarryVel or vector_origin) + Vector(dv.x, dv.y, 0)
            P.Carried[ent] = true
        else
            ent:SetLocalVelocity(ent:GetVelocity() + dv)
        end
    end

    -- Velocity as the solver should see it: the engine's plus any carry velocity.
    function P.GetVelocity(ent)
        return ent:GetVelocity() + (ent.DR_CarryVel or vector_origin)
    end

    P.Carried = P.Carried or {}
    P.CarryFriction = 10 -- 1/s fallback; the live value is rt_phys_carry_friction
    P.CarryStepHeight = 18

    -- Advances grounded bodies by their carry velocity with hull collision, so a rope can drag an NPC
    -- along the floor without ever teleporting it through walls or off ledges.
    function P.StepCarry(dt)
        for ent in pairs(P.Carried) do
            local vel = IsValid(ent) and ent.DR_CarryVel
            if not vel or ent:GetNW2Bool("RT_TimeFrozen") or vel:Length() < 1 then
                if IsValid(ent) then ent.DR_CarryVel = nil end
                P.Carried[ent] = nil
            else
                local pos = ent:GetPos()
                local up = Vector(0, 0, P.CarryStepHeight)
                local hull = { mins = ent:OBBMins(), maxs = ent:OBBMaxs(), mask = MASK_NPCSOLID, filter = ent }
                hull.start, hull.endpos = pos + up, pos + up + vel * dt
                local across = util.TraceHull(hull)
                if across.StartSolid then
                    ent.DR_CarryVel = nil
                    P.Carried[ent] = nil
                else
                    hull.start, hull.endpos = across.HitPos, across.HitPos - up - Vector(0, 0, 2)
                    local settle = util.TraceHull(hull)
                    if not settle.StartSolid then ent:SetPos(settle.HitPos) end
                    if across.Hit then
                        -- Slide: drop the part of the velocity that points into the wall.
                        vel = vel - across.HitNormal * math.min(vel:Dot(across.HitNormal), 0)
                    end
                    local friction = RT.Float and RT.Float("rt_phys_carry_friction") or P.CarryFriction
                    ent.DR_CarryVel = vel * math.max(0, 1 - friction * dt)
                end
            end
        end
    end

    hook.Add("Tick", "DashReality.Physics.Carry", function() P.StepCarry(engine.TickInterval()) end)

    -- Applies an impulse (kg*SU/s) at a world position on `bone` of `ent`; returns the velocity change
    -- for living bodies. Immovable endpoints ignore it.
    function P.ApplyImpulse(ent, bone, impulse, worldPos)
        if not IsValid(ent) then return end
        if P.IsLiving(ent) then
            local dv = impulse * P.InverseMass(ent)
            P.AddVelocity(ent, dv)
            return dv
        end
        local phys = ent:GetPhysicsObjectNum(bone or 0)
        if IsValid(phys) and phys:IsMotionEnabled() then
            phys:ApplyForceOffset(impulse, worldPos or phys:GetPos())
        end
    end
end
