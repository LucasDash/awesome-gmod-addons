local F = ContactIK
F.API = 1
F.Revision = "contact-ik-release1-20261012"
function F.Describe(ent)
    local sides={}
    for i,spec in ipairs(F.Arms) do
        sides[i]=IsValid(ent) and ent:LookupBone(spec.prefix.."UpperArm")~=nil and
            ent:LookupBone(spec.prefix.."Forearm")~=nil and ent:LookupBone(spec.prefix.."Hand")~=nil or false
    end
    local legs={}
    for i,side in ipairs({"L","R"}) do
        local prefix="ValveBiped.Bip01_"..side.."_"
        legs[i]=IsValid(ent) and ent:LookupBone(prefix.."Thigh")~=nil and
            ent:LookupBone(prefix.."Calf")~=nil and ent:LookupBone(prefix.."Foot")~=nil or false
    end
    return {api=F.API,rig="ValveBiped",arms=sides,legs=legs,
        upperBody=IsValid(ent) and ent:LookupBone("ValveBiped.Bip01_Spine")~=nil or false,presentationOnly=true}
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

