-- Optional rigid upper-body reach; never changes collision, input or physics.
local K=ContactIK
function K.BodyReachTransform(ent,matrices,root,target,armReach,contact,state)
    local spine=ent:LookupBone(contact.bodyPivot=="hips" and "ValveBiped.Bip01_Spine" or "ValveBiped.Bip01_Spine1")
    local pivotBone=contact.bodyPivot=="hips" and ent:LookupBone("ValveBiped.Bip01_Pelvis") or spine
    local pivotMatrix=pivotBone and ent:GetBoneMatrix(pivotBone)
    if not spine or not matrices[spine] or not pivotMatrix then return end
    local pivot=pivotMatrix:GetTranslation()
    if contact.passive then
        if state.model~=ent:GetModel() or state.scale~=ent:GetModelScale() then
            state.model,state.scale=ent:GetModel(),ent:GetModelScale()
            state.bodyTarget,state.bodyAngle=nil,0
            state.targetFrame,state.bodyFrame=nil,nil
        end
        if state.targetFrame~=FrameNumber() then
            state.targetFrame=FrameNumber()
            state.bodyTarget=LerpVector(1-math.exp(-(contact.response and contact.response.rate*2/3 or 8)*FrameTime()),state.bodyTarget or target,target)
        end
        target=state.bodyTarget
    end
    local from,to=root-pivot,target-pivot
    local length=from:Length()
    if length<1 or to:Length()<1 then return end
    local axis=from:GetNormalized()
    local bend=to:GetNormalized()-axis*axis:Dot(to:GetNormalized())
    if bend:LengthSqr()<0.00001 then return end
    bend:Normalize()
    local maximum=math.min(math.acos(math.Clamp(axis:Dot(to:GetNormalized()),-1,1)),
        math.rad(contact.bodyLean or 35),2*math.asin(math.min((contact.bodyReach or 0)/(2*length),1)))
    local function direction(angle)return axis*math.cos(angle)+bend*math.sin(angle)end
    local function error(angle)return (pivot+direction(angle)*length):Distance(target)end
    local wanted=0
    if root:Distance(target)>armReach+0.2 and error(maximum)<error(0) then
        wanted=maximum
        if error(maximum)<armReach then
            local low,high=0,maximum
            for _=1,10 do local mid=(low+high)*0.5 if error(mid)>armReach then low=mid else high=mid end end
            wanted=high
        end
    end
    if contact.collision then
        local function clear(angle)
            local transform=K.BoneAround(pivot,K.BoneRotation(from,direction(angle)*length))
            for _,name in ipairs({"ValveBiped.Bip01_Spine2","ValveBiped.Bip01_Head1"}) do
                local bone=ent:LookupBone(name) local m=bone and matrices[bone]
                if m then
                    local p=m:GetTranslation() local r=4*ent:GetModelScale()
                    local tr=util.TraceHull({start=p,endpos=transform*p,mins=Vector(-r,-r,-r),maxs=Vector(r,r,r),filter=ent,mask=MASK_SOLID})
                    if tr.Hit or tr.StartSolid then return false end
                end
            end
            return true
        end
        if not clear(maximum) then
            local low,high=0,maximum
            for _=1,6 do local mid=(low+high)*.5 if clear(mid) then low=mid else high=mid end end
            maximum=low
        end
        wanted=math.min(wanted,maximum)
    end
    if state.bodyFrame~=FrameNumber() then
        state.bodyFrame=FrameNumber()
        state.bodyAngle=Lerp(1-math.exp(-12*FrameTime()),state.bodyAngle or 0,wanted)
    end
    local angle=math.Clamp(state.bodyAngle or 0,0,maximum)
    if angle<0.00001 then return end
    local transform=K.BoneAround(pivot,K.BoneRotation(from,direction(angle)*length))
    for bone,m in pairs(matrices) do if K.BoneDescendant(ent,bone,spine) then matrices[bone]=transform*m end end
    return transform,math.deg(angle),matrices[spine]:GetTranslation():Distance(pivot)
end

-- Generic attachment presentation, driven by the caller's bone/local anchor.
-- Entity position, movement, collision and the physics anchor remain untouched.
function K.BuildAnchorPose(ent,contact,state)
    if state.model~=ent:GetModel() or state.scale~=ent:GetModelScale() then
        state.model,state.scale=ent:GetModel(),ent:GetModelScale() state.bodyAngle,state.bodyFrame=0,nil
    end
    local bone=contact.anchorBone
    local anchor=bone and ent:GetBoneMatrix(bone)
    if not anchor or not contact.anchorLocal then return end
    local spine=ent:LookupBone("ValveBiped.Bip01_Spine")
    if not spine or not K.BoneDescendant(ent,bone,spine) then return nil,{status="anchor outside upper body"} end
    local matrices={}
    for id=0,ent:GetBoneCount()-1 do
        if K.BoneDescendant(ent,id,spine) then local m=ent:GetBoneMatrix(id) if m then matrices[id]=Matrix(m) end end
    end
    local point=anchor*contact.anchorLocal
    local spec=table.Copy(contact) spec.bodyPivot="hips"
    local transform,angle=K.BodyReachTransform(ent,matrices,point,contact.point,0,spec,state)
    local result=transform and transform*point or point
    return matrices,{status="anchored pose",bodyAngle=angle or 0,anchorError=result:Distance(contact.point),bodyAssisted=transform~=nil},transform
end
