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
local function descendant(ply, bone, ancestor)
    for _ = 1, 128 do
        if bone == ancestor then return true end
        bone = ply:GetBoneParent(bone)
        if not bone or bone < 0 then return false end
    end
    return false
end
F.BoneRotation, F.BoneAround, F.BoneDescendant = rotation, around, descendant

local function fingerPose(ply, spec, matrices, normal, amount, passive)
    local limited = 0
    for finger = 0, 4 do
        for joint = 0, 2 do
            local suffix = "Finger" .. finger .. (joint == 0 and "" or tostring(joint))
            local bone = ply:LookupBone(spec.prefix .. suffix)
            if bone and matrices[bone] then
                local current = matrices[bone]
                local pivot = current:GetTranslation()
                local original = current:GetForward():GetNormalized()
                local flat = passive and original or original - normal * original:Dot(normal)
                if flat:LengthSqr() > 0.001 then
                    flat:Normalize()
                    local child = joint < 2 and ply:LookupBone(spec.prefix .. "Finger" .. finger .. (joint + 1))
                    local scale = ply:GetModelScale()
                    local length = child and matrices[child] and pivot:Distance(matrices[child]:GetTranslation()) or 1.1 * scale
                    local angle = math.rad((finger == 0 and 20 or (joint == 1 and 55 or 35)) * amount)
                    local function direction(fraction)
                        local a = angle * fraction
                        return flat * math.cos(a) - normal * math.sin(a)
                    end
                    local fraction = 1
                    if amount > 0.001 then
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
                    end
                    local transform = around(pivot, rotation(original, direction(fraction)))
                    for id, matrix in pairs(matrices) do
                        if descendant(ply, id, bone) then matrices[id] = transform * matrix end
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
    local spec = F.Arms[contact.arm]
    if not spec then return end
    local upper = ply:LookupBone(spec.prefix .. "UpperArm")
    local fore = ply:LookupBone(spec.prefix .. "Forearm")
    local hand = ply:LookupBone(spec.prefix .. "Hand")
    if not upper or not fore or not hand then return end
    local matrices = {}
    -- Snapshot the subtree before writing: engine propagation is not assumed.
    for bone = 0, ply:GetBoneCount() - 1 do
        local spineName=contact.bodyPivot=="hips" and "ValveBiped.Bip01_Spine" or "ValveBiped.Bip01_Spine1"
        local other=contact.freeHand and ply:LookupBone(F.Arms[contact.arm==1 and 2 or 1].prefix.."UpperArm")
        if descendant(ply, bone, upper) or (other and descendant(ply,bone,other)) or ((contact.bodyReach or 0)>0 and ply:LookupBone(spineName) and
            descendant(ply,bone,ply:LookupBone(spineName))) then
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
        state.profile = F.HandProfile(ply, contact.arm, matrices)
    end
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
        contact=table.Copy(contact) contact.normal=state.normal tangent=state.tangent
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
    for bone,matrix in pairs(matrices) do if descendant(ply,bone,upper) then matrices[bone]=upperTransform*matrix end end
    local newElbow = matrices[fore]:GetTranslation()
    local newWrist = matrices[hand]:GetTranslation()
    local lowerTransform = around(newElbow, rotation(newWrist - newElbow, wanted - newElbow))
    for bone, matrix in pairs(matrices) do
        if descendant(ply, bone, fore) then matrices[bone] = lowerTransform * matrix end
    end
    local handMatrix = matrices[hand]
    local desired = F.HandFrame(contact.normal, tangent)
    desired:SetAngles(LerpAngle(state.weight, handMatrix:GetAngles(), desired:GetAngles()))
    desired:SetScale(handMatrix:GetScale())
    desired:SetTranslation(handMatrix:GetTranslation())
    local handTransform = desired * handMatrix:GetInverse()
    for bone, matrix in pairs(matrices) do
        if descendant(ply, bone, hand) then matrices[bone] = handTransform * matrix end
    end
    local fingerLimit = (not contact.passive or state.curl>.001) and fingerPose(ply, spec, matrices, contact.normal, state.curl,contact.passive) or 0
    local free=contact.freeHand and freeHandPose(ply,contact,matrices,state) or nil
    local finalHand = matrices[hand]
    local actualPalm = finalHand:GetTranslation() + finalHand:GetForward():GetNormalized() * state.profile.length
        + finalHand:GetRight():GetNormalized() * state.profile.depth
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
            local a=F.Arm(ent,index)
            excess[index]=a and a.root:Distance(F.TargetWrist(ent,index,contacts[index].point,contacts[index].normal,contacts[index].tangent))-a.reach or 0
        end
        primary=state.bodyArm or (excess[2]>excess[1] and 2 or 1)
        local other=primary==1 and 2 or 1
        if excess[other]>excess[primary]+ent:GetModelScale() then primary=other end
    end
    state.bodyArm=primary
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
            if index==primary and not baseMatrices then
                spec.bodyPivot="hips" spec.bodyLean=12 spec.bodyState=state.body
                spec.bodyReach=5*ent:GetModelScale()*(state.arms[index].weight or 0)
            end
            local pose,r=F.BuildArmPose(ent,spec,state.arms[index])
            if pose then for id,m in pairs(pose) do matrices[id]=m end end
            if pose and index==primary and not baseMatrices then common=pose end
            report.arms[index]=r or {status="unavailable"}
        end
    end
    return matrices,report
end

