local Matcher = {}
local dimensions = {pose = 25, velocity = 28, trajectory = 15, contacts = 2}
local defaults = {pose = 1, velocity = 0.5, trajectory = 2, contacts = 0.5, switch = 0.15, phase = 0.05}
local preparedStates = setmetatable({}, {__mode = "k"})

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer(value)
    return finite(value) and value >= 0 and value == math.floor(value)
end

local function textValid(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
end

local function denseCount(values, maximum)
    if type(values) ~= "table" then return nil end
    local count, last = 0, 0
    for index in pairs(values) do
        if not integer(index) or index < 1 or index > maximum then return nil end
        count = count + 1
        last = math.max(last, index)
    end
    if count ~= last then return nil end
    return count
end

local function featuresValid(frame)
    if type(frame) ~= "table" then return false end
    for name, size in pairs(dimensions) do
        if denseCount(frame[name], size) ~= size then return false end
        for index = 1, size do
            if not finite(frame[name][index]) then return false end
        end
    end
    return true
end

local function semanticsValid(semantic)
    return type(semantic) == "table" and textValid(semantic.role, 64)
        and textValid(semantic.stance, 64) and textValid(semantic.region, 64)
        and type(semantic.grounded) == "boolean"
        and (semantic.gait == nil or textValid(semantic.gait, 64))
end

local function poolKey(semantic)
    return #semantic.role .. ":" .. semantic.role .. #semantic.stance .. ":" .. semantic.stance
        .. #semantic.region .. ":" .. semantic.region .. tostring(semantic.grounded)
end

local function candidateCopy(frame)
    local semantic = frame.semantic
    return {sequence = frame.sequence, variant = frame.variant, cycle = frame.cycle,
        moveX = frame.moveX, moveY = frame.moveY, duration = frame.duration,
        semantic = {role = semantic.role, stance = semantic.stance, region = semantic.region,
            grounded = semantic.grounded, gait = semantic.gait}}
end

function Matcher.Prepare(database)
    if type(database) ~= "table" or database.schema ~= 1 or not textValid(database.model, 260) then
        return nil, "invalid_database"
    end
    local count = denseCount(database.frames, 16384)
    if not count or count == 0 then return nil, "invalid_database" end
    if database.featureDimensions ~= nil then
        if type(database.featureDimensions) ~= "table" then return nil, "invalid_database" end
        for name, size in pairs(dimensions) do
            if database.featureDimensions[name] ~= size then return nil, "invalid_database" end
        end
    end
    local state = {model = database.model, pools = {}}
    for index = 1, count do
        local frame = database.frames[index]
        if not featuresValid(frame) or not textValid(frame.sequence, 256) or not integer(frame.variant)
            or not finite(frame.cycle) or frame.cycle < 0 or frame.cycle >= 1
            or (frame.eligible ~= nil and type(frame.eligible) ~= "boolean")
            or (frame.moveX ~= nil and not finite(frame.moveX))
            or (frame.moveY ~= nil and not finite(frame.moveY))
            or (frame.duration ~= nil and (not finite(frame.duration) or frame.duration <= 0)) then
            return nil, "invalid_frame"
        end
        local semantic = frame.semantic
        if type(semantic) ~= "table" or not textValid(semantic.role, 64) then
            return nil, "invalid_semantics"
        end
        if semantic.role ~= "unclassified" and frame.eligible ~= false then
            if not semanticsValid(semantic) then return nil, "invalid_semantics" end
            local snapshot = candidateCopy(frame)
            snapshot.frameIndex = index
            for name, size in pairs(dimensions) do
                snapshot[name] = {}
                for feature = 1, size do snapshot[name][feature] = frame[name][feature] end
            end
            local key = poolKey(semantic)
            local pool = state.pools[key] or {}
            state.pools[key] = pool
            pool[#pool + 1] = snapshot
        end
    end
    local handle = {}
    preparedStates[handle] = state
    return handle
end

function Matcher.Search(handle, query)
    local state = type(handle) == "table" and preparedStates[handle]
    if not state then return nil, "invalid_prepared" end
    if not featuresValid(query) or not semanticsValid(query.semantic)
        or query.semantic.role == "unclassified"
        or (query.previousVariant ~= nil and not integer(query.previousVariant))
        or (query.expectedCycle ~= nil and (not finite(query.expectedCycle)
            or query.expectedCycle < 0 or query.expectedCycle >= 1)) then
        return nil, "invalid_query"
    end
    if state.model ~= query.model then return nil, "model_mismatch" end
    if query.weights ~= nil and type(query.weights) ~= "table" then return nil, "invalid_weights" end
    if query.weights then
        for name in pairs(query.weights) do
            if defaults[name] == nil then return nil, "invalid_weights" end
        end
    end
    local weights = {}
    for name, default in pairs(defaults) do
        local value = query.weights and query.weights[name]
        if value == nil then value = default end
        if not finite(value) or value < 0 then return nil, "invalid_weights" end
        weights[name] = value
    end
    local pool = state.pools[poolKey(query.semantic)] or {}
    if #pool > 2048 then return nil, "candidate_budget_exceeded" end
    local best, bestCost, evaluated = nil, math.huge, 0
    for _, frame in ipairs(pool) do
        if not query.semantic.gait or frame.semantic.gait == query.semantic.gait then
            local cost = 0
            for name, size in pairs(dimensions) do
                if weights[name] > 0 then
                    local groupCost = 0
                    for index = 1, size do
                        local difference = frame[name][index] - query[name][index]
                        groupCost = groupCost + difference * difference
                    end
                    cost = cost + weights[name] * groupCost / size
                end
            end
            if query.previousVariant ~= nil and frame.variant ~= query.previousVariant then
                cost = cost + weights.switch
            end
            if query.previousVariant == frame.variant and query.expectedCycle ~= nil then
                local difference = math.abs(frame.cycle - query.expectedCycle)
                difference = math.min(difference, 1 - difference)
                cost = cost + weights.phase * difference * difference
            end
            if not finite(cost) then return nil, "non_finite_cost" end
            evaluated = evaluated + 1
            if cost < bestCost then best, bestCost = frame, cost end
        end
    end
    if not best then return nil, "no_eligible_frames" end
    return candidateCopy(best), {cost = bestCost, evaluated = evaluated, frameIndex = best.frameIndex}
end

return Matcher
