-- Server-owned material responses. Source adapters must establish exposure;
-- this API does not infer fluid identity or particle contact from client data.
if not SERVER then return end

DashReality = DashReality or {}
local prior = DashReality.FluidReactions
if not istable(prior) or prior.Version ~= 1 then prior = nil end
local registry = prior and istable(prior._registry) and prior._registry or {}
local owners = prior and istable(prior._owners) and prior._owners or {}
local MAX_DOSE = 1

local function identifier(value)
    return isstring(value) and #value <= 96 and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

-- Registered handlers run as trusted server addon code: (entity, dose, context).
-- No client message or remote registration is installed by this module.
local function registerPreset(id, definition)
    if not identifier(id) or not istable(definition) or not istable(definition.targets) then
        return false, "invalid_preset"
    end
    if registry[id] then return false, "already_registered" end
    local handlers, count = {}, 0
    for class, handler in pairs(definition.targets) do
        if not identifier(class) or not isfunction(handler) then return false, "invalid_target_handler" end
        count = count + 1
        if count > 64 then return false, "too_many_target_handlers" end
        handlers[class] = handler
    end
    if count == 0 then return false, "empty_preset" end
    registry[id] = handlers
    local token = {}
    owners[id] = token
    return true, token
end

-- Two consecutive dense, timely particle samples are required before the
-- stronger response. Weak keys prevent this short-lived state owning fires.
-- A reload intentionally starts fresh rather than trusting stale observations.
local wetSamples = setmetatable({}, {__mode = "k"})

-- Replace the built-in response on reload while retaining independently
-- registered server integrations and the API table identity.
registry.water = {
    vfire = function(target, dose, context)
        if not isfunction(target.SoftExtinguish) then return false, "provider_unavailable" end
        -- vFire's SoftExtinguish subtracts life but leaves feed and scheduled
        -- spreading intact. Confirm sustained dense liquid proximity before
        -- extinguishing this flame through vFire's life/death handling.
        -- The solver provides proximity, not collision or occlusion proof.
        if istable(context) and context.kind == "gwater_particle_proximity" then
            local count, now = context.particles, CurTime()
            local previous = wetSamples[target]
            if isnumber(count) and count >= 4 then
                local life = target.life
                if previous and now >= previous + 0.1 and now <= previous + 0.8
                    and isnumber(life) and life == life and math.abs(life) < 1000000
                    and isfunction(target.LifeThink) then
                    -- Tested vFire checks life <= 0 first in LifeThink and
                    -- removes itself, invoking its normal OnRemove cleanup.
                    target:SoftExtinguish(math.max(0, life) + 1)
                    target:LifeThink()
                    wetSamples[target] = nil
                    return true
                end
                if not previous or now < previous or now > previous + 0.8 then
                    wetSamples[target] = now
                end
            else
                wetSamples[target] = nil
            end
        end
        target:SoftExtinguish(dose)
        return true
    end
}

local api = prior and prior.Version == 1 and prior or {}
api.Version = 1
api._registry = registry
api._owners = owners
api.RegisterPreset = registerPreset
-- Only the owner holding its opaque registration token may remove a profile.
-- An addon can unregister and re-register on refresh without deleting another
-- provider's profile. The built-in water profile cannot be unregistered.
api.UnregisterPreset = function(id, token)
    if id == "water" or not identifier(id) or token == nil
        or not registry[id] or owners[id] ~= token then return false end
    registry[id], owners[id] = nil, nil
    return true
end
api.ApplyExposure = function(id, target, dose, context)
    if not identifier(id) or not registry[id] then return false, "unknown_preset" end
    if type(dose) ~= "number" or dose ~= dose or dose <= 0 or dose > MAX_DOSE then
        return false, "invalid_dose"
    end
    if context ~= nil and not istable(context) then return false, "invalid_context" end
    if not IsValid(target) or not isfunction(target.GetClass) then return false, "invalid_target" end
    local ok, class = pcall(target.GetClass, target)
    if not ok or not identifier(class) then return false, "invalid_target" end
    local response = registry[id][class]
    if not response then return false, "unsupported_target" end
    local called, result, reason = pcall(response, target, dose, context)
    if not called then return false, "response_error" end
    if result == false then return false, reason or "response_declined" end
    return true
end

-- Built-in detectors share a per-target/preset cadence, so overlapping sources
-- cannot accidentally apply the same water response several times per tick.
-- Third-party API-1 ApplyExposure remains unchanged.
local managed = prior and istable(prior._managedExposure) and prior._managedExposure
    or setmetatable({}, {__mode = "k"})
api._managedExposure = managed
api.ApplyManagedExposure = function(id, target, dose, context)
    if not IsValid(target) then return false, "invalid_target" end
    local now, perTarget = CurTime(), managed[target]
    local previous = perTarget and perTarget[id]
    if previous and now >= previous and now - previous < 0.25 then return false, "cooldown" end
    local ok, reason = api.ApplyExposure(id, target, dose, context)
    if ok then
        perTarget = perTarget or {}
        managed[target] = perTarget
        perTarget[id] = now
    end
    return ok, reason
end
DashReality.FluidReactions = api
