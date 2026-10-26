local F = ContactIK
-- Rodrigues rotation maps the original segment onto the solved segment.
-- Preserve each bone's authored basis/twist instead of replacing its Euler pose.
local function rotation(from, to)
    local a, b = from:GetNormalized(), to:GetNormalized()
    local axis = a:Cross(b)
    local cosine = math.Clamp(a:Dot(b), -1, 1)
    local sine = axis:Length()
    if sine < 0.00001 then
        if cosine > 0 then return Matrix() end
        axis = a:Cross(Vector(0, 0, 1))
        if axis:LengthSqr() < 0.001 then axis = a:Cross(Vector(0, 1, 0)) end
        sine = 0
    end
    axis:Normalize()
    local u = {axis.x, axis.y, axis.z}
    local skew = {{0, -u[3], u[2]}, {u[3], 0, -u[1]}, {-u[2], u[1], 0}}
    local result = Matrix()
    for i = 1, 3 do
        for j = 1, 3 do
            result:SetField(i, j, (i == j and cosine or 0)
                + (1 - cosine) * u[i] * u[j] + sine * skew[i][j])
        end
    end
    return result
end
local function around(pivot, rot)
    local a, b = Matrix(), Matrix()
    a:SetTranslation(pivot)
    b:SetTranslation(-pivot)
    return a * rot * b
end
local function descendant(ply, bone, ancestor,rig)
    return F.CachedBoneDescendant(ply,bone,ancestor,rig)
end
F.BoneRotation, F.BoneAround, F.BoneDescendant = rotation, around, descendant

local function fingerPose(ply, spec, matrices, normal, amount, passive,state)
    local limited = 0
    local hierarchy=F.BoneHierarchy(ply)
    state.fingerClearance=state.fingerClearance or {}
    for finger = 0, 4 do
        for joint = 0, 2 do
            local suffix = "Finger" .. finger .. (joint == 0 and "" or tostring(joint))
            local bone = F.RigBone(ply,spec.prefix .. suffix,hierarchy)
            if bone and matrices[bone] then
                local current = matrices[bone]
                local pivot = current:GetTranslation()
                local original = current:GetForward():GetNormalized()
                local flat = passive and original or original - normal * original:Dot(normal)
                if flat:LengthSqr() > 0.001 then
                    flat:Normalize()
                    local child = joint < 2 and F.RigBone(ply,spec.prefix .. "Finger" .. finger .. (joint + 1),hierarchy)
                    local scale = ply:GetModelScale()
                    local length = child and matrices[child] and pivot:Distance(matrices[child]:GetTranslation()) or 1.1 * scale
                    local angle = math.rad((finger == 0 and 20 or (joint == 1 and 55 or 35)) * amount)
                    local function direction(fraction)
                        local a = angle * fraction
                        return flat * math.cos(a) - normal * math.sin(a)
                    end
                    local fraction = 1
                    if amount > 0.001 then
                        local endpoint=pivot+direction(1)*length
                        local cached=state.fingerClearance[bone]
                        if cached and cached.frame==FrameNumber() and cached.pivot==pivot and cached.endpoint==endpoint and cached.scale==scale
                            and cached.flat==flat and cached.normal==normal and cached.angle==angle and cached.length==length then
                            fraction=cached.fraction limited=limited+cached.limited
                        else
                            local pad = Vector(0.18, 0.18, 0.18) * scale
                            local function clear(value)
                                local tr = util.TraceHull({start = pivot, endpos = pivot + direction(value) * length,
                                    mins = -pad, maxs = pad, mask = MASK_SOLID, filter = ply})
                                return not tr.Hit and not tr.StartSolid
                            end
                            if not clear(1) then
                                local lo, hi = 0, 1
                                for _ = 1, 5 do
                                    local mid = (lo + hi) * 0.5
                                    if clear(mid) then lo = mid else hi = mid end
                                end
                                fraction, limited = lo, limited + 1
                            end
                            state.fingerClearance[bone]={frame=FrameNumber(),pivot=pivot,endpoint=endpoint,scale=scale,flat=flat,normal=normal,angle=angle,length=length,
                                fraction=fraction,limited=fraction<1 and 1 or 0}
                        end
                    end
                    local transform = around(pivot, rotation(original, direction(fraction)))
                    for id, matrix in pairs(matrices) do
                        if descendant(ply, id, bone,hierarchy) then matrices[id] = transform * matrix end
                    end
                end
            end
        end
    end
    return limited
end

-- Shared by the actual player callback and explicit visual-only developer
-- previews. It has no physics setters and never supplies a server contact.
local function freeHandPose(ply,contact,matrices,state)
    local index=contact.arm==1 and 2 or 1
    local spec=F.Arms[index]
    local upper,fore,hand=ply:LookupBone(spec.prefix.."UpperArm"),ply:LookupBone(spec.prefix.."Forearm"),ply:LookupBone(spec.prefix.."Hand")
    if not upper or not matrices[upper] or not matrices[fore] or not matrices[hand] then return end
    local root,elbow,wrist=matrices[upper]:GetTranslation(),matrices[fore]:GetTranslation(),matrices[hand]:GetTranslation()
    local scale=ply:GetModelScale() local reach=root:Distance(elbow)+elbow:Distance(wrist)-.06
    local outward=ply:GetRight()*(index==1 and -1 or 1)
    local normal=contact.normal local tangent=contact.tangent or F.SurfaceTangent(normal,ply:GetForward())
    local candidate=contact.point+outward*14*scale-tangent*8*scale
    local tr=util.TraceLine({start=root,endpos=candidate-normal*3*scale,filter=ply,mask=MASK_SOLID})
    local profile=F.HandProfile(ply,index,matrices)
    local target=tr.Hit and not tr.StartSolid and tr.HitNormal:Dot(normal)>.8 and
        F.TargetWrist(ply,index,tr.HitPos,tr.HitNormal,tangent,profile)
    local brace=target and root:Distance(target)<reach
    if not brace then target=root+outward*8*scale+ply:GetForward()*7*scale-Vector(0,0,16)*scale end
    if state.freeFrame~=FrameNumber() then
        state.freeFrame=FrameNumber()
        state.freeTarget=LerpVector(1-math.exp(-18*FrameTime()),state.freeTarget or wrist,target)
    end
    local delta=state.freeTarget-root
    if delta:LengthSqr()<.001 then return end
    local minimum=math.max(math.abs(root:Distance(elbow)-elbow:Distance(wrist))+.06,1.01)
    local wanted=root+delta:GetNormalized()*math.Clamp(delta:Length(),minimum,reach)
    local solved=F.Solve(root,elbow,wrist,wanted,outward-Vector(0,0,.4))
    if not solved then return end
    if contact.collision then
        local r=1.5*scale
        local clear=util.TraceHull({start=solved,endpos=solved,mins=Vector(-r,-r,-r),maxs=Vector(r,r,r),filter=ply,mask=MASK_SOLID})
        if clear.Hit or clear.StartSolid then return {status="free elbow blocked",presentationOnly=true} end
    end
    local transform=around(root,rotation(elbow-root,solved-root))
    for id,m in pairs(matrices) do if descendant(ply,id,upper) then matrices[id]=transform*m end end
    local newElbow,newWrist=matrices[fore]:GetTranslation(),matrices[hand]:GetTranslation()
    transform=around(newElbow,rotation(newWrist-newElbow,wanted-newElbow))
    for id,m in pairs(matrices) do if descendant(ply,id,fore) then matrices[id]=transform*m end end
    if brace then
        local frame=F.HandFrame(tr.HitNormal,tangent) frame:SetScale(matrices[hand]:GetScale()) frame:SetTranslation(matrices[hand]:GetTranslation())
        transform=frame*matrices[hand]:GetInverse()
        for id,m in pairs(matrices) do if descendant(ply,id,hand) then matrices[id]=transform*m end end
    end
    return {status=brace and "visual brace" or "balance",presentationOnly=true,index=index,
        upperLength=root:Distance(matrices[fore]:GetTranslation()),foreLength=matrices[fore]:GetTranslation():Distance(matrices[hand]:GetTranslation())}
end
function F.BuildArmPose(ply, contact, state)
    if F.RefreshHierarchy then F.RefreshHierarchy(ply)end
    local spec = F.Arms[contact.arm]
    if not spec then return end
    local upper = ply:LookupBone(spec.prefix .. "UpperArm")
    local fore = ply:LookupBone(spec.prefix .. "Forearm")
    local hand = ply:LookupBone(spec.prefix .. "Hand")
    if not upper or not fore or not hand then return end
    local matrices = {}
    local hierarchy=F.BoneHierarchy(ply)
    local other=contact.freeHand and ply:LookupBone(F.Arms[contact.arm==1 and 2 or 1].prefix.."UpperArm")
    local spine=(contact.bodyReach or 0)>0 and ply:LookupBone(contact.bodyPivot=="hips" and "ValveBiped.Bip01_Spine" or "ValveBiped.Bip01_Spine1")
    -- Snapshot the subtree before writing: engine propagation is not assumed.
    for bone = 0, ply:GetBoneCount() - 1 do
        if descendant(ply, bone, upper,hierarchy) or (other and descendant(ply,bone,other,hierarchy)) or (spine and descendant(ply,bone,spine,hierarchy)) then
            local m = contact.baseMatrices and contact.baseMatrices[bone] or ply:GetBoneMatrix(bone)
            if m then matrices[bone] = Matrix(m) end
        end
    end
    if not matrices[upper] or not matrices[fore] or not matrices[hand] then return end
    local root = matrices[upper]:GetTranslation()
    local elbow = matrices[fore]:GetTranslation()
    local wrist = matrices[hand]:GetTranslation()
    local scale = ply:GetModelScale()
    if state.arm ~= contact.arm or state.model ~= ply:GetModel() or state.scale ~= scale then
        state.target, state.weight, state.curl = wrist, 0, 0
        state.frame = nil
        state.freeTarget,state.freeFrame=nil,nil
        state.bodyAngle,state.bodyFrame=0,nil
        state.normal,state.tangent,state.pole=nil,nil,nil
        state.orientationFrame,state.poleFrame=nil,nil
        state.fingerClearance=nil
        state.carryEntity,state.carryFrame=nil,nil
        state.profile = F.HandProfile(ply, contact.arm, matrices)
    end
    -- Carry smoothing belongs to the moving prop's frame. Transport its old
    -- target/orientation first, then ease only changes to the local contact.
    -- Otherwise ordinary walking/turning is filtered as if the prop stood still.
    if contact.role=="carry" and IsValid(contact.entity) and not contact.lostAt then
        local frame=Matrix()frame:SetAngles(contact.entity:GetAngles())
        local origin=contact.entity:GetPos()
        frame:SetTranslation(F.CarryAlignedPoint and F.CarryAlignedPoint(contact.entity,origin) or origin)
        if state.carryEntity==contact.entity and state.carryFrame then
            local motion=frame*state.carryFrame:GetInverse()local shift=motion:GetTranslation()
            if state.target then state.target=motion*state.target end
            if state.normal then state.normal=(motion*state.normal-shift):GetNormalized()end
            if state.tangent then state.tangent=(motion*state.tangent-shift):GetNormalized()end
            local body=contact.bodyState
            if body and body.bodyTarget then body.bodyTarget=motion*body.bodyTarget end
        end
        state.carryEntity,state.carryFrame=contact.entity,frame
    else state.carryEntity,state.carryFrame=nil,nil end
    local tangent = contact.tangent or F.SurfaceTangent(contact.normal, ply:GetForward())
    local target = contact.wristTarget or F.TargetWrist(ply, contact.arm, contact.point, contact.normal, tangent, state.profile)
    -- Passive frame changes ease along with the wrist, including corner switches.
    if contact.passive then
        if state.orientationFrame~=FrameNumber() then
            state.orientationFrame=FrameNumber()
            local alpha=1-math.exp(-(contact.response and contact.response.rate or 12)*FrameTime())
            state.normal=LerpVector(alpha,state.normal or contact.normal,contact.normal):GetNormalized()
            state.tangent=LerpVector(alpha,state.tangent or tangent,tangent):GetNormalized()
        end
        local bodyState=contact.bodyState
        contact=table.Copy(contact) contact.bodyState=bodyState contact.normal=state.normal tangent=state.tangent
    end
    local bodyTransform,bodyAngle
    if (contact.bodyReach or 0)>0 and F.BodyReachTransform then
        bodyTransform,bodyAngle=F.BodyReachTransform(ply,matrices,root,target,root:Distance(elbow)+elbow:Distance(wrist)-0.06,contact,contact.bodyState or state)
        root,elbow,wrist=matrices[upper]:GetTranslation(),matrices[fore]:GetTranslation(),matrices[hand]:GetTranslation()
    end
    -- Advance once per frame even when a model builds bones multiple times.
    if state.frame ~= FrameNumber() then
        state.frame = FrameNumber()
        local alpha = 1 - math.exp(-(contact.passive and (contact.response and contact.response.rate or 12) or 32) * FrameTime())
        state.target = LerpVector(alpha, state.target or wrist, target)
        state.weight = Lerp(alpha, state.weight or 0, contact.weight or 1)
        local curl=contact.passive and (contact.response and contact.response.settle or 0)*math.Clamp((state.weight-.8)*5,0,1) or contact.gripping and .8 or 0
        state.curl = Lerp(contact.passive and 1-math.exp(-5*FrameTime()) or alpha, state.curl or 0, curl)
        state.arm, state.model, state.scale = contact.arm, ply:GetModel(), scale
    end
    if contact.passive and state.weight<.001 then return {},{status="faded",arm=state.arm,weight=state.weight} end
    local wanted = state.target or target
    if contact.passive then wanted=LerpVector(state.weight or 0,wrist,wanted) end
    -- A logical grip may exceed this model's exact visual arm length. Present
    -- the closest attainable wrist, rather than making the physical grip fail.
    local delta = wanted - root
    local distance = delta:Length()
    local minimum = math.max(math.abs(root:Distance(elbow) - elbow:Distance(wrist)) + 0.06, 1.01)
    local maximum = root:Distance(elbow) + elbow:Distance(wrist) - 0.06
    if distance < 0.001 then
        delta, distance = ply:GetForward(), 1
    end
    wanted = root + delta / distance * math.Clamp(distance, minimum, maximum)
    local pole = ply:GetRight() * (state.arm == 1 and -1 or 1) - ply:GetUp() * 0.4
    if contact.passive then
        -- Low horizontal support calls for a hanging elbow, not a wide wall brace.
        local rest=ply:GetRight()*(state.arm==1 and -1 or 1)*.2-ply:GetUp()+ply:GetForward()*.15
        local low=math.Clamp((root.z-target.z)/(maximum*.6),0,1)*math.Clamp((contact.normal.z-.5)*2,0,1)
        pole=LerpVector(low,pole,rest):GetNormalized()
        if state.poleFrame~=FrameNumber() then
            state.poleFrame=FrameNumber()
            state.pole=LerpVector(1-math.exp(-10*FrameTime()),state.pole or pole,pole):GetNormalized()
        end
        pole=LerpVector(state.weight,elbow-root,state.pole*(elbow-root):Length())
    end
    local collisionFilter=ply
    local character=contact.passive and IsValid(contact.entity) and (contact.entity:IsNPC() or contact.entity:IsPlayer())
    if character then collisionFilter={ply,contact.entity} end
    local solved = F.Solve(root, elbow, wrist, wanted, pole)
    if solved and contact.collision then
        local r=1.5*scale
        local function clear(p)
            local tr=util.TraceHull({start=p,endpos=p,mins=Vector(-r,-r,-r),maxs=Vector(r,r,r),filter=collisionFilter,mask=MASK_SOLID})
            return not tr.Hit and not tr.StartSolid
        end
        if not clear(solved) then
            solved=F.Solve(root,elbow,wrist,wanted,contact.normal+pole)
            if not solved or not clear(solved) then return nil,{status="elbow clearance blocked",arm=state.arm} end
        end
    end
    if not solved then
        return nil, {status = "visual target unreachable", arm = state.arm}
    end
    if contact.passive and contact.collision then
        local r=.35*scale
        for _,segment in ipairs({{root,solved},{solved,wanted}}) do
            local tr=util.TraceHull({start=segment[1],endpos=segment[2],mins=Vector(-r,-r,-r),maxs=Vector(r,r,r),filter=collisionFilter,mask=MASK_SOLID})
            if tr.Hit or tr.StartSolid then return nil,{status="limb path blocked",arm=state.arm} end
            if character then
                local ray=util.TraceLine({start=segment[1],endpos=segment[2],filter=ply,mask=MASK_SHOT})
                if ray.Hit or ray.StartSolid then return nil,{status="character limb path blocked",arm=state.arm} end
            end
        end
    end
    local upperTransform = around(root, rotation(elbow - root, solved - root))
    for bone,matrix in pairs(matrices) do if descendant(ply,bone,upper,hierarchy) then matrices[bone]=upperTransform*matrix end end
    local newElbow = matrices[fore]:GetTranslation()
    local newWrist = matrices[hand]:GetTranslation()
    local lowerTransform = around(newElbow, rotation(newWrist - newElbow, wanted - newElbow))
    for bone, matrix in pairs(matrices) do
        if descendant(ply, bone, fore,hierarchy) then matrices[bone] = lowerTransform * matrix end
    end
    local handMatrix = matrices[hand]
    local desired = F.HandFrame(contact.normal, tangent)
    desired:SetAngles(LerpAngle(state.weight, handMatrix:GetAngles(), desired:GetAngles()))
    desired:SetScale(handMatrix:GetScale())
    desired:SetTranslation(handMatrix:GetTranslation())
    local handTransform = desired * handMatrix:GetInverse()
    for bone, matrix in pairs(matrices) do
        if descendant(ply, bone, hand,hierarchy) then matrices[bone] = handTransform * matrix end
    end
    local fingerLimit = (not contact.passive or state.curl>.001) and fingerPose(ply, spec, matrices, contact.normal, state.curl,contact.passive,state) or 0
    local free=contact.freeHand and freeHandPose(ply,contact,matrices,state) or nil
    local finalHand = matrices[hand]
    local actualPalm = finalHand:GetTranslation() + finalHand:GetForward():GetNormalized() * state.profile.length
        + finalHand:GetRight():GetNormalized() * state.profile.depth
    if contact.role=="carry" and F.RecordCarryPalm then
        F.RecordCarryPalm(ply,contact.entity,contact.arm,actualPalm,contact.point+contact.normal*state.profile.clearance,state.weight)
    end
    return matrices, {status = "posed", arm = state.arm,
        wristError = matrices[hand]:GetTranslation():Distance(target),
        solvedError = matrices[hand]:GetTranslation():Distance(wanted),
        palmError = actualPalm:Distance(contact.point + contact.normal * state.profile.clearance),
        palmNormalDot = finalHand:GetRight():GetNormalized():Dot(-contact.normal),
        upperLength = root:Distance(matrices[fore]:GetTranslation()),
        foreLength = matrices[fore]:GetTranslation():Distance(matrices[hand]:GetTranslation()),
        fingerLimits = fingerLimit, curl = state.curl,weight=state.weight,bodyAngle=bodyAngle or 0,bodyAssisted=bodyTransform~=nil,freeHand=free},bodyTransform
end

-- Passive arms share the incoming animated torso and never rotate it twice.
-- When composing with an explicit pose, baseMatrices contains its single torso
-- transform. Only the unclaimed arm subtree is subsequently written.
function F.BuildContactsPose(ent,contacts,state,baseMatrices)
    state.arms=state.arms or {}
    state.body=state.body or {}
    local response=F.PassiveResponse and F.PassiveResponse(ent,contacts)
    local matrices,report={}, {status="passive contacts",presentationOnly=true,arms={}}
    local primary=contacts[1] and 1 or 2
    if contacts[1] and contacts[2] then
        local excess={}
        for index=1,2 do
            local a=F.SensingArm and F.SensingArm(ent,index)or F.Arm(ent,index)
            excess[index]=a and a.root:Distance(F.TargetWrist(ent,index,contacts[index].point,contacts[index].normal,contacts[index].tangent))-a.reach or 0
        end
        primary=state.bodyArm or (excess[2]>excess[1] and 2 or 1)
        local other=primary==1 and 2 or 1
        local carry=contacts[1].role=="carry" and contacts[2].role=="carry" and contacts[1].entity==contacts[2].entity
        if not carry and excess[other]>excess[primary]+ent:GetModelScale() then primary=other end
    end
    state.bodyArm=primary
    local suppressed=baseMatrices~=nil or contacts[primary] and contacts[primary].preserveBody==true or false
    if state.bodySuppressed~=suppressed then
        state.body={} state.bodySuppressed=suppressed
    end
    local order={primary,primary==1 and 2 or 1}
    local common=baseMatrices
    for _,index in ipairs(order) do
        local c=contacts[index]
        if c then
            state.arms[index]=state.arms[index] or {}
            local spec=table.Copy(c)
            spec.response=response
            spec.arm=index spec.passive=true spec.gripping=false spec.freeHand=false
            spec.bodyReach=0 spec.baseMatrices=common
            if index==primary and not baseMatrices and not c.preserveBody then
                spec.bodyPivot="hips" spec.bodyLean=math.Clamp(c.bodyLean or 12,0,35) spec.bodyState=state.body
                spec.bodyReach=math.Clamp(c.bodyReach or 5,0,16)*ent:GetModelScale()*(state.arms[index].weight or 0)
            end
            local pose,r=F.BuildArmPose(ent,spec,state.arms[index])
            if pose then for id,m in pairs(pose) do matrices[id]=m end end
            if pose and index==primary and not baseMatrices then common=pose end
            report.arms[index]=r or {status="unavailable"}
        end
    end
    return matrices,report
end

