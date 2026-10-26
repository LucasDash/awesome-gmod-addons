local F = ContactIK
F.API = 1
F.Revision = "contact-ik-carry-stability-20261026"
-- Player GetAngles can include aim pitch outside drawing while the rendered
-- skeleton remains upright. Use the same explicit body frame in both contexts.
function F.SubjectAngles(ent)
    return ent.GetRenderAngles and ent:GetRenderAngles() or ent.GetAngles and ent:GetAngles() or ent:GetForward():Angle()
end
function F.SubjectToLocal(ent,point)
    local result=WorldToLocal(point,angle_zero,ent:GetPos(),F.SubjectAngles(ent))return result
end
function F.SubjectToWorld(ent,point)
    local result=LocalToWorld(point,angle_zero,ent:GetPos(),F.SubjectAngles(ent))return result
end
-- Cache topology, never animated matrices. A model/count change retires it.
local rigs=setmetatable({}, {__mode="k"})
function F.BoneHierarchy(ent)
    local model,count=ent:GetModel(),ent:GetBoneCount() or 0
    local rig=rigs[ent]
    if not rig or rig.model~=model or rig.count~=count then
        rig={model=model,count=count,names={},descendants={}} rigs[ent]=rig
    end
    return rig
end
function F.RigBone(ent,name,rig)
    rig=rig or F.BoneHierarchy(ent)
    local bone=rig.names[name]
    if bone==nil then bone=ent:LookupBone(name) rig.names[name]=bone or false end
    return bone or nil
end
function F.CachedBoneDescendant(ent,bone,ancestor,rig)
    if ancestor==nil then return false end
    rig=rig or F.BoneHierarchy(ent)
    if not rig.parents then
        rig.parents={}rig.pendingParents={}
        for id=0,rig.count-1 do
            local parent=ent:GetBoneParent(id)rig.parents[id]=parent
            -- Newly replicated NPCs can report -1 for fingers until their
            -- first bone setup, despite an already stable model/bone count.
            if id~=0 and (not parent or parent<0)then rig.pendingParents[id]=true end
        end
    end
    local members=rig.descendants[ancestor]
    if not members then
        members={} rig.descendants[ancestor]=members
        for id=0,rig.count-1 do
            local current=id
            for _=1,128 do
                if current==ancestor then members[id]=true break end
                current=rig.parents[current]
                if not current or current<0 then break end
            end
        end
    end
    return members[bone] or false
end
function F.RefreshHierarchy(ent)
    local rig=F.BoneHierarchy(ent)
    if not rig.parents or not next(rig.pendingParents or {})or rig.parentRefreshFrame==FrameNumber()then return false end
    rig.parentRefreshFrame=FrameNumber()local changed=false
    for id in pairs(rig.pendingParents)do
        local parent=ent:GetBoneParent(id)
        if parent and parent>=0 then rig.parents[id]=parent rig.pendingParents[id]=nil changed=true end
    end
    if changed then rig.descendants={}end
    return changed
end
function F.Describe(ent)
    local rig=IsValid(ent) and F.BoneHierarchy(ent)
    local sides={}
    for i,spec in ipairs(F.Arms) do
        sides[i]=rig and F.RigBone(ent,spec.prefix.."UpperArm",rig)~=nil and
            F.RigBone(ent,spec.prefix.."Forearm",rig)~=nil and F.RigBone(ent,spec.prefix.."Hand",rig)~=nil or false
    end
    local legs={}
    for i,side in ipairs({"L","R"}) do
        local prefix="ValveBiped.Bip01_"..side.."_"
        legs[i]=rig and F.RigBone(ent,prefix.."Thigh",rig)~=nil and
            F.RigBone(ent,prefix.."Calf",rig)~=nil and F.RigBone(ent,prefix.."Foot",rig)~=nil or false
    end
    return {api=F.API,rig="ValveBiped",arms=sides,legs=legs,
        upperBody=rig and F.RigBone(ent,"ValveBiped.Bip01_Spine",rig)~=nil or false,presentationOnly=true}
end
F.Arms = {
    {side="left", prefix="ValveBiped.Bip01_L_"},
    {side="right", prefix="ValveBiped.Bip01_R_"}
}

function F.SurfaceTangent(normal, aim)
    local tangent = Vector(0, 0, 1) - normal * normal.z
    if tangent:LengthSqr() < 0.01 then tangent = aim - normal * aim:Dot(normal) end
    if tangent:LengthSqr() < 0.01 then tangent = Vector(1, 0, 0) - normal * normal.x end
    if tangent:LengthSqr() < 0.01 then tangent = Vector(0, 1, 0) - normal * normal.y end
    tangent:Normalize()
    return tangent
end

function F.HandProfile(ply, index, matrices)
    local spec = F.Arms[index]
    local scale = ply.GetModelScale and ply:GetModelScale() or 1
    local profile = {length = 2 * scale, depth = 0.35 * scale, clearance = 0.25 * scale}
    if not spec then return profile end
    local function position(suffix)
        local b = ply:LookupBone(spec.prefix .. suffix)
        if not b then return end
        if matrices and matrices[b] then return matrices[b]:GetTranslation() end
        return ply:GetBonePosition(b)
    end
    local wrist, one, two, four = position("Hand"), position("Finger1"), position("Finger2"), position("Finger4")
    if wrist and one and two and four then
        local length = (wrist:Distance(one) + wrist:Distance(two) + wrist:Distance(four)) / 6
        local width = one:Distance(four)
        if length > 0.4 * scale and width > 0.4 * scale then
            profile.length = math.Clamp(length, 0.4 * scale, 4 * scale)
            profile.depth = math.Clamp(width * 0.14, 0.1 * scale, 0.8 * scale)
        end
    end
    return profile
end

-- ValveBiped fingers run along local +X and flex toward local -Y.
-- Align that palm normal into the surface, keeping fingers tangential.
function F.HandFrame(normal, tangent)
    tangent = tangent - normal * tangent:Dot(normal)
    if tangent:LengthSqr() < 0.001 then tangent = F.SurfaceTangent(normal, Vector(1, 0, 0)) end
    tangent:Normalize()
    local across = tangent:Cross(normal)
    across:Normalize()
    local frame = Matrix()
    local columns = {tangent, normal, across}
    for col, v in ipairs(columns) do
        frame:SetField(1, col, v.x)
        frame:SetField(2, col, v.y)
        frame:SetField(3, col, v.z)
    end
    return frame
end

function F.TargetWrist(ply, index, point, normal, tangent, profile)
    profile = profile or F.HandProfile(ply, index)
    tangent = tangent or F.SurfaceTangent(normal, ply:GetAimVector())
    return point + normal * (profile.clearance + profile.depth) - tangent * profile.length
end

-- Analytic two-bone solve. Reject rather than stretch an unreachable arm.
function F.Solve(root, elbow, wrist, target, pole)
    local a, b = root:Distance(elbow), elbow:Distance(wrist)
    local delta = target - root
    local d = delta:Length()
    if a < 1 or b < 1 or d < math.max(math.abs(a - b) + 0.05, 1)
        or d > a + b - 0.05 then return nil end
    local dir = delta / d
    local along = (a * a + d * d - b * b) / (2 * d)
    local bend = (pole or (elbow - root))
    bend = bend - dir * bend:Dot(dir)
    if bend:LengthSqr() < 0.001 then bend = dir:Cross(Vector(0, 0, 1)) end
    if bend:LengthSqr() < 0.001 then bend = dir:Cross(Vector(0, 1, 0)) end
    bend:Normalize()
    return root + dir * along + bend * math.sqrt(math.max(a * a - along * along, 0))
end

function F.Arm(ply, index)
    local spec = F.Arms[index]
    if not spec then return end
    local upper = ply:LookupBone(spec.prefix .. "UpperArm")
    local fore = ply:LookupBone(spec.prefix .. "Forearm")
    local hand = ply:LookupBone(spec.prefix .. "Hand")
    if not upper or not fore or not hand then return end
    local root = ply:GetBonePosition(upper)
    local elbow = ply:GetBonePosition(fore)
    local wrist = ply:GetBonePosition(hand)
    if not root or not elbow or not wrist then return end
    local a, b = root:Distance(elbow), elbow:Distance(wrist)
    if a < 1 or b < 1 then return end
    return {index = index, upper = upper, fore = fore, hand = hand,
        root = root, elbow = elbow, wrist = wrist, reach = a + b, minimum = math.abs(a - b) + 1}
end

