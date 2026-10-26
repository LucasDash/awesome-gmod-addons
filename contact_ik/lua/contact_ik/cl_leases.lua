-- One compositor per entity. Explicit caller leases outrank passive fallback.
local K = ContactIK
-- GLua may refresh this module directly rather than through autorun. Preserve
-- the registry until its previous shutdown has removed all owned callbacks.
if K.Shutdown then K.Shutdown() end
local leases = K.PoseLeases or setmetatable({}, {__mode="k"})
K.PoseLeases=leases
K.Reports = setmetatable({}, {__mode="k"})
K.PoseCacheStats={hits=0,misses=0}
local function sameMatrix(a,b)
    if not a or not b then return not a and not b end
    local field=a.GetField
    for row=1,4 do for col=1,4 do if field(a,row,col)~=field(b,row,col) then return false end end end
    return true
end
local function passivePose(model,contacts,state)
    -- Only the provider's automatic reader uses this cache. Generic API-1
    -- readers and explicit consumers retain their per-call semantics.
    if state.automaticOwner~=state.passiveOwner then return K.BuildContactsPose(model,contacts,state.passiveState) end
    local response=K.PassiveResponse(model,contacts)
    local cached=state.poseCache
    local valid=cached and cached.frame==FrameNumber() and cached.time==CurTime()
        and cached.model==model:GetModel() and cached.scale==model:GetModelScale()
        and cached.count==model:GetBoneCount()
        and cached.rate==response.rate and cached.settle==response.settle
    if valid then
        for index=1,2 do
            local a,b=contacts[index],cached.contacts[index]
            if (a==nil)~=(b==nil) or a and (a.point~=b.point or a.normal~=b.normal or a.tangent~=b.tangent
                or a.weight~=b.weight or a.entity~=b.entity or a.preserveBody~=b.preserveBody
                or a.bodyReach~=b.bodyReach or a.bodyLean~=b.bodyLean) then valid=false break end
        end
    end
    if valid then
        for id,input in pairs(cached.inputs) do if not sameMatrix(model:GetBoneMatrix(id),input) then valid=false break end end
    end
    if valid then K.PoseCacheStats.hits=K.PoseCacheStats.hits+1 return cached.pose,cached.report end
    K.PoseCacheStats.misses=K.PoseCacheStats.misses+1
    local pose,report=K.BuildContactsPose(model,contacts,state.passiveState)
    if next(pose) then
        local inputs,snapshot={},{}
        -- Validate every incoming bone, including a rejected arm and body pivot.
        -- Leaf animation/jiggle or a new render origin must invalidate reuse.
        local count=model:GetBoneCount()
        for id=0,count-1 do local input=model:GetBoneMatrix(id)inputs[id]=input and Matrix(input)or false end
        for index,c in pairs(contacts) do snapshot[index]={point=Vector(c.point),normal=Vector(c.normal),tangent=Vector(c.tangent),
            weight=c.weight,entity=c.entity,preserveBody=c.preserveBody,bodyReach=c.bodyReach,bodyLean=c.bodyLean}end
        state.poseCache={frame=FrameNumber(),time=CurTime(),model=model:GetModel(),scale=model:GetModelScale(),
            count=count,rate=response.rate,settle=response.settle,contacts=snapshot,inputs=inputs,pose=pose,report=report}
    else state.poseCache=nil end
    return pose,report
end
function K.Release(ent, owner)
    local state = leases[ent]
    if not owner or not state or state.owner ~= owner then return false end
    state.owner,state.reader=nil,nil
    if not state.passiveOwner then
        if IsValid(ent) then ent:RemoveCallback("BuildBonePositions", state.callback) end
        leases[ent], K.Reports[ent] = nil, nil
    end
    return true
end
function K.ReleaseOwner(owner)
    for ent, state in pairs(leases) do if state.owner == owner then K.Release(ent,owner) end end
end
-- Discovery reads measurements from the incoming animation, never the pose
-- this compositor wrote last frame. Store vectors/lengths, not pose matrices.
local function captureSensing(model,state)
    if state.owner or state.automaticOwner~=state.passiveOwner or not model.WorldToLocal then return end
    local old=state.sensing
    local name,scale,count=model:GetModel(),model:GetModelScale(),model:GetBoneCount()
    if old and old.frame==FrameNumber() and old.model==name and old.scale==scale and old.count==count then return end
    local snapshot={frame=FrameNumber(),time=CurTime(),model=name,scale=scale,count=count,arms={}}
    local rig=K.BoneHierarchy(model)
    for index,spec in ipairs(K.Arms)do
        local upper=K.RigBone(model,spec.prefix.."UpperArm",rig)
        local fore=K.RigBone(model,spec.prefix.."Forearm",rig)local hand=K.RigBone(model,spec.prefix.."Hand",rig)
        local a,b,c=upper and model:GetBoneMatrix(upper),fore and model:GetBoneMatrix(fore),hand and model:GetBoneMatrix(hand)
        if a and b and c then
            local root,elbow,wrist=a:GetTranslation(),b:GetTranslation(),c:GetTranslation()
            local first,second=root:Distance(elbow),elbow:Distance(wrist)
            if first>=1 and second>=1 then snapshot.arms[index]={index=index,upper=upper,fore=fore,hand=hand,
                root=K.SubjectToLocal(model,root),elbow=K.SubjectToLocal(model,elbow),wrist=K.SubjectToLocal(model,wrist),
                reach=first+second,minimum=math.abs(first-second)+1}end
        end
    end
    state.sensing=snapshot
end
function K.SensingArm(model,index)
    local state=leases[model]local snapshot=state and not state.owner and state.sensing
    if snapshot and snapshot.model==model:GetModel() and snapshot.scale==model:GetModelScale()
        and snapshot.count==model:GetBoneCount() and CurTime()-snapshot.time<.3 then
        local a=snapshot.arms[index]
        if a then return {index=index,upper=a.upper,fore=a.fore,hand=a.hand,root=K.SubjectToWorld(model,a.root),
            elbow=K.SubjectToWorld(model,a.elbow),wrist=K.SubjectToWorld(model,a.wrist),reach=a.reach,minimum=a.minimum}end
    end
    return K.Arm(model,index)
end
local function ensure(ent)
    if leases[ent] then return leases[ent] end
    local state={passiveState={}}
    leases[ent]=state
    state.callback=ent:AddCallback("BuildBonePositions",function(model)
        captureSensing(model,state)
        local c=state.reader and state.reader(model)
        state.passiveBlocked=state.owner and (not c or not (c.allowPassive or c.freeHand) or c.anchorBone~=nil) or false
        local fallback=not state.passiveBlocked and state.passiveReader and state.passiveReader(model)
        if (c or fallback) and K.RefreshHierarchy(model)then state.poseCache=nil end
        if not c then
            if fallback and not state.owner then
                local pose,r=passivePose(model,fallback,state)
                for id,m in pairs(pose) do model:SetBoneMatrix(id,m) end
                r.owner=state.owner and "explicit idle / passive" or "passive"
                K.Reports[model]=r
            else K.Reports[model]=nil end
            return
        end
        local other=K.Arms[c.arm==1 and 2 or 1]
        local bone=other and model:LookupBone(other.prefix.."Hand")
        local matrix=bone and model:GetBoneMatrix(bone)
        local prior=matrix and matrix:GetTranslation()
        local matrices,report,bodyTransform
        local secondary=fallback and (c.allowPassive or c.freeHand) and not c.anchorBone and fallback[c.arm==1 and 2 or 1]
        local contact=c
        if secondary and c.freeHand then contact=table.Copy(c) contact.freeHand=false end
        if c.anchorBone then matrices,report,bodyTransform=K.BuildAnchorPose(model,contact,state)
        else matrices,report,bodyTransform=K.BuildArmPose(model,contact,state) end
        if secondary and matrices then
            local pose,r=K.BuildContactsPose(model,{[c.arm==1 and 2 or 1]=secondary},state.passiveState,matrices)
            for id,m in pairs(pose) do matrices[id]=m end
            if report then report.passive=r end
        end
        if matrices then for id,m in pairs(matrices) do model:SetBoneMatrix(id,m) end end
        if report and prior then
            local after=model:GetBoneMatrix(bone)
            report.inactiveHandError=after and after:GetTranslation():Distance(bodyTransform and bodyTransform*prior or prior) or -1
            report.inactiveHandWritten=matrices and matrices[bone]~=nil or false
        end
        if report then report.owner="explicit" end
        K.Reports[model]=report
    end)
    return state
end
function K.Acquire(ent,owner,reader)
    if not IsValid(ent) or not owner or not isfunction(reader) then return false,"invalid lease" end
    local state=leases[ent]
    if state and state.owner and state.owner~=owner then return false,"pose already owned" end
    state=ensure(ent)
    if state.owner~=owner then state.target,state.weight,state.profile,state.frame=nil,nil,nil,nil state.arm,state.model,state.scale=nil,nil,nil state.passiveBlocked=nil end
    state.owner,state.reader=owner,reader
    return true
end
function K.AcquirePassive(ent,owner,reader)
    if not IsValid(ent) or not owner or not isfunction(reader) then return false,"invalid passive lease" end
    local state=leases[ent]
    if state and state.passiveOwner and state.passiveOwner~=owner then return false,"passive pose already owned" end
    state=ensure(ent) state.passiveOwner,state.passiveReader=owner,reader
    return true
end
function K.ReleasePassive(ent,owner)
    local state=leases[ent]
    if not owner or not state or state.passiveOwner~=owner then return false end
    state.passiveOwner,state.passiveReader=nil,nil state.passiveState={}state.automaticOwner,state.poseCache,state.sensing=nil,nil,nil
    if not state.owner then
        if IsValid(ent) then ent:RemoveCallback("BuildBonePositions",state.callback) end
        leases[ent],K.Reports[ent]=nil,nil
    end
    return true
end
function K.LeaseCount() return table.Count(leases) end
hook.Add("EntityRemoved","ContactIK.Leases",function(ent)
    local state=leases[ent]
    if state then leases[ent],K.Reports[ent]=nil,nil end
end)
function K.Shutdown()
    if K.StopPassive then K.StopPassive() end
    if K.StopCarryAlignment then K.StopCarryAlignment() end
    hook.Remove("EntityRemoved","ContactIK.Leases")
    hook.Remove("PopulateToolMenu","ContactIK.Settings")
    for ent,state in pairs(leases) do
        if IsValid(ent) then ent:RemoveCallback("BuildBonePositions",state.callback) end
        leases[ent],K.Reports[ent]=nil,nil
    end
end
