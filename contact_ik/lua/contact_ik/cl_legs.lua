-- Independent limb presentation. Native visual traces; no gameplay hooks.
local F=ContactIK
-- Follow the solved shin's authored foot frame, then permit bounded ankle swing
-- and twist. A surface normal never authorizes arbitrary ankle rotation.
function F.LimitedFootFrame(current,normal,tangent,swingLimit,twistLimit)
    local from=-current:GetRight():GetNormalized()
    local wanted=-normal:GetNormalized()
    local angle=math.acos(math.Clamp(from:Dot(wanted),-1,1))
    local swing=math.min(angle,math.rad(swingLimit or 65))
    local bend=wanted-from*from:Dot(wanted)
    if bend:LengthSqr()<0.000001 then bend=current:GetUp() end
    bend:Normalize()
    local sole=from*math.cos(swing)+bend*math.sin(swing)
    local rotated=F.BoneRotation(from,sole)*current
    local forward=rotated:GetForward():GetNormalized()
    local desired=tangent-sole*tangent:Dot(sole)
    local twist=0
    if desired:LengthSqr()>0.000001 then
        desired:Normalize()
        twist=math.Clamp(math.atan2(sole:Dot(forward:Cross(desired)),forward:Dot(desired)),
            -math.rad(twistLimit or 30),math.rad(twistLimit or 30))
    end
    forward=forward*math.cos(twist)+sole:Cross(forward)*math.sin(twist)
    local frame=F.HandFrame(sole,forward)
    frame:SetScale(current:GetScale()) frame:SetTranslation(current:GetTranslation())
    return frame,math.deg(swing),math.deg(twist)
end
local function clearKnee(ent,root,knee,ankle,target,side,contact,tr,scale)
    local radius=contact.kneeRadius or 3*scale
    local ceiling=math.tan(math.rad(math.Clamp(contact.kneeSpread or 55,0,65)))
    local normal=tr.HitNormal
    local clearance=radius*(math.abs(normal.x)+math.abs(normal.y)+math.abs(normal.z))+.25*scale
    local function solve(spread)
        return F.Solve(root,knee,ankle,target,ent:GetForward()+ent:GetRight()*side*spread)
    end
    local previous=math.min(.25,ceiling)
    for _,spread in ipairs({.25,.5,.8,1.1,ceiling}) do
        if spread<=ceiling then
            local candidate=solve(spread)
            if candidate and (candidate-tr.HitPos):Dot(normal)>=clearance then
                -- Minimize spread against the contact plane, then confirm the
                -- resulting knee volume against all native solid geometry.
                local low,high=previous,spread
                for _=1,6 do
                    local mid=(low+high)*.5 local point=solve(mid)
                    if point and (point-tr.HitPos):Dot(normal)>=clearance then high=mid else low=mid end
                end
                candidate=solve(high)
                local hull=util.TraceHull({start=candidate,endpos=candidate,mins=Vector(-radius,-radius,-radius),
                    maxs=Vector(radius,radius,radius),filter=ent,mask=MASK_SOLID})
                if not hull.Hit and not hull.StartSolid and not hull.AllSolid then return candidate,high,radius end
            end
            previous=spread
        end
    end
end
function F.BuildFeetPose(ent, contact, state)
    local output, reports, count = {}, {}, 0
    if not contact or math.abs(contact.normal.z) > 0.55 then return nil, {status="no wall", contacts=0} end
    local normal = contact.normal:GetNormalized()
    local tangent = F.SurfaceTangent(normal, Vector(1, 0, 0))
    local scale = ent:GetModelScale()
    if state.model ~= ent:GetModel() or state.scale ~= scale then
        state.legs, state.model, state.scale = {}, ent:GetModel(), scale
    end
    for index, side in ipairs({"L", "R"}) do
        local prefix = "ValveBiped.Bip01_" .. side .. "_"
        local thigh, calf, foot = ent:LookupBone(prefix.."Thigh"), ent:LookupBone(prefix.."Calf"), ent:LookupBone(prefix.."Foot")
        if thigh and calf and foot then
            local matrices = {}
            for b=0,ent:GetBoneCount()-1 do
                if F.BoneDescendant(ent,b,thigh) then
                    local m=ent:GetBoneMatrix(b)
                    if m then matrices[b]=Matrix(m) end
                end
            end
            if matrices[thigh] and matrices[calf] and matrices[foot] then
                local root,knee,ankle=matrices[thigh]:GetTranslation(),matrices[calf]:GetTranslation(),matrices[foot]:GetTranslation()
                local a,b=root:Distance(knee),knee:Distance(ankle)
                local probe=root-Vector(0,0,(a+b)*0.6)
                local projected=probe-normal*(probe-contact.point):Dot(normal)
                local tr=util.TraceLine({start=projected+normal*(a+b),endpos=projected-normal*6,
                    filter=ent,mask=MASK_SOLID})
                local toe=ent:LookupBone(prefix.."Toe0")
                local length=toe and matrices[toe] and ankle:Distance(matrices[toe]:GetTranslation())*0.45 or 3*scale
                length=math.Clamp(length,1*scale,4*scale)
                local depth,clearance=2.5*scale,0.3*scale
                local desired=tr.HitPos and (tr.HitPos+normal*(depth+clearance)-tangent*length)
                local distance=desired and root:Distance(desired) or math.huge
                local valid=tr.Hit and not tr.StartSolid and tr.Entity==contact.entity and tr.HitNormal:Dot(normal)>0.85
                    and distance>math.max(math.abs(a-b)+0.1,1.1) and distance<a+b-0.1
                if valid then
                    local leg=state.legs[index] or {target=ankle,weight=0}
                    state.legs[index]=leg
                    if leg.frame~=FrameNumber() then
                        local alpha=1-math.exp(-24*FrameTime())
                        leg.target=LerpVector(alpha,leg.target,desired)
                        leg.weight=Lerp(alpha,leg.weight,1)
                        leg.frame=FrameNumber()
                    end
                    local delta=leg.target-root
                    if delta:LengthSqr()<0.001 then delta=normal end
                    local wanted=root+delta:GetNormalized()*math.Clamp(delta:Length(),math.max(math.abs(a-b)+0.06,1.01),a+b-0.06)
                    -- Knees flex toward the character's front, regardless of
                    -- which side of the character the contacted wall occupies.
                    -- The outward wall normal previously selected the rear
                    -- branch of the two-bone solution when facing the wall.
                    local bendSign=index==1 and -1 or 1
                    local baseline=matrices
                    local frame,swing,twist
                    local solved,spread,kneeRadius=clearKnee(ent,root,knee,ankle,wanted,bendSign,contact,tr,scale)
                    if solved then
                        -- Reconstruct the pad from the bounded ankle frame, then
                        -- correct the ankle target and re-solve the whole chain.
                        -- This keeps an angled foot in contact without increasing
                        -- ankle budgets or translating a foot off its shin.
                        for iteration=1,5 do
                            matrices={}
                            for id,m in pairs(baseline) do matrices[id]=Matrix(m) end
                            solved,spread,kneeRadius=clearKnee(ent,root,knee,ankle,wanted,bendSign,contact,tr,scale)
                            if not solved then break end
                            local upper=F.BoneAround(root,F.BoneRotation(knee-root,solved-root))
                            for id,m in pairs(matrices) do matrices[id]=upper*m end
                            local newKnee,newAnkle=matrices[calf]:GetTranslation(),matrices[foot]:GetTranslation()
                            local lower=F.BoneAround(newKnee,F.BoneRotation(newAnkle-newKnee,wanted-newKnee))
                            for id,m in pairs(matrices) do if F.BoneDescendant(ent,id,calf) then matrices[id]=lower*m end end
                            local current=matrices[foot]
                            -- Calibrated on the rendered ValveBiped foot: toes run
                            -- +X. Soles face local +Y, opposite Matrix:GetRight; this is
                            -- the opposite side from the palm's convention.
                            frame,swing,twist=F.LimitedFootFrame(current,normal,tangent,
                                (contact.ankleSwing or 65)*leg.weight,(contact.ankleTwist or 30)*leg.weight)
                            frame:SetScale(current:GetScale())
                            frame:SetTranslation(current:GetTranslation())
                            local transform=frame*current:GetInverse()
                            for id,m in pairs(matrices) do
                                if F.BoneDescendant(ent,id,foot) then matrices[id]=transform*m end
                            end
                            local pad=frame:GetTranslation()+frame:GetForward():GetNormalized()*length-frame:GetRight():GetNormalized()*depth
                            local correction=(tr.HitPos+normal*clearance-pad)*leg.weight
                            if correction:Length()<0.01*scale or iteration==5 then break end
                            if correction:Length()>4*scale then correction=correction:GetNormalized()*4*scale end
                            local nextTarget=wanted+correction
                            local offset=nextTarget-root
                            if offset:LengthSqr()<0.000001 then break end
                            wanted=root+offset:GetNormalized()*math.Clamp(offset:Length(),math.max(math.abs(a-b)+0.06,1.01),a+b-0.06)
                        end
                        if solved then
                            for id,m in pairs(matrices) do output[id]=m end
                            local final=matrices[foot]
                            local kneePoint=matrices[calf]:GetTranslation()
                            local line=(final:GetTranslation()-root):GetNormalized()
                            local forward=ent:GetForward()-line*ent:GetForward():Dot(line)
                            local bend=kneePoint-root-line*(kneePoint-root):Dot(line)
                            local kneeForward=forward:LengthSqr()>0.001 and bend:Dot(forward:GetNormalized()) or 0
                            local flexion=180-math.deg(math.acos(math.Clamp((root-kneePoint):GetNormalized():Dot((final:GetTranslation()-kneePoint):GetNormalized()),-1,1)))
                            local pad=final:GetTranslation()+final:GetForward():GetNormalized()*length-final:GetRight():GetNormalized()*depth
                            reports[index]={side=side,status="posed",point=tr.HitPos,normal=normal,
                                upperLength=root:Distance(matrices[calf]:GetTranslation()),
                                lowerLength=matrices[calf]:GetTranslation():Distance(final:GetTranslation()),
                                kneeForward=kneeForward,kneeFlexion=flexion,kneeClearance=(kneePoint-tr.HitPos):Dot(normal),
                                kneeSpread=math.deg(math.atan(spread)),kneeRadius=kneeRadius,
                                soleError=pad:Distance(tr.HitPos+normal*clearance),soleNormalDot=(-final:GetRight():GetNormalized()):Dot(-normal),
                                ankleSwing=swing,ankleTwist=twist,orientationLimited=swing>= (contact.ankleSwing or 65)-0.01 or math.abs(twist)>=(contact.ankleTwist or 30)-0.01}
                            count=count+1
                        else reports[index]={side=side,status="knee clearance blocked"} end
                    else reports[index]={side=side,status="knee clearance blocked"}
                    end
                else state.legs[index]=nil end
            end
        end
    end
    return count>0 and output or nil,{status=count>0 and "wall bracing" or "no reachable foot surface",contacts=count,legs=reports}
end
