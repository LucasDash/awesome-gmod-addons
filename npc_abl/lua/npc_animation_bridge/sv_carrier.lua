local Bridge = NPCAnimationBridge
local Carrier = {}
Bridge.Carrier = Carrier
local core = {
    "Pelvis", "Spine", "Spine1", "Spine2", "Head1",
    "L_Clavicle", "L_UpperArm", "L_Forearm", "L_Hand",
    "R_Clavicle", "R_UpperArm", "R_Forearm", "R_Hand",
    "L_Thigh", "L_Calf", "L_Foot", "R_Thigh", "R_Calf", "R_Foot"
}

function Carrier.Check(entity)
    for _, suffix in ipairs(core) do
        local name = "ValveBiped.Bip01_" .. suffix
        if entity:LookupBone(name) == nil then return false, "carrier_missing_bone: " .. name end
    end
    return true
end

function Carrier.Create(context)
    local entity = context.entity
    local visual = ents.Create("prop_dynamic")
    if not IsValid(visual) then return nil, "carrier_visual_creation_failed" end
    -- Register the allocation before any engine writes so preview error cleanup
    -- can remove even a partially initialized visual.
    context.visual = visual
    visual:SetModel(context.model)
    visual:SetPos(entity:GetPos())
    visual:SetAngles(entity:GetAngles())
    visual:SetKeyValue("solid", "0")
    visual:SetKeyValue("DisableBoneFollowers", "1")
    visual:Spawn()
    visual:SetSolid(SOLID_NONE)
    visual:SetMoveType(MOVETYPE_NONE)
    visual:SetParent(entity)
    visual:SetLocalPos(Vector(0, 0, 0))
    visual:SetLocalAngles(Angle(0, 0, 0))
    visual:AddEffects(EF_PARENT_ANIMATES)
    visual:SetSkin(context.skin)
    for id, value in pairs(context.bodygroups) do visual:SetBodygroup(id, value) end
    visual:SetColor(entity:GetColor())
    visual:SetRenderMode(entity:GetRenderMode())
    visual:SetMaterial(entity:GetMaterial())
    for slot, material in pairs(context.originalSubmaterials) do visual:SetSubMaterial(slot, material) end
    if IsValid(context.owner) and context.owner:IsPlayer() then visual:SetCreator(context.owner) end
    visual:SetNW2Bool("NPCAnimationBridge.Visual", true)
    entity:DeleteOnRemove(visual)
    context.carrierNoShadow = not entity:IsEffectActive(EF_NOSHADOW)
    if context.carrierNoShadow then entity:AddEffects(EF_NOSHADOW) end
    entity:SetNW2Entity("NPCAnimationBridge.Visual", visual)
    return visual
end

function Carrier.Remove(context)
    local entity, visual = context.entity, context.visual
    if IsValid(entity) and entity:GetNW2Entity("NPCAnimationBridge.Visual") == visual then
        entity:SetNW2Entity("NPCAnimationBridge.Visual", NULL)
    end
    if IsValid(visual) then visual:Remove() end
    if IsValid(entity) and context.carrierNoShadow then entity:RemoveEffects(EF_NOSHADOW) end
end
