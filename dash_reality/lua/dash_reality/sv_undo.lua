-- Physgun Undo: every completed physgun move becomes an undo entry (default key: Z).
-- Recorded after the pickup is accepted, so entities refused by other hooks never get stuck "held".

local RT = DashReality

local origin = {}
local MIN_MOVE, MIN_TURN = 1, 1

local function snapshot(ent)
    if ent:IsRagdoll() then
        local bones = {}
        for index = 0, ent:GetPhysicsObjectCount() - 1 do
            local bone = ent:GetPhysicsObjectNum(index)
            if IsValid(bone) then
                bones[#bones + 1] = { bone = bone, pos = bone:GetPos(), ang = bone:GetAngles(), motion = bone:IsMotionEnabled() }
            end
        end
        return { bones = bones, pos = ent:GetPos() }
    end

    local phys = ent:GetPhysicsObject()
    return {
        phys = IsValid(phys) and phys or nil,
        pos = ent:GetPos(),
        ang = ent:GetAngles(),
        motion = IsValid(phys) and phys:IsMotionEnabled() or nil,
    }
end

local function restore(_, ent, data)
    if not IsValid(ent) then return end

    if data.bones then
        for _, info in ipairs(data.bones) do
            if IsValid(info.bone) then
                info.bone:SetPos(info.pos)
                info.bone:SetAngles(info.ang)
                info.bone:SetVelocity(vector_origin)
                info.bone:EnableMotion(info.motion)
            end
        end
        return
    end

    ent:SetPos(data.pos)
    ent:SetAngles(data.ang)
    if IsValid(data.phys) then
        data.phys:SetVelocity(vector_origin)
        data.phys:EnableMotion(data.motion)
    end
end

local function trackable(ent)
    if not IsValid(ent) or ent:IsPlayer() or ent:IsNPC() then return false end
    -- Swapped ragdolls vanish when the NPC stands up; there is nothing to return to.
    return not ent.RT_RagState
end

hook.Add("OnPhysgunPickup", "DashReality.UndoRecord", function(ply, ent)
    if not RT.Bool("rt_undo_enable") or not trackable(ent) then return end
    if not origin[ent] then origin[ent] = snapshot(ent) end
end)

hook.Add("PhysgunDrop", "DashReality.UndoCommit", function(ply, ent)
    local data = origin[ent]
    if not data then return end
    origin[ent] = nil
    if not IsValid(ent) or not IsValid(ply) then return end

    local moved = data.pos:DistToSqr(ent:GetPos()) > MIN_MOVE ^ 2
    local turned = false
    if data.ang then
        local now = ent:GetAngles()
        turned = math.abs(math.AngleDifference(data.ang.p, now.p)) > MIN_TURN
            or math.abs(math.AngleDifference(data.ang.y, now.y)) > MIN_TURN
            or math.abs(math.AngleDifference(data.ang.r, now.r)) > MIN_TURN
    end
    if not (moved or turned or data.bones) then return end

    undo.Create("Physgun move")
    undo.SetPlayer(ply)
    undo.AddFunction(restore, ent, data)
    undo.SetCustomUndoText("Undone physgun move")
    undo.Finish()
end)

hook.Add("EntityRemoved", "DashReality.UndoForget", function(ent)
    origin[ent] = nil
end)
