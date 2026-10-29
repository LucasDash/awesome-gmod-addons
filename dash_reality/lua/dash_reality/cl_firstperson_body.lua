-- Optional first-person legs. Saved nonzero legacy body modes render legs only.
local MODE_LEGS = 1

-- Opt in on new installations so an existing first-person body addon is not
-- silently drawn twice. Saved user preferences are retained by the engine.
local cvMode = CreateClientConVar("rt_legs_mode", "0", true, false, "0 off, nonzero shows first-person legs.", 0, 3)
local cvOffset = CreateClientConVar("rt_legs_offset", "18", true, false, "How far behind the camera the body is drawn.", 0, 45)
local cvNoclip = CreateClientConVar("rt_legs_hide_noclip", "1", true, false, "Hide the body while noclipping.", 0, 1)
local cvVehicle = CreateClientConVar("rt_legs_vehicle", "0", true, false, "Draw the body inside vehicles.", 0, 1)

local HIDE_SCALE = Vector(0.001, 0.001, 0.001)
local NORMAL_SCALE = Vector(1, 1, 1)
local DOWN = Vector(0, 0, -1)
local SYNC_INTERVAL = 1

-- Which bones to collapse per mode. A collapsed bone hides its whole subtree.
local HIDDEN_BONES = {[MODE_LEGS] = {"ValveBiped.Bip01_Spine2"}}

-- Models without the ValveBiped skeleton fall back to cutting the mesh with a clip plane at these heights.
local CLIP_ABOVE_FLOOR = {[MODE_LEGS] = 40}

local legs
local legsMode, legsModel
local usePlane = false
local nextSync = 0
local function removeLegs()
    if IsValid(legs) then legs:Remove() end
    legs, legsMode, legsModel = nil, nil, nil
end

-- ManipulateBoneScale does not reliably cascade to children, so every descendant is collapsed explicitly.
local function collapseSubtree(ent, root)
    ent:ManipulateBoneScale(root, HIDE_SCALE)
    for i = 0, ent:GetBoneCount() - 1 do
        local parent = ent:GetBoneParent(i)
        while parent and parent >= 0 do
            if parent == root then
                ent:ManipulateBoneScale(i, HIDE_SCALE)
                break
            end
            parent = ent:GetBoneParent(parent)
        end
    end
end

-- Returns false when the model lacks the skeleton the mode relies on.
local function hideBones(ent, mode)
    for i = 0, ent:GetBoneCount() - 1 do ent:ManipulateBoneScale(i, NORMAL_SCALE) end
    local complete = true
    for _, name in ipairs(HIDDEN_BONES[mode]) do
        local bone = ent:LookupBone(name)
        if bone then
            collapseSubtree(ent, bone)
        elseif mode == MODE_LEGS or name == "ValveBiped.Bip01_Neck1" then
            complete = false
        end
    end
    return complete
end

local function syncAppearance(ply)
    legs:SetSkin(ply:GetSkin())
    legs:SetMaterial(ply:GetMaterial())
    for i = 0, #ply:GetMaterials() - 1 do legs:SetSubMaterial(i, ply:GetSubMaterial(i)) end
    for i = 0, ply:GetNumBodyGroups() - 1 do legs:SetBodygroup(i, ply:GetBodygroup(i)) end
    legs:SetModelScale(ply:GetModelScale())
end

local function buildLegs(ply, mode)
    removeLegs()
    legs = ClientsideModel(ply:GetModel(), RENDERGROUP_OPAQUE)
    if not IsValid(legs) then return end

    legs:SetNoDraw(true)
    legs:DrawShadow(false)
    legs:SetupBones()
    -- Playermodel materials read the player colour through this proxy hook.
    legs.GetPlayerColor = function() return IsValid(ply) and ply:GetPlayerColor() or Vector(1, 1, 1) end
    legsMode, legsModel = mode, ply:GetModel()
    usePlane = not hideBones(legs, mode)
    syncAppearance(ply)
end

local function shouldDraw(ply)
    if not ply:Alive() or ply:GetViewEntity() ~= ply or ply:ShouldDrawLocalPlayer() then return false end
    if IsValid(ply:GetObserverTarget()) then return false end
    if ply:InVehicle() and not cvVehicle:GetBool() then return false end
    if cvNoclip:GetBool() and ply:GetMoveType() == MOVETYPE_NOCLIP then return false end
    return not hook.Run("DashReality.ShouldDisableLegs", ply)
end

local legsCycle, legsSequence, lastAdvance = 0, -1, 0

-- The local player is barely animated by the engine in first person, so its cycle freezes and the body would hold one pose.
-- The sequence still tracks movement correctly; the cycle is advanced here from the real velocity instead.
local function copyAnimation(ply)
    local seq = ply:GetSequence()
    local now = CurTime()
    local dt = math.Clamp(now - lastAdvance, 0, 0.1)
    lastAdvance = now

    if seq ~= legsSequence then legsSequence, legsCycle = seq, 0 end
    local duration = legs:SequenceDuration(seq)
    if duration > 0 then
        local groundSpeed = legs:GetSequenceGroundSpeed(seq)
        local rate = groundSpeed > 1 and ply:GetVelocity():Length2D() / groundSpeed or 1
        legsCycle = (legsCycle + dt * rate / duration) % 1
    end

    legs:SetSequence(seq)
    legs:SetCycle(legsCycle)
    for i = 0, ply:GetNumPoseParameters() - 1 do
        local min, max = ply:GetPoseParameterRange(i)
        legs:SetPoseParameter(ply:GetPoseParameterName(i), math.Remap(ply:GetPoseParameter(ply:GetPoseParameterName(i)), 0, 1, min, max))
    end
end

hook.Add("PostDrawTranslucentRenderables", "DashReality.Legs", function(_, skybox, skybox3d)
    if skybox or skybox3d then return end
    local mode = cvMode:GetInt() == 0 and 0 or MODE_LEGS
    local ply = LocalPlayer()
    if mode == 0 or not IsValid(ply) or not shouldDraw(ply) then
        if legs then removeLegs() end
        return
    end

    if not IsValid(legs) or legsMode ~= mode or legsModel ~= ply:GetModel() then buildLegs(ply, mode) end
    if not IsValid(legs) then return end

    if CurTime() >= nextSync then
        nextSync = CurTime() + SYNC_INTERVAL
        syncAppearance(ply)
    end

    local yaw = ply:GetRenderAngles().y
    local forward = Angle(0, yaw, 0):Forward()
    local pos = ply:GetPos() - forward * cvOffset:GetFloat()
    legs:SetPos(pos)
    legs:SetAngles(Angle(0, yaw, 0))
    copyAnimation(ply)
    legs:SetupBones()

    local color = ply:GetColor()
    local clipped = false
    if usePlane then
        local limit = ply:GetPos().z + CLIP_ABOVE_FLOOR[MODE_LEGS]
        clipped = render.EnableClipping(true)
        render.PushCustomClipPlane(DOWN, -limit)
    end

    render.SetColorModulation(color.r / 255, color.g / 255, color.b / 255)
    render.SetBlend(color.a / 255)
    legs:DrawModel()
    render.SetBlend(1)
    render.SetColorModulation(1, 1, 1)

    if usePlane then
        render.PopCustomClipPlane()
        render.EnableClipping(clipped)
    end
end)

cvars.AddChangeCallback("rt_legs_mode", function() removeLegs() end, "DashReality.Legs")

concommand.Add("rt_legs_refresh", function() removeLegs() end, nil, "Rebuilds the first-person body model.")
hook.Add("ShutDown", "DashReality.Legs", removeLegs)
