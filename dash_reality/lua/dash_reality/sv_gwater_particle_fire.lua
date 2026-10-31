-- Private candidate. A singleplayer client reports nearby solver particles;
-- this is proximity, not collision history or verified material identity.
if not SERVER then return end

DashReality = DashReality or {}
local NAME = "DashReality.GWaterParticleFire"
local MESSAGE = "DashReality.GWaterParticleFire"
local SETTING = "rt_gwater_vfire_contact"
local previous = DashReality.GWaterParticleFire
if previous and isfunction(previous.Shutdown) then previous.Shutdown() end

local enabled = GetConVar(SETTING) or CreateConVar(SETTING, "0",
    FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
    "Experimental singleplayer gWater-particle proximity to vFire.", 0, 1)
local RANGE, INTERVAL, GLOBAL_RATE = 2048, 0.25, 8
local nextFire = setmetatable({}, {__mode = "k"})
local windowStart, windowCount = 0, 0
local active = true
local stats = {received = 0, rejected = 0, rateLimited = 0, doses = 0, errors = 0}

local function validPosition(pos)
    if not isvector(pos) then return false end
    for _, coordinate in ipairs({pos.x, pos.y, pos.z}) do
        if not isnumber(coordinate) or coordinate ~= coordinate
            or math.abs(coordinate) > 1000000 then return false end
    end
    return true
end

local function report(length, ply)
    stats.received = stats.received + 1
    -- A client-side solver is not authoritative in multiplayer. No remote
    -- client, listen host or dedicated server may supply contact claims.
    if not active or not enabled:GetBool() or not game.SinglePlayer() or game.IsDedicated() then
        stats.rejected = stats.rejected + 1; return
    end
    local humans = player.GetHumans()
    if #humans ~= 1 or humans[1] ~= ply or not IsValid(ply) or not ply:IsPlayer()
        or not ply:Alive() or not isnumber(length) or length > 64 then
        stats.rejected = stats.rejected + 1; return
    end
    -- An optional ownership coordinator prevents simultaneous legacy and
    -- particle adapters. Without it, retain the standalone candidate API.
    local readiness = DashReality.FluidParticleReadiness
    if readiness ~= nil then
        if not istable(readiness) or not isfunction(readiness.IsReady) then
            stats.rejected = stats.rejected + 1; return
        end
        local ok, ready = pcall(readiness.IsReady)
        if not ok or ready ~= true then stats.rejected = stats.rejected + 1; return end
    end
    local fire, count, creationID = net.ReadEntity(), net.ReadUInt(3), net.ReadUInt(24)
    if not IsValid(fire) or fire:GetClass() ~= "vfire"
        or not isnumber(count) or count < 1 or count > 4 or count % 1 ~= 0
        or not isfunction(fire.GetCreationID) or fire:GetCreationID() ~= creationID
        or not istable(gwater2) or not isfunction(gwater2.AddSphere) then
        stats.rejected = stats.rejected + 1; return
    end
    local from, to = ply:GetPos(), fire:GetPos()
    if not validPosition(from) or not validPosition(to) or from:DistToSqr(to) > RANGE * RANGE then
        stats.rejected = stats.rejected + 1; return
    end
    local now = CurTime()
    if now < windowStart or now - windowStart >= 1 then windowStart, windowCount = now, 0 end
    local due = nextFire[fire]
    if due and now < due - INTERVAL then nextFire[fire] = nil; due = nil end
    if (due and now < due) or windowCount >= GLOBAL_RATE then
        stats.rateLimited = stats.rateLimited + 1; return
    end
    local fluid = DashReality.FluidReactions
    if not istable(fluid) then stats.errors = stats.errors + 1; return end
    local dispatch = isfunction(fluid.ApplyManagedExposure) and fluid.ApplyManagedExposure or fluid.ApplyExposure
    if not isfunction(dispatch) then stats.errors = stats.errors + 1; return end
    windowCount = windowCount + 1
    nextFire[fire] = now + INTERVAL
    local ok, applied, reason = pcall(dispatch, "water", fire, count / 4,
        {kind = "gwater_particle_proximity", actor = ply, particles = count})
    if ok and applied then stats.doses = stats.doses + 1
    elseif ok and reason == "cooldown" then stats.rateLimited = stats.rateLimited + 1
    else stats.errors = stats.errors + 1 end
end

util.AddNetworkString(MESSAGE)
net.Receive(MESSAGE, report)
DashReality.GWaterParticleFire = {
    Status = function()
        local configured = active and enabled:GetBool()
        local mode = not configured and "disabled"
            or (game.SinglePlayer() and not game.IsDedicated()) and "singleplayer" or "unsupported"
        return {enabled = configured, mode = mode, singleplayerOnly = true,
        received = stats.received, rejected = stats.rejected, rateLimited = stats.rateLimited,
        doses = stats.doses, errors = stats.errors}
    end,
    Shutdown = function()
        active = false
        if istable(net.Receivers) and net.Receivers[string.lower(MESSAGE)] == report then
            net.Receivers[string.lower(MESSAGE)] = nil
        end
    end
}
