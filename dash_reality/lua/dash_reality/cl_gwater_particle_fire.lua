-- Private singleplayer candidate. This probes the local gWater solver for any
-- nearby liquid particles, regardless of their source or visual fluid preset.
-- It does not report particle identity, trajectories or physical collisions.
if not CLIENT then return end

DashReality = DashReality or {}
local NAME = "DashReality.GWaterParticleFireClient"
local WATCHER = NAME .. ".Settings"
local MESSAGE = "DashReality.GWaterParticleFire"
local SETTING = "rt_gwater_vfire_contact"
local previous = DashReality.GWaterParticleFireClient
if previous and isfunction(previous.Shutdown) then previous.Shutdown() end

local INTERVAL, DISCOVERY_INTERVAL, SCAN_BUDGET, QUERY_BUDGET, RADIUS, RANGE = 0.25, 1, 64, 2, 24, 2048
local TRACK_BUDGET, FIRE_LIMIT = 64, 2048
local fires, indexes = {}, {}
local discovery, discoveryIndex, discoveryLimit, nextDiscovery, lastDiscovery, cursor = nil, 1, 0, 0, nil, 1
local active = false
local stats = {discoveries = 0, scanned = 0, queries = 0, positives = 0, reports = 0, errors = 0, dropped = 0}

local function track(ent)
    if not IsValid(ent) or ent:GetClass() ~= "vfire" or indexes[ent] then return end
    if #fires >= FIRE_LIMIT then stats.dropped = stats.dropped + 1; return end
    fires[#fires + 1] = ent; indexes[ent] = #fires
end

local function forget(ent)
    local index = indexes[ent]
    if not index then return end
    local last = fires[#fires]
    fires[index] = last; fires[#fires] = nil; indexes[ent] = nil
    if last ~= ent then indexes[last] = index end
    if cursor > #fires then cursor = 1 end
end

-- Class names may not be available in OnEntityCreated. A bounded periodic
-- class-only reconciliation catches such fires after initialization without
-- buffering the unrelated client entities produced by particle effects.
local function discover(now)
    if lastDiscovery and now < lastDiscovery then discovery, nextDiscovery = nil, now end
    lastDiscovery = now
    if not discovery and now >= nextDiscovery then
        discovery = ents.FindByClass("vfire")
        discoveryIndex = 1
        discoveryLimit = math.min(#discovery, FIRE_LIMIT)
        nextDiscovery = now + DISCOVERY_INTERVAL
        stats.discoveries = stats.discoveries + 1
        if #discovery > FIRE_LIMIT then stats.dropped = stats.dropped + #discovery - FIRE_LIMIT end
    end
    if not discovery then return end
    for _ = 1, TRACK_BUDGET do
        if discoveryIndex > discoveryLimit then break end
        track(discovery[discoveryIndex]); discoveryIndex = discoveryIndex + 1
    end
    if discoveryIndex > discoveryLimit then discovery = nil end
end

local function tick()
    if not active or not game.SinglePlayer() or game.IsDedicated() then return end
    local ply = LocalPlayer()
    local solver = istable(gwater2) and gwater2.solver
    if not IsValid(ply) or not ply:Alive() or not solver
        or not isfunction(solver.GetActiveParticles) or not isfunction(solver.GetParticlesInRadius) then
        stats.solverReady = false; return
    end
    local ok, amount = pcall(solver.GetActiveParticles, solver)
    if not ok or not isnumber(amount) or amount ~= amount or amount < 0 or amount == math.huge then
        stats.solverReady = false; stats.errors = stats.errors + 1; return
    end
    -- Availability is provisional until a real particle query has succeeded.
    stats.solverReady = true
    discover(CurTime())
    if amount == 0 or #fires == 0 then return end
    local origin = ply:GetPos()
    if not isvector(origin) then return end
    -- Checking a cached fire's range is cheap compared with a solver query,
    -- which can inspect every active particle. Skip far entries promptly while
    -- keeping both work types bounded and preserving round-robin fairness.
    local examined, queries = 0, 0
    local limit = math.min(SCAN_BUDGET, #fires)
    while examined < limit and queries < QUERY_BUDGET and #fires > 0 do
        if cursor > #fires then cursor = 1 end
        local fire = fires[cursor]
        examined = examined + 1; stats.scanned = stats.scanned + 1
        if not IsValid(fire) then
            forget(fire)
        else
            cursor = cursor + 1
            local position = fire:GetPos()
            if isvector(position) and origin:DistToSqr(position) <= RANGE * RANGE then
                queries = queries + 1; stats.queries = stats.queries + 1
                local success, count = pcall(solver.GetParticlesInRadius, solver,
                    position + fire:GetForward() * 3, RADIUS, 4)
                local valid = success and isnumber(count) and count == count and count >= 0 and count ~= math.huge
                stats.lastQueryAt, stats.lastQueryOK = CurTime(), valid
                if not valid then
                    stats.lastQueryErrorAt = stats.lastQueryAt
                    stats.errors = stats.errors + 1
                elseif count >= 1 then
                    stats.positives = stats.positives + 1
                    -- Do not send until the server registered its optional receiver.
                    local id = util.NetworkStringToID(MESSAGE)
                    local creationID = isfunction(fire.GetCreationID) and fire:GetCreationID() or nil
                    if isnumber(id) and id > 0 and isnumber(creationID) and creationID == creationID
                        and creationID >= 0 and creationID < 16777216 and creationID % 1 == 0 then
                        net.Start(MESSAGE)
                        net.WriteEntity(fire)
                        net.WriteUInt(math.min(4, math.floor(count)), 3)
                        net.WriteUInt(creationID, 24)
                        net.SendToServer()
                        stats.reports = stats.reports + 1
                    end
                end
            end
        end
    end
end

local function stop()
    active = false; timer.Remove(NAME)
    hook.Remove("EntityRemoved", NAME); hook.Remove("vFireCreated", NAME)
    fires, indexes = {}, {}
    discovery, discoveryIndex, discoveryLimit, nextDiscovery, lastDiscovery, cursor = nil, 1, 0, 0, nil, 1
    stats.solverReady, stats.lastQueryAt, stats.lastQueryOK, stats.lastQueryErrorAt = nil, nil, nil, nil
end

local function update()
    local enabled = GetConVar(SETTING)
    if not enabled or not enabled:GetBool() or not game.SinglePlayer() or game.IsDedicated() then
        if active then stop() end
        return
    end
    if active then return end
    active = true
    discover(CurTime())
    -- vFire emits this after initializing its client entity; unlike the
    -- generic entity-created event it does not enqueue unrelated particles.
    hook.Add("vFireCreated", NAME, function(ent) track(ent) end)
    hook.Add("EntityRemoved", NAME, forget)
    timer.Create(NAME, INTERVAL, 0, tick)
end

cvars.AddChangeCallback(SETTING, update, NAME)
-- Replicated convars may change without delivering a client Lua callback.
-- Keep an inexpensive singleplayer watcher alive even when sampling is off.
if game.SinglePlayer() and not game.IsDedicated() then timer.Create(WATCHER, 1, 0, update) end
DashReality.GWaterParticleFireClient = {
    Status = function() return {enabled = active, fires = #fires,
        pending = discovery and math.max(0, discoveryLimit - discoveryIndex + 1) or 0,
        discoveries = stats.discoveries, discoveryInterval = DISCOVERY_INTERVAL, trackBudget = TRACK_BUDGET,
        solverReady = stats.solverReady, lastQueryAt = stats.lastQueryAt,
        lastQueryOK = stats.lastQueryOK, lastQueryErrorAt = stats.lastQueryErrorAt,
        scanBudget = SCAN_BUDGET, scanned = stats.scanned,
        queryBudget = QUERY_BUDGET, queries = stats.queries, positives = stats.positives,
        reports = stats.reports, errors = stats.errors, dropped = stats.dropped} end,
    Shutdown = function() stop(); timer.Remove(WATCHER); cvars.RemoveChangeCallback(SETTING, NAME) end
}
update()
