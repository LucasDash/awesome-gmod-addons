-- Periodic singleplayer-only capability report. It does not send contact or
-- claim that the solver has sampled every fire or identified fluid material.
if not CLIENT then return end
DashReality = DashReality or {}
local NAME, MESSAGE = "DashReality.FluidParticleReadinessClient", "DashReality.FluidParticleReadiness"
local SETTING = "rt_gwater_vfire_contact"
local previous = DashReality.FluidParticleReadinessClient
if previous and isfunction(previous.Shutdown) then previous.Shutdown() end
local active = true
local stats = {reports=0, ready=false, reason="not_checked"}

local function tick()
    if not active or not game.SinglePlayer() or game.IsDedicated() then return end
    local setting, ply = GetConVar(SETTING), LocalPlayer()
    if not setting or not setting:GetBool() or not IsValid(ply) or not ply:Alive() then return end
    local observer = DashReality.GWaterParticleFireClient
    local solver = istable(gwater2) and gwater2.solver
    local observerState = observer and isfunction(observer.Status) and observer.Status() or nil
    local available = solver and isfunction(solver.GetActiveParticles) and isfunction(solver.GetParticlesInRadius)
        and istable(observerState) and observerState.enabled and observerState.lastQueryOK ~= false
    local reason = available and "available" or "unavailable"
    if available then
        local ok, count = pcall(solver.GetActiveParticles, solver)
        available = ok and isnumber(count) and count == count and count >= 0 and count < math.huge
        if not available then reason = "solver_error" end
    end
    stats.ready, stats.reason = available == true, reason
    local id = util.NetworkStringToID(MESSAGE)
    if not isnumber(id) or id <= 0 then return end
    net.Start(MESSAGE); net.WriteBool(stats.ready); net.SendToServer()
    stats.reports = stats.reports + 1
end

if game.SinglePlayer() and not game.IsDedicated() then timer.Create(NAME, 1, 0, tick) end
DashReality.FluidParticleReadinessClient = {
    Status = function() return {ready=stats.ready, reason=stats.reason, reports=stats.reports} end,
    Shutdown = function() active=false; timer.Remove(NAME) end,
}
