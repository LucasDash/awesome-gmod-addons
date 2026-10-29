-- Optional NPC Tool Gun actions. An unassigned NPC remains under the
-- Universal Tool Gun's existing hook chain and native Remover behavior.
local D = DashReality
local assignments = D.NPCToolgunAssignments or setmetatable({}, {__mode = "k"})
D.NPCToolgunAssignments = assignments

local MODE = "rt_timefreeze"
local RANGE = 1024
local MAX_MUZZLE_OFFSET = 512

local function authorized(ply)
    return IsValid(ply) and ply:IsPlayer() and ply:Alive()
        and (game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin())
end
local function ownedNPC(ply, npc)
    -- Scripted NPC frameworks can own the same Tool Gun action hook. Leave
    -- those integrations in control until they expose an explicit contract.
    return IsValid(npc) and npc:IsNPC() and not npc:IsScripted() and npc:Health() > 0 and npc:GetCreator() == ply
end
local function finiteVector(v)
    return isvector(v) and v.x == v.x and v.y == v.y and v.z == v.z
        and math.abs(v.x) < 100000000 and math.abs(v.y) < 100000000 and math.abs(v.z) < 100000000
end

-- Assignments belong to the original player creator, not to a model class,
-- faction or arbitrary entity index. No NPC is opted in on module load.
function D.SetNPCToolgunAction(ply, npc, action)
    if not authorized(ply) or not ownedNPC(ply, npc) then return false, "Only the authorized creator of a native NPC can change its action." end
    if action == "off" then assignments[npc] = nil return true end
    if action ~= "freeze" then return false, "Unknown NPC Tool Gun action." end
    assignments[npc] = {owner = ply, action = action}
    return true
end
function D.GetNPCToolgunAction(npc)
    local assignment = assignments[npc]
    return assignment and assignment.action or nil
end

-- The actor/weapon callback is server-side. A configured NPC always claims
-- its shot, including failures, so a missed freeze cannot become a Remover
-- shot. Unconfigured actors return nil and leave other integrations in control.
hook.Add("UniversalToolgunNPCPrimaryAction", "DashReality.NPCToolgun", function(actor, weapon, shootPos, shootDir)
    local assignment = assignments[actor]
    if not assignment then return end
    local owner = assignment.owner
    if assignment.action ~= "freeze" or not authorized(owner) or not ownedNPC(owner, actor) then
        return true, false, "NPC Tool Gun owner unavailable or unauthorized"
    end
    if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" or weapon:GetOwner() ~= actor then
        return true, false, "NPC is not using its Tool Gun"
    end
    if not isfunction(D.SetEntityFrozen) or not isfunction(weapon.GetToolObject) then
        return true, false, "Freeze action unavailable"
    end
    local ok, tool = pcall(weapon.GetToolObject, weapon, MODE)
    if not ok or not istable(tool) or not isfunction(tool.Allowed) then return true, false, "Freeze mode unavailable" end
    local allowedOK, allowed = pcall(tool.Allowed, tool)
    if not allowedOK or allowed ~= true then return true, false, "Freeze mode disabled" end

    local origin = actor:GetShootPos()
    if not finiteVector(origin) then return true, false, "NPC firing position unavailable" end
    local start = shootPos or origin
    local direction = shootDir or actor:GetAimVector()
    if not finiteVector(start) or start:DistToSqr(origin) > MAX_MUZZLE_OFFSET * MAX_MUZZLE_OFFSET
        or not finiteVector(direction) or direction:LengthSqr() < 0.000001 then
        return true, false, "Invalid NPC firing direction"
    end
    direction = direction:GetNormalized()
    local trace = util.TraceLine({start=start, endpos=start + direction * RANGE, mask=MASK_SHOT, filter={actor, weapon}})
    local target = trace and trace.Entity
    if not trace or not trace.Hit or trace.StartSolid or not IsValid(target) or target:IsWorld()
        or target == actor or target == weapon or target:IsPlayer() then
        return true, false, "No permitted freeze target"
    end
    if target:IsVehicle() then
        local driver = target:GetDriver()
        if IsValid(driver) and driver:IsPlayer() then return true, false, "Occupied player vehicle" end
    end
    local parent = target:GetParent()
    if IsValid(parent) and parent:IsPlayer() then return true, false, "Player attachment" end

    -- SetEntityFrozen checks the actual target and Sandbox CanTool using this
    -- original player owner, not the NPC or a fabricated player object.
    local called, accepted, reason = pcall(D.SetEntityFrozen, owner, target, true, tool, trace)
    if not called then
        ErrorNoHalt("Dash Reality NPC freeze action: " .. tostring(accepted) .. "\n")
        return true, false, "Freeze action failed"
    end
    return true, accepted == true, reason
end)

-- A player looks directly at their NPC when assigning it. This avoids trusting
-- a client-supplied entity index or targeting through a wall.
concommand.Add("dash_npc_toolgun_action", function(ply, _, args)
    if not authorized(ply) then return end
    local action = args[1] or ""
    local trace = ply:GetEyeTrace()
    if not trace or not trace.Hit or not IsValid(trace.Entity) or not finiteVector(trace.HitPos)
        or trace.HitPos:DistToSqr(ply:GetShootPos()) > RANGE * RANGE then
        ply:ChatPrint("Aim at your nearby NPC to change its Tool Gun action.")
        return
    end
    local ok, reason = D.SetNPCToolgunAction(ply, trace.Entity, action)
    if ok then
        ply:ChatPrint(action == "freeze" and "NPC Tool Gun action: Freeze Entity." or "NPC Tool Gun action cleared.")
    else
        ply:ChatPrint(reason or "NPC Tool Gun action was not changed.")
    end
end, nil, "Assign freeze/off to the nearby NPC you created (host or superadmin only).")

hook.Add("EntityRemoved", "DashReality.NPCToolgun", function(ent)
    assignments[ent] = nil
end)
