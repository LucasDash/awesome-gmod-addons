-- Experimental server-side proximity approximation for explicit gWater2
-- emission events. This is not particle contact and does not model pools.
if not SERVER then return end

DashReality = DashReality or {}
local NAME, SETTING = "DashReality.GWaterEmissionWater", "rt_gwater_vfire_contact"
local previous = DashReality.GWaterEmissionWater
if previous and isfunction(previous.Shutdown) then previous.Shutdown() end
local function particleOwns()
    local monitor = DashReality.FluidParticleReadiness
    if not game.SinglePlayer() or not monitor or not isfunction(monitor.IsReady) then return false end
    local ok, value = pcall(monitor.IsReady)
    return ok and value == true
end
local enabled = GetConVar(SETTING) or CreateConVar(SETTING, "0", FCVAR_ARCHIVE + FCVAR_NOTIFY,
    "Approximate water-gun emission proximity cools vFire; not particle collision.", 0, 1)

local PER_ACTOR_INTERVAL, PER_TARGET_INTERVAL = 0.25, 0.25
local GLOBAL_RATE, MAX_CANDIDATES, MAX_TARGETS = 8, 64, 4
local RANGE, DOSE = 48, 1
local TRACK_INTERVAL, TRACK_BUDGET, PENDING_LIMIT = 0.25, 64, 2048
local lastActor, lastTarget = setmetatable({}, {__mode="k"}), setmetatable({}, {__mode="k"})
local fires, fireIndex, pending = {}, {}, {}
local pendingHead, pendingTail, pendingCount = 1, 1, 0
local rescan, rescanAt = false, 0
local globalStart, globalCount, cursor = 0, 0, 1
local running = false
local stats = {events=0, accepted=0, rateLimited=0, queries=0, candidates=0,
    traces=0, doses=0, errors=0, dropped=0}

local function track(ent)
    if IsValid(ent) and ent:GetClass() == "vfire" and not fireIndex[ent] then
        fires[#fires + 1] = ent
        fireIndex[ent] = #fires
    end
end

local function forget(ent)
    local index = fireIndex[ent]
    if not index then return end
    local last = fires[#fires]
    fires[index] = last
    fires[#fires] = nil
    fireIndex[ent], lastTarget[ent] = nil, nil
    if last ~= ent then fireIndex[last] = index end
end

local function trackPending()
    for _ = 1, math.min(TRACK_BUDGET, pendingCount) do
        local ent = pending[pendingHead]
        pending[pendingHead] = nil
        pendingHead = pendingHead % PENDING_LIMIT + 1
        pendingCount = pendingCount - 1
        track(ent)
    end
    if rescan and (pendingCount == 0 or CurTime() >= rescanAt) then
        rescan = false
        for _, ent in ipairs(ents.FindByClass("vfire")) do track(ent) end
    end
end

local function finite(n)
    return isnumber(n) and n == n and n ~= math.huge and n ~= -math.huge
end

local function validVector(v)
    return isvector(v) and finite(v.x) and finite(v.y) and finite(v.z)
        and math.abs(v.x) <= 1000000 and math.abs(v.y) <= 1000000 and math.abs(v.z) <= 1000000
end

local function sample(event)
    stats.events = stats.events + 1
    if not istable(event) or event.version ~= 1 or event.shape ~= "sphere"
        or not finite(event.radius) or event.radius <= 0 or event.radius > 32
        or not validVector(event.origin) or not validVector(event.velocity)
        or (event.profile ~= nil and event.profile ~= "water") then return end
    if not istable(gwater2) or not isfunction(gwater2.AddSphere) then return end
    local source, actor = event.source, event.actor
    if not IsValid(source) or not IsValid(actor) or not actor:IsPlayer() or not actor:Alive()
        or source:GetClass() ~= "weapon_gw2_watergun" or source:GetOwner() ~= actor
        or actor:GetActiveWeapon() ~= source then return end
    local eye = actor:EyePos()
    if not validVector(eye) or event.origin:DistToSqr(eye) > 256 * 256 then return end
    local api = DashReality.FluidReactions
    if not api or not isfunction(api.ApplyExposure) then return end

    local now = CurTime()
    if now < (lastActor[actor] or 0) then stats.rateLimited = stats.rateLimited + 1; return end
    if now < globalStart or now - globalStart >= 1 then globalStart, globalCount = now, 0 end
    if globalCount >= GLOBAL_RATE then stats.rateLimited = stats.rateLimited + 1; return end
    globalCount, lastActor[actor] = globalCount + 1, now + PER_ACTOR_INTERVAL
    stats.accepted, stats.queries = stats.accepted + 1, stats.queries + 1
    local length, targets = #fires, 0
    if length == 0 then return end
    if cursor > length then cursor = 1 end
    for _ = 1, math.min(length, MAX_CANDIDATES) do
        local fire = fires[cursor]
        cursor = cursor % length + 1
        stats.candidates = stats.candidates + 1
        if IsValid(fire) and now >= (lastTarget[fire] or 0)
            and validVector(fire:GetPos()) and fire:GetPos():DistToSqr(event.origin) <= RANGE * RANGE then
            targets = targets + 1
            local target = fire:GetPos() + fire:GetForward() * 3
            if validVector(target) then
                stats.traces = stats.traces + 1
                local ok, tr = pcall(util.TraceLine, {start=event.origin, endpos=target,
                    filter={actor, source, fire}, mask=MASK_SOLID})
                if not ok or not istable(tr) or type(tr.Hit) ~= "boolean"
                    or type(tr.StartSolid) ~= "boolean" or type(tr.AllSolid) ~= "boolean" then
                    stats.errors = stats.errors + 1
                elseif not tr.Hit and not tr.StartSolid and not tr.AllSolid then
                    local apply = api.ApplyManagedExposure or api.ApplyExposure
                    local called, applied, reason = pcall(apply, "water", fire, DOSE,
                        {kind="gwater_emission_proximity", source=source, actor=actor})
                    if not called then stats.errors = stats.errors + 1
                    elseif applied then lastTarget[fire] = now + PER_TARGET_INTERVAL; stats.doses = stats.doses + 1
                    elseif reason == "cooldown" then stats.rateLimited = stats.rateLimited + 1 end
                end
            end
            if targets >= MAX_TARGETS then break end
        end
    end
end

local function onEmission(event)
    local ok = pcall(sample, event)
    if not ok then stats.errors = stats.errors + 1 end
    -- Observe only; never block another provider's event hook.
end

local function update()
    running = false
    hook.Remove("GWater2FluidEmission", NAME)
    hook.Remove("OnEntityCreated", NAME)
    hook.Remove("EntityRemoved", NAME)
    timer.Remove(NAME)
    lastActor, lastTarget = setmetatable({}, {__mode="k"}), setmetatable({}, {__mode="k"})
    fires, fireIndex, pending = {}, {}, {}
    pendingHead, pendingTail, pendingCount = 1, 1, 0
    rescan, rescanAt = false, 0
    globalStart, globalCount, cursor = 0, 0, 1
    if not enabled:GetBool() or particleOwns() then return end
    running = true
    for _, ent in ipairs(ents.FindByClass("vfire")) do track(ent) end
    hook.Add("GWater2FluidEmission", NAME, onEmission)
    hook.Add("OnEntityCreated", NAME, function(ent)
        if pendingCount >= PENDING_LIMIT then
            stats.dropped = stats.dropped + 1
            if not rescan then rescan, rescanAt = true, CurTime() + 2 end
            return
        end
        pending[pendingTail] = ent
        pendingTail = pendingTail % PENDING_LIMIT + 1
        pendingCount = pendingCount + 1
    end)
    hook.Add("EntityRemoved", NAME, forget)
    timer.Create(NAME, TRACK_INTERVAL, 0, trackPending)
end

cvars.AddChangeCallback(SETTING, update, NAME)
hook.Add("DashReality.FluidDetectorModeChanged", NAME, update)
DashReality.GWaterEmissionWater = {
    Status = function() return {enabled=running, configured=enabled:GetBool(), events=stats.events, accepted=stats.accepted,
        rateLimited=stats.rateLimited, queries=stats.queries, candidates=stats.candidates,
        traces=stats.traces, doses=stats.doses, errors=stats.errors, dropped=stats.dropped,
        fires=#fires, pending=pendingCount} end,
    Shutdown = function()
        running = false
        hook.Remove("GWater2FluidEmission", NAME); hook.Remove("OnEntityCreated", NAME)
        hook.Remove("EntityRemoved", NAME); hook.Remove("DashReality.FluidDetectorModeChanged", NAME)
        timer.Remove(NAME); cvars.RemoveChangeCallback(SETTING, NAME)
    end
}
update()
