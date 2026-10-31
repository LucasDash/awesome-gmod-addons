-- Singleplayer-only readiness for selecting the gWater detector. This is a
-- capability heartbeat, not a fluid-contact claim. Multiplayer always uses
-- server-owned fallback sources and never trusts a client report.
if not SERVER then return end
DashReality = DashReality or {}
local NAME, MESSAGE = "DashReality.FluidParticleReadiness", "DashReality.FluidParticleReadiness"
local SETTING = "rt_gwater_vfire_contact"
local previous = DashReality.FluidParticleReadiness
if previous and isfunction(previous.Shutdown) then previous.Shutdown() end

local enabled = GetConVar(SETTING)
assert(enabled, "fluid master setting must exist before readiness loads")
local active, reported, expires, lastReady, nextMessage = true, false, 0, false, 0
local timeout, interval = 2.5, 0.5
local stats = {received=0, rejected=0, transitions=0}

local function ready()
    return active and enabled:GetBool() and game.SinglePlayer() and not game.IsDedicated()
        and reported and CurTime() < expires
end
local function reconcile()
    local value = ready()
    if value == lastReady then return end
    lastReady = value; stats.transitions = stats.transitions + 1
    hook.Run("DashReality.FluidDetectorModeChanged", value)
end
local function receive(length, ply)
    stats.received = stats.received + 1
    local humans = player.GetHumans()
    if not active or not enabled:GetBool() or not game.SinglePlayer() or game.IsDedicated()
        or #humans ~= 1 or humans[1] ~= ply or not IsValid(ply) or not ply:IsPlayer()
        or not isnumber(length) or length < 1 or length > 64 then
        stats.rejected = stats.rejected + 1; return
    end
    local now = CurTime()
    if now < nextMessage - 0.25 then nextMessage = 0 end
    if now < nextMessage then stats.rejected = stats.rejected + 1; return end
    nextMessage = now + 0.25
    local clientReady = net.ReadBool()
    reported = clientReady == true and istable(gwater2) and isfunction(gwater2.AddSphere)
    expires = reported and (now + timeout) or 0
    reconcile()
end

util.AddNetworkString(MESSAGE)
net.Receive(MESSAGE, receive)
timer.Create(NAME, interval, 0, reconcile)
cvars.AddChangeCallback(SETTING, reconcile, NAME)
DashReality.FluidParticleReadiness = {
    IsReady = ready,
    Status = function() return {ready=ready(), reported=reported, expires=expires,
        received=stats.received, rejected=stats.rejected, transitions=stats.transitions} end,
    Shutdown = function()
        -- lastReady is the mode already delivered to adapters. It can still
        -- be true after the heartbeat expires but before the next timer tick.
        local wasReady = lastReady
        active, reported, expires = false, false, 0
        timer.Remove(NAME); cvars.RemoveChangeCallback(SETTING, NAME)
        if istable(net.Receivers) and net.Receivers[string.lower(MESSAGE)] == receive then
            net.Receivers[string.lower(MESSAGE)] = nil
        end
        if wasReady then hook.Run("DashReality.FluidDetectorModeChanged", false) end
    end,
}
