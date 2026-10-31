-- Optional local movement readout; no server state or network traffic.
local enabled = CreateClientConVar("rt_ups_enabled", "0", true, false, "Show movement speed in units per second.")
local horizontal = CreateClientConVar("rt_ups_horizontal", "1", true, false, "Measure horizontal speed only.")
local color = Color(255, 220, 0, 220)
local outline = Color(0, 0, 0, 220)
local hookName = "DashReality.SpeedHUD"

local function drawSpeed()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local velocity = ply:GetVelocity()
    local speed = horizontal:GetBool() and velocity:Length2D() or velocity:Length()
    draw.SimpleTextOutlined("UPS  " .. math.floor(speed + 0.5), "DermaDefaultBold",
        ScrW() - 24, ScrH() - 74, color, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER, 1, outline)
end

local function updateHook()
    hook.Remove("HUDPaint", hookName)
    if enabled:GetBool() then hook.Add("HUDPaint", hookName, drawSpeed) end
end

-- Replacing the callback and hook also makes Lua refresh idempotent.
cvars.RemoveChangeCallback("rt_ups_enabled", hookName)
cvars.AddChangeCallback("rt_ups_enabled", updateHook, hookName)
updateHook()
