-- Optional client-side movement readout; no server state or network traffic.
local enabled = CreateClientConVar("rt_ups_enabled", "0", true, false, "Show movement speed.")
local horizontal = CreateClientConVar("rt_ups_horizontal", "1", true, false, "Measure horizontal speed only.")
local units = CreateClientConVar("rt_ups_units", "0", true, false, "Speed units: 0 UPS, 1 km/h, 2 km/min.")
local source = CreateClientConVar("rt_ups_source", "1", true, false, "Speed source: 0 world displacement, 1 entity velocity.")
local color = Color(255, 220, 0, 235)
local background = Color(0, 0, 0, 145)
local hookName = "DashReality.SpeedHUD"
local SAMPLE_SECONDS, MAX_GAP_SECONDS = 0.1, 0.75
-- Time constant in wall-clock seconds. Weighting by elapsed time keeps the
-- filter's response stable when frames or sample intervals vary.
local SMOOTH_SECONDS = 0.18
local lastPlayer, lastSubject, lastAlive, lastSource, lastTime, lastX, lastY, lastZ
local speed2DSquared, speed3DSquared = 0, 0
local filteredX, filteredY, filteredZ = 0, 0, 0
local layoutValue, layoutLabel, layoutScreenW, layoutScreenH, boxWidth, boxHeight

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function clear()
    lastPlayer, lastSubject, lastAlive, lastSource, lastTime, lastX, lastY, lastZ = nil, nil, nil, nil, nil, nil, nil, nil
    speed2DSquared, speed3DSquared = 0, 0
    filteredX, filteredY, filteredZ = 0, 0, 0
    layoutValue, layoutLabel, layoutScreenW, layoutScreenH, boxWidth, boxHeight = nil, nil, nil, nil, nil, nil
end

local function sample(ply)
    if not IsValid(ply) then clear() return false end
    local vehicle = ply:GetVehicle()
    local driven = not IsValid(vehicle) and ply:GetDrivingEntity() or nil
    -- A seated player can report zero velocity while the vehicle is moving.
    local subject = IsValid(vehicle) and vehicle or IsValid(driven) and driven or ply
    local sourceMode = source:GetInt() == 1 and 1 or 0

    if sourceMode == 1 then
        -- Engine velocity can be used immediately, including on a source or
        -- vehicle change. It needs neither position samples nor smoothing.
        local velocity = subject:GetVelocity()
        if not isvector(velocity) or not finite(velocity.x) or not finite(velocity.y) or not finite(velocity.z) then clear() return false end
        local xy = velocity.x * velocity.x + velocity.y * velocity.y
        local xyz = xy + velocity.z * velocity.z
        if not finite(xy) or not finite(xyz) then clear() return false end
        speed2DSquared, speed3DSquared = xy, xyz
        if lastSource ~= sourceMode then lastTime = nil end
        lastSource = sourceMode
        return true
    end

    local now = RealTime()
    if not finite(now) then clear() return false end
    local alive = ply:Alive()
    local dt = lastTime and now - lastTime or nil
    -- Reacquire on subject/death changes or stale/nonmonotonic clocks rather
    -- than turning a gap into a misleading displacement measurement.
    local reset = lastPlayer ~= ply or lastSubject ~= subject or lastAlive ~= alive or lastSource ~= sourceMode or not dt or dt < 0 or dt > MAX_GAP_SECONDS
    if not reset and dt < SAMPLE_SECONDS then return true end

    -- Read entity position only for acquisition or a new sample, rather than
    -- on every rendered frame. The HUD can still paint at the normal rate.
    local pos = subject:GetPos()
    if not isvector(pos) or not finite(pos.x) or not finite(pos.y) or not finite(pos.z) then clear() return false end
    if reset then
        lastPlayer, lastSubject, lastAlive, lastSource, lastTime = ply, subject, alive, sourceMode, now
        lastX, lastY, lastZ = pos.x, pos.y, pos.z
        speed2DSquared, speed3DSquared = 0, 0
        filteredX, filteredY, filteredZ = 0, 0, 0
        return true
    end
    local vx, vy, vz = (pos.x - lastX) / dt, (pos.y - lastY) / dt, (pos.z - lastZ) / dt
    if not finite(vx) or not finite(vy) or not finite(vz) then clear() return false end
    -- Average signed components before taking magnitude; opposite position
    -- jitter can cancel instead of being counted as extra travel.
    local alpha = 1 - math.exp(-dt / SMOOTH_SECONDS)
    filteredX = filteredX + alpha * (vx - filteredX)
    filteredY = filteredY + alpha * (vy - filteredY)
    filteredZ = filteredZ + alpha * (vz - filteredZ)
    local xy = filteredX * filteredX + filteredY * filteredY
    local xyz = xy + filteredZ * filteredZ
    if not finite(xy) or not finite(xyz) then clear() return false end
    speed2DSquared, speed3DSquared = xy, xyz
    lastX, lastY, lastZ, lastTime = pos.x, pos.y, pos.z, now
    return true
end

local function drawSpeed()
    if not sample(LocalPlayer()) then return end
    local speed = math.sqrt(horizontal:GetBool() and speed2DSquared or speed3DSquared)
    -- GMod's vehicle conversion treats one Source unit as one inch.
    local unitMode = units:GetInt()
    local label, value = "UPS", tostring(math.floor(speed + 0.5))
    if unitMode == 1 then
        label, value = "KM/H", tostring(math.floor(speed * 0.09144 + 0.5))
    elseif unitMode == 2 then
        label, value = "KM/MIN", string.format("%.2f", speed * 0.001524)
    end

    -- Reuse Source's HUD fonts and colors, with a separate centered panel so
    -- it does not occupy the normal ammo counter's lower-right position.
    local screenW, screenH = ScrW(), ScrH()
    if value ~= layoutValue or label ~= layoutLabel or screenW ~= layoutScreenW or screenH ~= layoutScreenH then
        surface.SetFont("HudNumbers")
        local numberWidth, numberHeight = surface.GetTextSize(value)
        surface.SetFont("HudSelectionText")
        local labelWidth = surface.GetTextSize(label)
        boxWidth = math.max(150, numberWidth + labelWidth + 32)
        boxHeight = math.max(56, numberHeight + 12)
        layoutValue, layoutLabel, layoutScreenW, layoutScreenH = value, label, screenW, screenH
    end
    local x, y = math.max(0, math.floor((screenW - boxWidth) / 2)), screenH - boxHeight - 24
    draw.RoundedBox(4, x, y, boxWidth, boxHeight, background)
    draw.SimpleText(label, "HudSelectionText", x + 10, y + boxHeight - 9, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
    draw.SimpleText(value, "HudNumbers", x + boxWidth - 10, y + boxHeight / 2, color, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
end

local function updateHook()
    hook.Remove("HUDPaint", hookName)
    clear()
    if enabled:GetBool() then hook.Add("HUDPaint", hookName, drawSpeed) end
end

-- Replacing the callback and hook also makes Lua refresh idempotent.
cvars.RemoveChangeCallback("rt_ups_enabled", hookName)
cvars.AddChangeCallback("rt_ups_enabled", updateHook, hookName)
updateHook()
