-- Ropes that attach to NPCs and NextBots.
--
-- Sandbox ropes are VPhysics constraints, and NPCs are not simulated by VPhysics: they have no
-- usable physics object, so the constraint cannot be built and cannot pull them. Instead of faking
-- a physics body (Attach Anything's invisible anchors plus SetPos "pulls" is what stretches and
-- glitches), a rope with a living endpoint becomes a *link*: a visual keyframe rope plus a per-tick
-- solve from DashReality.Physics.SolveRope that applies velocity changes to both ends. Props are
-- pushed with real impulses, NPCs with AddVelocity, and immovable ends (world, frozen NPCs, pinned
-- bones) simply do not move.
local RT = DashReality
local P = RT.Physics
local Ropes = RT.NPCRopes
Ropes.Links = Ropes.Links or {}

-- Keep the engine function so ropes between two ordinary props are left entirely to VPhysics.
Ropes.OriginalRope = Ropes.OriginalRope or constraint.Rope

-- Samples one rope end in the form SolveRope expects. Returns nil if the end can no longer be read.
local function sample(point)
    local ent = point.ent
    if not Ropes.IsEnd(ent) then return nil end
    if ent:IsWorld() then
        -- For the world, the "local" position is already a world position.
        return { pos = point.lpos, vel = vector_origin, inverseMass = 0 }
    end
    if P.IsLiving(ent) then
        return { pos = ent:LocalToWorld(point.lpos), vel = P.GetVelocity(ent), inverseMass = P.InverseMass(ent) }
    end
    local phys = ent:GetPhysicsObjectNum(point.bone)
    if not IsValid(phys) then return nil end
    local pos = phys:LocalToWorld(point.lpos)
    local inverse = 0
    if phys:IsMotionEnabled() then inverse = 1 / math.max(P.PointMass(phys, point.lpos), P.Defaults.minMass) end
    return { pos = pos, vel = phys:GetVelocityAtPoint(pos), inverseMass = inverse }
end

local function removeLink(handle)
    Ropes.Links[handle] = nil
end

-- Rope feel is fixed: ropes follow the stock Rope tool's own Rigid option. Only the force cap is a
-- dashboard setting (rt_phys_max_force), since it protects light NPCs from heavy props.
local ELASTIC_STIFFNESS = 1500 -- kg/s^2; 600 let a running zombie stretch a rope by ~65 units
local RIGID_CORRECTION = 0.2   -- fraction of a rigid rope's stretch removed per tick

local rigidOptions, elasticOptions = {}, {}
local function refreshOptions()
    local maxForce = RT.Float("rt_phys_max_force")
    rigidOptions.stiffness, rigidOptions.maxForce, rigidOptions.baumgarte = 0, maxForce, RIGID_CORRECTION
    elasticOptions.stiffness, elasticOptions.maxForce, elasticOptions.baumgarte = ELASTIC_STIFFNESS, maxForce, RIGID_CORRECTION
end

-- keyframe_rope keeps its attachments in engine fields; setting the keyvalues and re-activating
-- moves an end to another entity without replacing the rope (so Undo and Reload keep working).
local SIDE_KEYS = { a = "Start", b = "End" }
local function retarget(rope, side, ent, bone, lpos)
    if not IsValid(rope) then return end
    local key = SIDE_KEYS[side]
    rope:SetEntity(key .. "Entity", ent)
    rope:SetKeyValue(key .. "Offset", tostring(lpos))
    rope:SetKeyValue(key .. "Bone", tostring(bone))
    rope:Activate()
end

-- While an NPC is swapped for its ragdoll (Physgun pickup) the NPC is hidden and its body is the ragdoll,
-- so a rope end on the NPC would hang from an invisible origin. The end moves to the nearest ragdoll bone
-- at the same world point, and goes back to its original NPC anchor when the NPC stands up.
local function moveToRagdoll(npc, rag)
    for handle, link in pairs(Ropes.Links) do
        for side in pairs(SIDE_KEYS) do
            local e = link[side]
            if e.ent == npc and not e.home then
                local world = npc:LocalToWorld(e.lpos)
                local bestBone, bestDist
                for index = 0, rag:GetPhysicsObjectCount() - 1 do
                    local phys = rag:GetPhysicsObjectNum(index)
                    if IsValid(phys) then
                        local d = phys:GetPos():DistToSqr(world)
                        if not bestDist or d < bestDist then bestBone, bestDist = index, d end
                    end
                end
                if bestBone then
                    local lpos = rag:GetPhysicsObjectNum(bestBone):WorldToLocal(world)
                    e.home = { ent = npc, bone = e.bone, lpos = e.lpos }
                    e.ent, e.bone, e.lpos = rag, bestBone, lpos
                    retarget(handle, side, rag, bestBone, lpos)
                end
            end
        end
    end
end

local function returnToNPC(handle, link, side)
    local e = link[side]
    local home = e.home
    e.home = nil
    if not (home and IsValid(home.ent)) then return end
    e.ent, e.bone, e.lpos = home.ent, home.bone, home.lpos
    retarget(handle, side, home.ent, home.bone, home.lpos)
end

local function moveBackToNPC(npc)
    for handle, link in pairs(Ropes.Links) do
        for side in pairs(SIDE_KEYS) do
            local e = link[side]
            if e.home and e.home.ent == npc then returnToNPC(handle, link, side) end
        end
    end
end

hook.Add("DashReality.RagdollEntered", "DashReality.NPCRopes", function(npc, rag)
    local ok, err = pcall(moveToRagdoll, npc, rag)
    if not ok then ErrorNoHalt("[dash_reality] rope handoff to ragdoll failed: ", tostring(err), "\n") end
end)
hook.Add("DashReality.RagdollLeft", "DashReality.NPCRopes", function(npc)
    local ok, err = pcall(moveBackToNPC, npc)
    if not ok then ErrorNoHalt("[dash_reality] rope handoff to NPC failed: ", tostring(err), "\n") end
end)

function Ropes.Step(dt)
    if next(Ropes.Links) == nil then return end
    refreshOptions()
    for handle, link in pairs(Ropes.Links) do
        -- A ragdoll can vanish between swap polls; fall back to the NPC it stood in for instead of dropping the rope.
        for side in pairs(SIDE_KEYS) do
            local e = link[side]
            if e.home and not Ropes.IsEnd(e.ent) then returnToNPC(handle, link, side) end
        end
        if not IsValid(handle) or not Ropes.IsEnd(link.a.ent) or not Ropes.IsEnd(link.b.ent) then
            removeLink(handle)
            if IsValid(handle) then handle:Remove() end
        else
            local a, b = sample(link.a), sample(link.b)
            if a and b then
                local result = P.SolveRope(a, b, link.length, dt, link.rigid and rigidOptions or elasticOptions)
                if result.taut then
                    P.ApplyImpulse(link.b.ent, link.b.bone, result.impulse, b.pos)
                    P.ApplyImpulse(link.a.ent, link.a.bone, -result.impulse, a.pos)
                end
                link.tension, link.stretch = result.tension, result.stretch
            end
        end
    end
end

hook.Add("Tick", "DashReality.NPCRopes", function() Ropes.Step(engine.TickInterval()) end)

-- Same arguments and return values as constraint.Rope, so tools and addons that call it work unchanged.
function Ropes.CreateLink(e1, e2, b1, b2, lp1, lp2, length, addLength, forcelimit, width, material, rigid, color)
    addLength = math.Clamp(addLength or 0, -56756, 56756)
    local total = math.max(length + addLength, 1)
    local kv = { Length = total, Collide = 1 }
    if rigid then kv.Type = 2 end

    -- A living end has no physics bone; its anchor is stored relative to the entity itself.
    if Ropes.IsTarget(e1) then b1 = 0 end
    if Ropes.IsTarget(e2) then b2 = 0 end

    local rope = constraint.CreateKeyframeRope(e1:LocalToWorld(lp1), width, material, nil, e1, lp1, b1, e2, lp2, b2, kv)
    if not IsValid(rope) then return false end
    if color then rope:SetColor(color) end

    -- Registering the constraint table lets the Rope tool's Reload and Undo find and remove it.
    local info = { Type = "Rope", Ent1 = e1, Ent2 = e2, Bone1 = b1, Bone2 = b2, LPos1 = lp1, LPos2 = lp2,
        length = length, addlength = addLength, forcelimit = forcelimit, width = width, material = material, rigid = rigid }
    rope:SetTable(info)
    constraint.AddConstraintTable(e1, rope, e2)

    Ropes.Links[rope] = {
        a = { ent = e1, bone = b1, lpos = lp1 },
        b = { ent = e2, bone = b2, lpos = lp2 },
        length = total, rigid = rigid and true or false,
    }
    rope:CallOnRemove("DashReality.NPCRopes", removeLink)
    return rope
end

function constraint.Rope(e1, e2, b1, b2, lp1, lp2, length, addLength, forcelimit, width, material, rigid, color)
    if Ropes.IsEnd(e1) and Ropes.IsEnd(e2) and e1 ~= e2
        and (Ropes.IsTarget(e1) or Ropes.IsTarget(e2)) then
        return Ropes.CreateLink(e1, e2, b1, b2, lp1, lp2, length, addLength, forcelimit, width, material, rigid, color)
    end
    return Ropes.OriginalRope(e1, e2, b1, b2, lp1, lp2, length, addLength, forcelimit, width, material, rigid, color)
end
