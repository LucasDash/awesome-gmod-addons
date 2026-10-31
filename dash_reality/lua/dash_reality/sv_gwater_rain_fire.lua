-- Experimental server-side approximation, NOT gWater particle contact.
-- Only active near-horizontal gWater rain emitters can cool exposed vFire.
if not SERVER then return end

DashReality = DashReality or {}
local previous = DashReality.GWaterRainFire
if previous and previous.Shutdown then previous.Shutdown() end
local function particleOwns()
    local monitor = DashReality.FluidParticleReadiness
    if not game.SinglePlayer() or not monitor or not isfunction(monitor.IsReady) then return false end
    local ok, value = pcall(monitor.IsReady)
    return ok and value == true
end

local NAME = 'DashReality.GWaterRainFire'
local SETTING = 'rt_gwater_vfire_contact'
local INTERVAL, PAIR_BUDGET, TRACE_BUDGET = 0.25, 24, 8
local TRACK_BUDGET, PENDING_LIMIT = 64, 2048
local MAX_DEPTH, MIN_UP, RATE = 1024, 0.98, 1
local enabled = GetConVar(SETTING) or CreateConVar(SETTING, '0',
    FCVAR_ARCHIVE + FCVAR_NOTIFY,
    'Approximate gWater rain exposure on vFire; does not detect particle contact.', 0, 1)

local fires, emitters, fireIndex, emitterIndex = {}, {}, {}, {}
local lastDosed = setmetatable({}, {__mode = 'k'})
local active, fireCursor, emitterCursor = false, 1, 1
local pending, pendingHead, pendingTail, pendingCount = {}, 1, 1, 0
local rescan, rescanAt = false, 0
local stats = {pairs = 0, traces = 0, doses = 0, errors = 0, dropped = 0}

local function add(list, index, ent)
    if index[ent] then return end
    list[#list + 1] = ent
    index[ent] = #list
end

local function remove(list, index, ent)
    local pos = index[ent]
    if not pos then return end
    local last = list[#list]
    list[pos] = last
    list[#list] = nil
    index[ent] = nil
    if last ~= ent then index[last] = pos end
end

local function track(ent)
    if not IsValid(ent) then return end
    local class = ent:GetClass()
    if class == 'vfire' then add(fires, fireIndex, ent)
    elseif class == 'gwater2_rain_emitter' then add(emitters, emitterIndex, ent) end
end

local function forget(ent)
    remove(fires, fireIndex, ent)
    remove(emitters, emitterIndex, ent)
    lastDosed[ent] = nil
end

-- Geometry follows the emitter's actual sampling expression:
-- LocalToWorld(OBBCenter() + random(OBBMins(), OBBMaxs())).
-- Reject tilted emitters because their client particles also fall under gravity.
local function exposure(fire, emitter)
    if not IsValid(fire) or not IsValid(emitter) or not isfunction(fire.SoftExtinguish)
        or not isfunction(emitter.GetOn) or not isfunction(emitter.GetDensity)
        or not emitter:GetOn() then return false end
    local density = emitter:GetDensity()
    if not isnumber(density) or density ~= density or density <= 0 then return false end
    local up = emitter:GetUp()
    if up.z < MIN_UP then return false end
    local mins, maxs, center = emitter:OBBMins(), emitter:OBBMaxs(), emitter:OBBCenter()
    local localFire = emitter:WorldToLocal(fire:GetPos())
    local lowZ = center.z + mins.z
    local depth = lowZ - localFire.z
    if localFire.x < center.x + mins.x or localFire.x > center.x + maxs.x
        or localFire.y < center.y + mins.y or localFire.y > center.y + maxs.y
        or depth < 5 or depth > MAX_DEPTH then return false end
    local endpoint = emitter:LocalToWorld(Vector(localFire.x, localFire.y, lowZ - 2))
    -- vFire orients Forward along the surface normal, so this also clears a
    -- wall-mounted flame without ignoring its parent as potential shelter.
    local startpoint = fire:GetPos() + fire:GetForward() * 3 + up * 2
    return true, density, startpoint, endpoint
end

local function tick()
    if not active then return end
    -- Class names may be unset in OnEntityCreated. Process a bounded deferred
    -- FIFO, avoiding a timer allocation for every newly created entity.
    for _ = 1, math.min(TRACK_BUDGET, pendingCount) do
        local ent = pending[pendingHead]
        pending[pendingHead] = nil
        pendingHead = pendingHead % PENDING_LIMIT + 1
        pendingCount = pendingCount - 1
        track(ent)
    end
    if rescan and (pendingCount == 0 or CurTime() >= rescanAt) then
        rescan = false
        for _, ent in ipairs(ents.FindByClass('vfire')) do track(ent) end
        for _, ent in ipairs(ents.FindByClass('gwater2_rain_emitter')) do track(ent) end
    end
    if #fires == 0 or #emitters == 0 then return end
    local total = math.min(PAIR_BUDGET, #fires * #emitters)
    local traces = 0
    for _ = 1, total do
        if #fires == 0 or #emitters == 0 or traces >= TRACE_BUDGET then break end
        if fireCursor > #fires then fireCursor = 1 end
        if emitterCursor > #emitters then emitterCursor = 1 end
        local fire, emitter = fires[fireCursor], emitters[emitterCursor]
        emitterCursor = emitterCursor + 1
        if emitterCursor > #emitters then emitterCursor = 1; fireCursor = fireCursor + 1 end
        stats.pairs = stats.pairs + 1
        local ok, qualifying, density, startpoint, endpoint = pcall(exposure, fire, emitter)
        if not ok then
            stats.errors = stats.errors + 1
        elseif qualifying and lastDosed[fire] ~= CurTime() then
            traces = traces + 1
            stats.traces = stats.traces + 1
            local traceOk, trace = pcall(util.TraceLine, {
                start = startpoint, endpos = endpoint, mask = MASK_SOLID, filter = {fire, emitter}
            })
            if not traceOk or not istable(trace) then
                stats.errors = stats.errors + 1
            elseif type(trace.Hit) ~= 'boolean' or type(trace.StartSolid) ~= 'boolean'
                or type(trace.AllSolid) ~= 'boolean' then
                stats.errors = stats.errors + 1
            elseif not trace.Hit and not trace.StartSolid and not trace.AllSolid then
                -- A given fire is dosed at most once per timer tick, even with
                -- overlapping emitters. There is no catch-up after skipped work.
                local amount = RATE * INTERVAL * math.min(density / 10, 2)
                local fluid = DashReality.FluidReactions
                local doseOk, applied, reason = false, false, nil
                local apply = fluid and (fluid.ApplyManagedExposure or fluid.ApplyExposure)
                if isfunction(apply) then
                    doseOk, applied, reason = pcall(apply, 'water', fire, amount,
                        {source = emitter, kind = 'gwater_rain'})
                end
                if doseOk and applied then lastDosed[fire] = CurTime(); stats.doses = stats.doses + 1
                elseif not doseOk or reason ~= 'cooldown' then stats.errors = stats.errors + 1 end
            end
        end
    end
end

local function stop()
    active = false
    timer.Remove(NAME)
    hook.Remove('OnEntityCreated', NAME)
    hook.Remove('EntityRemoved', NAME)
    fires, emitters, fireIndex, emitterIndex = {}, {}, {}, {}
    pending, pendingHead, pendingTail, pendingCount = {}, 1, 1, 0
    rescan, rescanAt = false, 0
    lastDosed = setmetatable({}, {__mode = 'k'})
    fireCursor, emitterCursor = 1, 1
end

local function start()
    if active or particleOwns() then return end
    active = true
    hook.Add('OnEntityCreated', NAME, function(ent)
        if pendingCount >= PENDING_LIMIT then
            stats.dropped = stats.dropped + 1
            if not rescan then rescan, rescanAt = true, CurTime() + 2 end
            return
        end
        pending[pendingTail] = ent
        pendingTail = pendingTail % PENDING_LIMIT + 1
        pendingCount = pendingCount + 1
    end)
    hook.Add('EntityRemoved', NAME, forget)
    for _, ent in ipairs(ents.FindByClass('vfire')) do track(ent) end
    for _, ent in ipairs(ents.FindByClass('gwater2_rain_emitter')) do track(ent) end
    timer.Create(NAME, INTERVAL, 0, tick)
end

cvars.AddChangeCallback(SETTING, function(_, _, value)
    if tonumber(value) and tonumber(value) ~= 0 then start() else stop() end
end, NAME)
hook.Add('DashReality.FluidDetectorModeChanged', NAME, function()
    if not enabled:GetBool() or particleOwns() then stop() else start() end
end)

DashReality.GWaterRainFire = {
    Tick = tick,
    Status = function() return {enabled = active, fires = #fires, emitters = #emitters,
        pairBudget = PAIR_BUDGET, traceBudget = TRACE_BUDGET,
        trackBudget = TRACK_BUDGET, pending = pendingCount, pendingLimit = PENDING_LIMIT,
        pairs = stats.pairs, traces = stats.traces, doses = stats.doses,
        errors = stats.errors, dropped = stats.dropped} end,
    Shutdown = function() stop(); hook.Remove('DashReality.FluidDetectorModeChanged', NAME); cvars.RemoveChangeCallback(SETTING, NAME) end
}
if enabled:GetBool() then start() end
