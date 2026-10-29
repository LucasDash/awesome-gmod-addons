-- Shared half of NPC ropes: the target test and the Rope tool patch.
--
-- The stock Rope tool rejects any entity without a physics object, which is why NPCs could never be
-- picked. This patch accepts them and defers everything else to the original tool, so behaviour for
-- props and the world is untouched. The rope itself is built by constraint.Rope (see sv_npc_ropes.lua).
local RT = DashReality
RT.NPCRopes = RT.NPCRopes or {}
local Ropes = RT.NPCRopes

-- Players are intentionally excluded; ropes never pull players.
function Ropes.IsTarget(ent)
    return IsValid(ent) and not ent:IsPlayer() and not ent:IsRagdoll() and (ent:IsNPC() or ent:IsNextBot())
end

-- The world entity fails IsValid() but is a legitimate (immovable) rope end.
function Ropes.IsEnd(ent)
    return IsValid(ent) or (ent ~= nil and ent ~= NULL and ent:IsWorld())
end

local function ropeClick(self, trace, chain, original)
    local ent = trace.Entity
    local pendingLiving = self:NumObjects() > 0 and Ropes.IsTarget(self:GetEnt(1))
    if not (Ropes.IsTarget(ent) or pendingLiving) then
        return original(self, trace)
    end
    if not Ropes.IsEnd(ent) or (ent:IsPlayer()) then return false end

    local living = Ropes.IsTarget(ent)
    local bone = living and 0 or trace.PhysicsBone
    if SERVER and not living and not util.IsValidPhysicsObject(ent, bone) then return false end

    -- A living entity is anchored by its own local space; a prop by its physics object, as in the stock tool.
    local phys = (not living) and ent:GetPhysicsObjectNum(bone) or nil
    local count = self:NumObjects()
    self:SetObject(count + 1, ent, trace.HitPos, phys, bone, trace.HitNormal)
    if count == 0 then
        self:SetStage(1)
        return true
    end

    if CLIENT then
        self:ClearObjects()
        return true
    end

    local ply = self:GetOwner()
    if not ply:CheckLimit("ropeconstraints") then
        self:ClearObjects()
        return false
    end

    local forcelimit = self:GetClientNumber("forcelimit")
    local addlength = self:GetClientNumber("addlength")
    local material = self:GetClientInfo("material")
    local width = self:GetClientNumber("width")
    local rigid = self:GetClientNumber("rigid") == 1
    local color = Color(self:GetClientNumber("color_r"), self:GetClientNumber("color_g"), self:GetClientNumber("color_b"))

    local ent1, ent2 = self:GetEnt(1), self:GetEnt(2)
    local bone1, bone2 = self:GetBone(1), self:GetBone(2)
    local length = (self:GetPos(1) - self:GetPos(2)):Length()
    local constr, rope = constraint.Rope(ent1, ent2, bone1, bone2, self:GetLocalPos(1), self:GetLocalPos(2),
        length, addlength, forcelimit, width, material, rigid, color)

    if IsValid(constr) then
        undo.Create("Rope")
            undo.AddEntity(constr)
            if IsValid(rope) then undo.AddEntity(rope) end
            undo.SetPlayer(ply)
            undo.SetCustomUndoText("Undone #tool.rope.name")
        undo.Finish("#tool.rope.name")
        ply:AddCount("ropeconstraints", constr)
        ply:AddCleanup("ropeconstraints", constr)
    end

    self:ClearObjects()
    if chain then
        self:SetObject(1, ent2, trace.HitPos, phys, bone2, trace.HitNormal)
        self:SetStage(1)
    end
    return true
end

local function patchTool(tool)
    if not tool then return end
    -- Keep the stock handlers so re-running this file replaces the patch instead of stacking it.
    tool.DR_StockLeft = tool.DR_StockLeft or tool.LeftClick
    tool.DR_StockRight = tool.DR_StockRight or tool.RightClick
    tool.DR_RopePatched = true
    tool.LeftClick = function(self, trace) return ropeClick(self, trace, false, tool.DR_StockLeft) end
    tool.RightClick = function(self, trace) return ropeClick(self, trace, true, tool.DR_StockRight) end
end

-- Balloon and Light tools tie a rope to whatever they hit but refuse anything that fails
-- util.IsValidPhysicsObject, which is every NPC. Their rope is built by constraint.Rope, so letting the
-- click through is all they need.
local function patchAttachTool(tool)
    if not tool then return end
    tool.DR_StockAttach = tool.DR_StockAttach or tool.LeftClick
    tool.DR_AttachPatched = true
    tool.LeftClick = function(self, trace, ...)
        local ent = trace.Entity
        if not (SERVER and Ropes.IsTarget(ent)) then return tool.DR_StockAttach(self, trace, ...) end

        -- Report a valid body for this one entity, for this one call, so every other check stays stock.
        local stock = util.IsValidPhysicsObject
        util.IsValidPhysicsObject = function(e, bone)
            if e == ent then return true end
            return stock(e, bone)
        end
        local ok, result = pcall(tool.DR_StockAttach, self, trace, ...)
        util.IsValidPhysicsObject = stock
        if not ok then error(result, 0) end
        return result
    end
end

-- The Tool Gun copies the stored tool table into each weapon when it is created, so patch the stored
-- table for future guns and the live guns for this session.
function Ropes.PatchRopeTool()
    local function apply(tools)
        if not tools then return end
        patchTool(tools.rope)
        patchAttachTool(tools.balloon)
        patchAttachTool(tools.light)
    end
    local stored = weapons.GetStored("gmod_tool")
    if stored then apply(stored.Tool) end
    for _, gun in ipairs(ents.FindByClass("gmod_tool")) do apply(gun.Tool) end
end

Ropes.PatchRopeTool()
hook.Add("InitPostEntity", "DashReality.NPCRopes.PatchTool", Ropes.PatchRopeTool)
hook.Add("OnReloaded", "DashReality.NPCRopes.PatchTool", Ropes.PatchRopeTool)
