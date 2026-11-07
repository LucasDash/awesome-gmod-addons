-- Presentation-only NPC/NextBot camera. Server authorizes selection through
-- the regular Tool Gun trace; the client owns and can always close its view.
local RT = DashReality
if RT.NPCCamera and RT.NPCCamera.Shutdown then RT.NPCCamera.Shutdown() end
local Camera = {}
RT.NPCCamera = Camera
local target, mode
local orbitYaw, orbitPitch = 0, 0
local dragX, dragY
local function resetOrbit()
    orbitYaw, orbitPitch, dragX, dragY = 0, 0, nil, nil
end
local function stop()
    target, mode = nil, nil
    resetOrbit()
end
Camera.Stop = stop
function Camera.Active() return IsValid(target) end

local function selectedTool(ply)
    local weapon = ply:GetActiveWeapon()
    return IsValid(weapon) and weapon:GetClass() == "gmod_tool"
        and isfunction(weapon.GetMode) and weapon:GetMode() == "rt_npc_camera"
end
local function usable(ply)
    return IsValid(ply) and ply:Alive() and ply:GetViewEntity() == ply and selectedTool(ply)
        and IsValid(target) and not target:IsDormant()
end
local function eyeView(ent)
    local attachment = ent:LookupAttachment("eyes")
    local eye = attachment and attachment > 0 and ent:GetAttachment(attachment) or nil
    local pos = eye and eye.Pos or ent:EyePos()
    -- EyeAngles follows the character's aim even when a model's eye attachment
    -- has unusual rotational axes. Both fallbacks are visual approximations.
    local angles = ent:EyeAngles()
    if not isangle(angles) then angles = eye and eye.Ang or ent:GetAngles() end
    return pos, angles
end

net.Receive("DashReality.NPCCamera", function()
    local incoming, incomingMode = net.ReadEntity(), net.ReadUInt(2)
    if incomingMode == 0 then stop() return end
    local ply = LocalPlayer()
    if (incomingMode ~= 1 and incomingMode ~= 2) or not IsValid(incoming)
        or not (incoming:IsNPC() or incoming:IsNextBot()) or not IsValid(ply)
        or not ply:Alive() or ply:GetViewEntity() ~= ply or not selectedTool(ply) then
        stop()
        return
    end
    resetOrbit()
    target, mode = incoming, incomingMode
end)

-- Early priority prevents the optional death and body modifiers from editing
-- this camera. Other addons' CalcView ownership is not overridden or replaced.
RT.AddViewModifier("npc_camera", 10, function(ply, view)
    if not usable(ply) then stop() return end
    local pos, angles = eyeView(target)
    if not isvector(pos) or not isangle(angles) then stop() return end
    local viewAngles = angles
    if mode == 2 and (orbitYaw ~= 0 or orbitPitch ~= 0) then
        -- The offsets are relative to the target's current eye direction, so
        -- the camera follows as the actor turns while retaining the orbit.
        viewAngles = Angle(math.Clamp(angles.p + orbitPitch, -80, 80), angles.y + orbitYaw, 0)
    end
    if mode == 1 then
        view.origin = pos + angles:Forward() * 2
    else
        local destination = pos - viewAngles:Forward() * 120 + Vector(0, 0, 24)
        local tr = util.TraceHull({start = pos, endpos = destination,
            mins = Vector(-5, -5, -5), maxs = Vector(5, 5, 5),
            filter = {ply, target}, mask = MASK_SOLID})
        if not tr or tr.StartSolid or tr.AllSolid then stop() return end
        view.origin = tr.Hit and tr.HitPos + tr.HitNormal * 2 or destination
    end
    view.angles, view.drawviewer = viewAngles, false
    return "stop"
end)

-- Holding the normal Sandbox context menu and dragging middle mouse provides
-- opt-in orbit input. We read the existing cursor only: no binds, cursor state,
-- mouse events, player movement or view angles are changed or consumed.
local function updateOrbit()
    local context = IsValid(g_ContextMenu) and g_ContextMenu:IsVisible()
    if mode ~= 2 or not context or not vgui.CursorVisible()
        or gui.IsGameUIVisible() or gui.IsConsoleVisible() or not input.IsMouseDown(MOUSE_MIDDLE) then
        dragX, dragY = nil, nil
        return
    end
    local x, y = input.GetCursorPos()
    if not isnumber(x) or not isnumber(y) or x ~= x or y ~= y or math.abs(x) == math.huge or math.abs(y) == math.huge then
        dragX, dragY = nil, nil
        return
    end
    if dragX and dragY then
        local dx = math.Clamp(x - dragX, -250, 250)
        local dy = math.Clamp(y - dragY, -250, 250)
        orbitYaw = math.NormalizeAngle(orbitYaw - dx * 0.25)
        orbitPitch = math.Clamp(orbitPitch + dy * 0.25, -75, 75)
    end
    dragX, dragY = x, y
end

hook.Add("Think", "DashReality.NPCCamera", function()
    if not target then return end
    if not usable(LocalPlayer()) then stop() return end
    updateOrbit()
end)
concommand.Add("dash_npc_camera_exit", stop, nil, "Return from the NPC camera to your own view.")
concommand.Add("dash_npc_camera_orbit_reset", resetOrbit, nil, "Reset the NPC trailing camera orbit.")
hook.Add("HUDPaint", "DashReality.NPCCamera", function()
    if not target then return end
    local hint = mode == 2 and "  |  Context menu + middle-drag to orbit" or ""
    draw.SimpleText("NPC camera (" .. (mode == 1 and "eyes" or "behind") .. ")  -  Reload or dash_npc_camera_exit to exit" .. hint,
        "DermaDefaultBold", ScrW() / 2, ScrH() - 80, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
hook.Add("PreDrawViewModel", "DashReality.NPCCamera", function()
    if target then return true end
end)
hook.Add("DashReality.ShouldDisableLegs", "DashReality.NPCCamera", function()
    if target then return true end
end)
hook.Add("EntityRemoved", "DashReality.NPCCamera", function(ent)
    if ent == target then stop() end
end)
hook.Add("PreCleanupMap", "DashReality.NPCCamera", stop)
hook.Add("ShutDown", "DashReality.NPCCamera", stop)

function Camera.Shutdown()
    stop()
    RT.RemoveViewModifier("npc_camera")
    for _, event in ipairs({"Think", "HUDPaint", "PreDrawViewModel",
        "DashReality.ShouldDisableLegs", "EntityRemoved", "PreCleanupMap", "ShutDown"}) do
        hook.Remove(event, "DashReality.NPCCamera")
    end
end
