local Bridge = NPCAnimationBridge
local Pose = {}
Bridge.CarrierPose = Pose

local function rotation(matrix)
    local result = Matrix()
    result:SetAngles(matrix:GetAngles())
    return result
end

function Pose.Attach(source, target)
    -- Networked entities may report unreadable bone names before their first setup.
    source:SetupBones()
    target:SetupBones()
    -- These names are already required by the server carrier contract. Retry early
    -- network readiness rather than installing a mapping made from unreadable names.
    for _, suffix in ipairs({"Pelvis", "Head1", "L_Hand", "R_Hand"}) do
        local name = "ValveBiped.Bip01_" .. suffix
        local sourceId, targetId = source:LookupBone(name), target:LookupBone(name)
        if sourceId == nil or targetId == nil or source:GetBoneName(sourceId) ~= name
            or target:GetBoneName(targetId) ~= name then return nil, "carrier_bone_names_not_ready" end
    end
    local _, sourceBind = util.GetModelMeshes(source:GetModel())
    local _, targetBind = util.GetModelMeshes(target:GetModel())
    if not sourceBind or not targetBind then return nil, "carrier_bind_pose_unavailable" end
    local bones = {}
    local mapping = {target_bones = target:GetBoneCount(), bound = 0, named = 0,
        driven = 0, fallback = 0, unreadable = 0, missing_bind = 0}
    for id = 0, target:GetBoneCount() - 1 do
        local bind = targetBind[id]
        local name = target:GetBoneName(id)
        -- Unnamed bind nodes can still be parents of visible bones (including root 0).
        -- Preserve their transforms; never drive or write them as named render bones.
        if bind then
            mapping.bound = mapping.bound + 1
            if name == "__INVALIDBONE__" then mapping.unreadable = mapping.unreadable + 1
            else mapping.named = mapping.named + 1 end
            local model = bind.matrix:GetInverseTR()
            local parentBind = targetBind[bind.parent]
            local localBind = parentBind and parentBind.matrix * model or model
            local driver = name ~= "__INVALIDBONE__" and source:LookupBone(name) or nil
            local sourcePose = driver and sourceBind[driver]
            if sourcePose then mapping.driven = mapping.driven + 1
            else mapping.fallback = mapping.fallback + 1 end
            bones[id] = {parent = bind.parent, position = localBind:GetTranslation(),
                localRotation = rotation(localBind), driver = driver,
                correction = sourcePose and rotation(sourcePose.matrix) * rotation(model),
                rootOffset = sourcePose and model:GetTranslation() - sourcePose.matrix:GetInverseTR():GetTranslation()}
        else
            mapping.missing_bind = mapping.missing_bind + 1
        end
    end
    if not bones[0] then return nil, "carrier_root_bind_unavailable" end
    local context = {source = source, target = target, bones = bones, mapping = mapping, updates = 0}
    local function update(entity, count)
        source:SetupBones()
        local origin = Matrix()
        origin:SetAngles(source:GetAngles())
        origin:SetTranslation(source:GetPos())
        local results = {}
        local function build(id)
            if results[id] then return results[id] end
            local bone = bones[id]
            if not bone then return nil end
            local parent = bone.parent >= 0 and build(bone.parent) or origin
            if not parent then return nil end
            local driven = bone.driver and source:GetBoneMatrix(bone.driver)
            local matrix
            if driven and bone.correction then
                matrix = rotation(driven) * bone.correction
            else
                matrix = rotation(parent) * bone.localRotation
            end
            if bone.parent < 0 and driven and bone.rootOffset then
                matrix:SetTranslation(driven:GetTranslation() + rotation(origin) * bone.rootOffset)
            else
                matrix:SetTranslation(parent * bone.position)
            end
            results[id] = matrix
            return matrix
        end
        -- Build before writing; engine write failures still cannot be rolled back.
        for id = 0, count - 1 do build(id) end
        for id = 0, count - 1 do
            local matrix = results[id]
            if matrix and entity:GetBoneName(id) ~= "__INVALIDBONE__" then entity:SetBoneMatrix(id, matrix) end
        end
    end
    context.callback = target:AddCallback("BuildBonePositions", function(entity, count)
        if context.updating or context.failure or not IsValid(source) then return end
        context.updating = true
        local ok, failure = xpcall(function() update(entity, count) end, debug.traceback)
        context.updating = false
        if ok then context.updates = context.updates + 1
        else context.failure = tostring(failure):sub(1, 2048) end
    end)
    return context
end

function Pose.Detach(context)
    if context and IsValid(context.target) then
        context.target:RemoveCallback("BuildBonePositions", context.callback)
    end
end
