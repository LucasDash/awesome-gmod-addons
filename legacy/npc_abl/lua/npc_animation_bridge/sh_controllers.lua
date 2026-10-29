local Bridge = NPCAnimationBridge
local Controllers = {version = 1}
Bridge.Controllers = Controllers

local function finite(n)
    return Bridge.Catalog.IsFinite(n) and math.abs(n) <= 1000000
end

local function nameValid(name)
    return type(name) == "string" and #name > 0 and #name <= 96
end

-- Read-only inventory. GLua SequenceInfo exposes blend counts, not the authored
-- blend-axis names; those must come from a model/sequence-specific adapter.
function Controllers.DescribeSequence(entity, request)
    local ok, clip, reason = pcall(Bridge.Catalog.Resolve, entity, request)
    if not ok then return nil, "sequence_query_failed" end
    if not clip then return nil, reason end
    if not Bridge.Catalog.IsFinite(clip.flags) or clip.flags < 0 or clip.flags > 4294967295 or clip.flags % 1 ~= 0
        or not finite(clip.numblends) or clip.numblends < 1 or clip.numblends > 65535 or clip.numblends % 1 ~= 0 then
        return nil, "invalid_sequence_metadata"
    end
    if type(entity.GetNumPoseParameters) ~= "function" or type(entity.GetPoseParameterName) ~= "function"
        or type(entity.GetPoseParameterRange) ~= "function" then return nil, "pose_metadata_unavailable" end
    local queried, count = pcall(entity.GetNumPoseParameters, entity)
    if not queried then return nil, "pose_query_failed" end
    if not finite(count) or count < 0 or count > 128 or count % 1 ~= 0 then return nil, "invalid_pose_metadata" end
    local poses, byIndex, names = {}, {}, {}
    for index=0,count-1 do
        local named, name = pcall(entity.GetPoseParameterName, entity, index)
        local ranged, low, high = pcall(entity.GetPoseParameterRange, entity, index)
        if not named or not ranged then return nil, "pose_query_failed" end
        if not nameValid(name) or names[name] or not finite(low) or not finite(high) then return nil, "invalid_pose_metadata" end
        local item={index=index, name=name, minimum=math.min(low,high), maximum=math.max(low,high)}
        poses[#poses+1], byIndex[index], names[name] = item, item, true
    end
    local cycleDriven = math.floor(clip.flags/128)%2 == 1
    local cyclePose
    if cycleDriven then
        local described, info = pcall(entity.GetSequenceInfo, entity, clip.sequence)
        if not described then return nil, "sequence_query_failed" end
        local index = type(info)=="table" and info.cycleposeindex
        if not finite(index) or index < 0 or index % 1 ~= 0 or not byIndex[index] then
            return nil, "cycle_pose_unavailable"
        end
        cyclePose=byIndex[index].name
    end
    return {schema=1, clip=clip, poses=poses, blended=clip.numblends>1,
        blendAxesKnown=false, cycleDriven=cycleDriven, cyclePose=cyclePose,
        baseRequired=Bridge.Catalog.BaseReason(clip)~=nil,baseReason=Bridge.Catalog.BaseReason(clip)}
end

function Controllers.ResolveSequence(entity, request)
    local description, reason = Controllers.DescribeSequence(entity, request)
    if not description then return nil, reason end
    local recipe=request.controller
    if (description.blended or description.cycleDriven) and recipe==nil then return nil,"controller_mapping_required" end
    local binding
    if recipe~=nil then
        if type(recipe)~="table" or recipe.model~=description.clip.model or recipe.sequence~=description.clip.label then
            return nil,"controller_mapping_mismatch"
        end
        local list=recipe.blendPoses or {}
        if type(list)~="table" then return nil,"invalid_controller_mapping" end
        local count, copied, unique=0,{},{}
        for index,name in pairs(list) do
            if type(index)~="number" or index%1~=0 or index<1 or index>2 or not nameValid(name) or unique[name] then
                return nil,"invalid_controller_mapping"
            end
            count=count+1; copied[index]=name; unique[name]=true
        end
        if (count==2 and copied[1]==nil) or (count==1 and copied[1]==nil)
            or (description.blended and count==0) then return nil,"invalid_controller_mapping" end
        if recipe.cyclePose~=description.cyclePose then return nil,"cycle_pose_mapping_mismatch" end
        binding={model=recipe.model,sequence=recipe.sequence,blendPoses=copied,cyclePose=recipe.cyclePose}
    end
    local inputs, inputReason=Controllers.Resolve(entity,request)
    if not inputs then return nil,inputReason end
    if binding then
        for _,name in ipairs(binding.blendPoses) do
            if inputs.poses[name]==nil then return nil,"controller_input_missing" end
        end
        if binding.cyclePose and inputs.poses[binding.cyclePose]==nil then return nil,"controller_input_missing" end
    end
    return {schema=1,clip=description.clip,inputs=inputs,controller=binding,
        blendAxesKnown=false,baseRequired=description.baseRequired,baseReason=description.baseReason}
end

-- Detached, read-only input resolution. Named values use parameter-range units
-- in both realms, never the client's normalized GetPoseParameter values.
function Controllers.Resolve(entity, request)
    if not Bridge.Catalog.IsActor(entity) then return nil, "unsupported_actor" end
    if type(request) ~= "table" or (request.poses ~= nil and type(request.poses) ~= "table") then
        return nil, "invalid_poses"
    end
    if type(entity.LookupPoseParameter) ~= "function" or type(entity.GetPoseParameterRange) ~= "function" then
        return nil, "pose_controller_unavailable"
    end
    local poses, total = {}, 0
    for name, value in pairs(request.poses or {}) do
        total = total + 1
        if total > 32 or not nameValid(name) or not finite(value) then return nil, "invalid_poses" end
        poses[name] = value
    end
    local movement = request.movement
    local observation
    if movement ~= nil then
        if type(movement) ~= "table" or not isvector(movement.velocity)
            or not finite(movement.velocity.x) or not finite(movement.velocity.y) or not finite(movement.velocity.z)
            or not finite(movement.referenceSpeed) or movement.referenceSpeed < 0.001
            or not nameValid(movement.forwardPose) or not nameValid(movement.rightPose)
            or movement.forwardPose == movement.rightPose then return nil, "invalid_movement_inputs" end
        if poses[movement.forwardPose] ~= nil or poses[movement.rightPose] ~= nil then return nil, "pose_input_conflict" end
        if total + 2 > 32 then return nil, "invalid_poses" end
        local yaw = movement.facingYaw
        if yaw == nil then
            if type(entity.GetAngles) ~= "function" then return nil, "orientation_unavailable" end
            local ok, angle = pcall(entity.GetAngles, entity)
            if not ok or not isangle(angle) then return nil, "orientation_unavailable" end
            yaw = angle.y
        end
        if not finite(yaw) then return nil, "invalid_movement_inputs" end
        local radians = math.rad(yaw)
        local vx, vy = movement.velocity.x, movement.velocity.y
        local forward = (vx * math.cos(radians) + vy * math.sin(radians)) / movement.referenceSpeed
        -- Source's positive right direction is negative Y at yaw zero.
        local right = (vx * math.sin(radians) - vy * math.cos(radians)) / movement.referenceSpeed
        local magnitude = math.sqrt(forward * forward + right * right)
        local divisor = math.max(1, magnitude)
        forward, right = forward / divisor, right / divisor
        poses[movement.forwardPose], poses[movement.rightPose] = forward, right
        observation = {forward = forward, right = right, facingYaw = yaw,
            referenceSpeed = movement.referenceSpeed, speed = math.sqrt(vx * vx + vy * vy), clamped = magnitude > 1}
    end
    for name, value in pairs(poses) do
        local ok, index = pcall(entity.LookupPoseParameter, entity, name)
        if not ok then return nil, "pose_query_failed" end
        if not finite(index) or index < 0 or index % 1 ~= 0 then return nil, "pose_unavailable" end
        local ranged, minimum, maximum = pcall(entity.GetPoseParameterRange, entity, index)
        if not ranged then return nil, "pose_query_failed" end
        if not finite(minimum) or not finite(maximum) then return nil, "invalid_pose_range" end
        minimum, maximum = math.min(minimum, maximum), math.max(minimum, maximum)
        if movement and (name == movement.forwardPose or name == movement.rightPose) then
            if minimum >= 0 or maximum <= 0 then return nil, "signed_movement_range_required" end
            value = value >= 0 and value * maximum or -value * minimum
            poses[name] = value
        end
        if value < minimum or value > maximum then return nil, "pose_out_of_range" end
    end
    return {schema = 1, model = entity:GetModel(), poses = poses, movement = observation}
end
