-- Optional native-water decal washing for networked players, NPCs and ragdolls.
-- Entity decals are cleared together; Source does not expose a blood-only filter.
if not SERVER then return end

local SETTING = "rt_water_decal_wash"
local HOOK = "DashReality.WaterWash"
local TIMER = "DashReality.WaterWash"
local INTERVAL, WASH_INTERVAL, BUDGET = 0.25, 2, 32
local PENDING_BUDGET, PENDING_LIMIT = 64, 2048
local enabled = GetConVar(SETTING) or CreateConVar(SETTING, "0",
    FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
    "Wash all entity decals from players, NPCs and ragdolls in native water.", 0, 1)

-- Remove a prior generation when this module is reloaded.
timer.Remove(TIMER)
hook.Remove("OnEntityCreated", HOOK)
hook.Remove("EntityRemoved", HOOK)
cvars.RemoveChangeCallback(SETTING, HOOK)

local tracked, positions, due = {}, {}, {}
local pending, head, tail, pendingCount = {}, 1, 1, 0
local active, cursor, rescan, rescanAt = false, 1, false, 0

local function isTarget(ent)
    return IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:GetClass() == "prop_ragdoll")
end

local function forget(ent)
    local index = positions[ent]
    if not index then return end
    local last = tracked[#tracked]
    tracked[index] = last
    tracked[#tracked] = nil
    positions[ent], due[ent] = nil, nil
    if last ~= ent then positions[last] = index end
    if cursor > #tracked then cursor = 1 end
end

local function track(ent)
    if not positions[ent] and isTarget(ent) then
        tracked[#tracked + 1] = ent
        positions[ent] = #tracked
    end
end

local function inWater(ent)
    local level = ent:WaterLevel()
    if ent:IsPlayer() then return ent:Alive() and level >= 3 end
    return level >= 2 or bit.band(util.PointContents(ent:WorldSpaceCenter()), CONTENTS_WATER) ~= 0
end

local function tick()
    if not active then return end
    -- Classify after entity initialization without creating one timer per
    -- entity. A bounded-rate recovery scan handles queue overflow, including
    -- sustained churn that prevents the backlog from draining.
    for _ = 1, math.min(pendingCount, PENDING_BUDGET) do
        local ent = pending[head]
        pending[head] = nil
        head = head % PENDING_LIMIT + 1
        pendingCount = pendingCount - 1
        track(ent)
    end
    local now = CurTime()
    if rescan and (pendingCount == 0 or now >= rescanAt) then
        rescan = false
        for _, ent in ipairs(ents.GetAll()) do track(ent) end
    end
    local count = math.min(#tracked, BUDGET)
    for _ = 1, count do
        if #tracked == 0 then break end
        if cursor > #tracked then cursor = 1 end
        local ent = tracked[cursor]
        if not IsValid(ent) then
            forget(ent)
        else
            cursor = cursor + 1
            if inWater(ent) then
                if now >= (due[ent] or 0) then
                    ent:RemoveAllDecals()
                    due[ent] = now + WASH_INTERVAL
                end
            else
                due[ent] = nil
            end
        end
    end
end

local function stop()
    active = false
    timer.Remove(TIMER)
    hook.Remove("OnEntityCreated", HOOK)
    hook.Remove("EntityRemoved", HOOK)
    tracked, positions, due, cursor = {}, {}, {}, 1
    pending, head, tail, pendingCount, rescan, rescanAt = {}, 1, 1, 0, false, 0
end

local function start()
    if active then return end
    active = true
    hook.Add("OnEntityCreated", HOOK, function(ent)
        if not IsValid(ent) then return end
        if pendingCount >= PENDING_LIMIT then
            if not rescan then rescan, rescanAt = true, CurTime() + 2 end
            return
        end
        pending[tail] = ent
        tail = tail % PENDING_LIMIT + 1
        pendingCount = pendingCount + 1
    end)
    hook.Add("EntityRemoved", HOOK, forget)
    for _, ent in ipairs(ents.GetAll()) do track(ent) end -- once per enable
    timer.Create(TIMER, INTERVAL, 0, tick)
end

cvars.AddChangeCallback(SETTING, function(_, _, value)
    if tonumber(value) and tonumber(value) ~= 0 then start() else stop() end
end, HOOK)
if enabled:GetBool() then start() end

DashReality.WaterWash = {
    Status = function() return {enabled = active, tracked = #tracked, budget = BUDGET,
        pending = pendingCount, pendingBudget = PENDING_BUDGET, pendingLimit = PENDING_LIMIT,
        rescan = rescan} end,
}
