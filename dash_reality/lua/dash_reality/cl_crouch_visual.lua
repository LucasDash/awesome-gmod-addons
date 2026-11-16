-- Client-only root-bone correction for the hull shift during airborne crouch.
-- The native hull, player position and first-person view are not changed.
local D = DashReality
if D.CrouchVisual and D.CrouchVisual.Shutdown then D.CrouchVisual.Shutdown() end
-- Clear the former render-matrix implementation on a live refresh.
local legacy = (hook.GetTable().PostRender or {})["DashReality.CrouchVisual"]
if isfunction(legacy) then legacy() end
for _, event in ipairs({"PrePlayerDraw", "PostPlayerDraw", "PostRender"}) do
    hook.Remove(event, "DashReality.CrouchVisual")
end
local enabled = CreateClientConVar("rt_crouch_visual", "0", true, false, "Smooth airborne crouch model position")
local states = setmetatable({}, {__mode = "k"})
local roots = setmetatable({}, {__mode = "k"})
local hookName = "DashReality.CrouchVisual"

local function getRoot(ply)
    local model, count = ply:GetModel(), ply:GetBoneCount() or 0
    local cache = roots[ply]
    if cache and cache.model == model and cache.count == count then return cache.root end
    local root, found = nil, 0
    if count > 0 and count <= 256 then
        for i = 0, count - 1 do
            local name = ply:GetBoneName(i)
            if name and name ~= "__INVALIDBONE__" and ply:GetBoneParent(i) == -1 then
                root, found = i, found + 1
            end
        end
    end
    if found ~= 1 then root = nil end
    roots[ply] = {model = model, count = count, root = root}
    return root
end

local function release(ply, sample)
    if not sample.applied then return end
    if IsValid(ply) and ply:GetModel() == sample.model then
        local current = ply:GetManipulateBonePosition(sample.root)
        if isvector(current) and current:DistToSqr(sample.applied) < 0.01 then
            ply:ManipulateBonePosition(sample.root, sample.original)
        end
    end
    sample.applied, sample.original, sample.root, sample.model = nil, nil, nil, nil
end

local function update(ply)
    local sample = states[ply]
    if not IsValid(ply) or not ply:Alive() or ply:InVehicle() then
        if sample then release(ply, sample) end
        states[ply] = nil
        return
    end
    local pos, velocity = ply:GetPos(), ply:GetVelocity()
    local airborne, ducking = not ply:OnGround(), ply:Crouching()
    local _, stand = ply:GetHull()
    local _, duck = ply:GetHullDuck()
    local depth = math.Clamp(stand.z - duck.z, 0, 36)
    local now = CurTime()
    if not sample then
        sample = {time=now, z=pos.z, velocity=velocity.z, duck=ducking, offset=0}
        states[ply] = sample
    else
        local dt = now - sample.time
        if not airborne or dt > 0.15 then
            sample.offset, sample.direction, sample.blocked = 0, nil, nil
        else
            if ducking ~= sample.duck then
                sample.direction = ducking and 1 or -1
                sample.untilTime = now + 0.18
            end
            if sample.direction and now <= sample.untilTime and dt > 0 then
                -- Duck flags can precede the interpolated origin shift. Remove
                -- only displacement beyond ordinary vertical movement, as seen.
                local movement = (sample.velocity + velocity.z) * 0.5 * dt
                local jump = pos.z - sample.z - movement
                if sample.direction * jump > 1 then
                    sample.offset = math.Clamp(sample.offset - jump, -depth, 0)
                end
            elseif sample.direction and now > sample.untilTime then
                sample.direction = nil
            end
        end
        sample.time, sample.z, sample.velocity, sample.duck = now, pos.z, velocity.z, ducking
    end
    if not airborne then sample.offset, sample.direction, sample.blocked = 0, nil, nil end
    if sample.offset < -0.05 and depth > 0 then
        local tr = util.TraceLine({start=pos, endpos=pos - Vector(0,0,depth), filter=ply, mask=MASK_PLAYERSOLID})
        sample.offset = math.max(sample.offset, -depth * tr.Fraction)
    end
    if math.abs(sample.offset) < 0.05 then release(ply, sample) return end
    local root = getRoot(ply)
    if root == nil then release(ply, sample) return end
    if sample.applied and (sample.root ~= root or sample.model ~= ply:GetModel()) then release(ply, sample) end
    if sample.blocked then return end
    local current = ply:GetManipulateBonePosition(root)
    if not isvector(current) then return end
    if sample.applied and current:DistToSqr(sample.applied) >= 0.01 then
        -- Another addon took ownership of this bone. Leave its value alone.
        sample.applied, sample.original, sample.root, sample.model = nil, nil, nil, nil
        sample.blocked = true
        return
    end
    if not sample.applied then
        sample.original = Vector(current.x, current.y, current.z)
        sample.root, sample.model = root, ply:GetModel()
    end
    local adjusted = sample.original + Vector(0, 0, sample.offset)
    if not sample.applied or sample.applied:DistToSqr(adjusted) >= 0.01 then
        ply:ManipulateBonePosition(root, adjusted)
        sample.applied = adjusted
    end
end

local function clear()
    for ply, sample in pairs(states) do release(ply, sample) states[ply] = nil end
end
local function setEnabled()
    hook.Remove("Think", hookName)
    clear()
    if enabled:GetBool() then
        hook.Add("Think", hookName, function() for _, ply in ipairs(player.GetAll()) do update(ply) end end)
    end
end
local function shutdown()
    hook.Remove("Think", hookName)
    hook.Remove("ShutDown", hookName)
    cvars.RemoveChangeCallback("rt_crouch_visual", hookName)
    clear()
end
cvars.RemoveChangeCallback("rt_crouch_visual", hookName)
cvars.AddChangeCallback("rt_crouch_visual", setEnabled, hookName)
hook.Add("ShutDown", hookName, shutdown)
D.CrouchVisual = {Shutdown=shutdown}
setEnabled()
