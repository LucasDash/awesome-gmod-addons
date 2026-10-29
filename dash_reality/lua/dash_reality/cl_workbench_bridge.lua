-- Optional adapter for an already loaded Mod Workbench performance recorder.
-- Dash Reality does not load, replace or bundle the recorder itself.
local D = DashReality
D.WorkbenchBridge = D.WorkbenchBridge or {counter = 0}
local B = D.WorkbenchBridge

local function provider()
    local p = ModWorkbenchPerformance
    if not istable(p) or p.version ~= 2 or not isfunction(p.Start)
        or not isfunction(p.Stop) or not isfunction(p.Status) then
        return nil, "Load Mod Workbench performance recorder version 2."
    end
    local ok, status = pcall(p.Status)
    if not ok or not istable(status) or not isbool(status.active)
        or (status.active and not isstring(status.path)) then
        return nil, "Workbench recorder status is unavailable."
    end
    return p, status
end

local function safeReason(reason)
    if reason == "completed" or reason == "cancelled" or reason == "frame_limit" then return reason end
    local prefix = "observation_error:"
    if isstring(reason) and string.sub(reason, 1, #prefix) == prefix then return "observation_error" end
    return nil
end

function B.Status()
    local p, status = provider()
    if not p then return {available = false, message = status} end
    local owned = status.active and B.owned and B.owned.provider == p and B.owned.path == status.path or false
    return {available = true, active = status.active, owned = owned,
        path = status.path, saved = status.saved, reason = safeReason(status.reason),
        -- Workbench errors can contain paths or arbitrary values from other
        -- modules. Expose a bounded, local message rather than those details.
        error = status.saved == false and "Workbench could not save the report." or nil}
end

function B.Start()
    local p, status = provider()
    if not p then return false, status end
    if status.active then return false, "A Workbench performance recording is already active." end
    B.owned = nil
    local name
    for _ = 1, 100 do
        B.counter = B.counter + 1
        name = "dash_reality_" .. os.time() .. "_" .. B.counter
        if not file.Exists("mod_workbench/performance/" .. name, "DATA") then break end
        name = nil
    end
    if not name then return false, "Could not select a new report name." end
    local ok, path = pcall(p.Start, {name = name, duration = 10})
    if not ok or not isstring(path) then return false, "Could not start recording: " .. tostring(path) end
    -- Record the start response before asking for status again. If that status
    -- query fails transiently, a later successful query can still identify our
    -- job; Stop always rechecks the current provider, active state and path.
    B.owned = {provider = p, path = path}
    local current, observed = provider()
    if current ~= p or not istable(observed) or not observed.active or observed.path ~= path then
        return false, "Recording started, but its ownership could not be confirmed."
    end
    return true, path
end

function B.Stop()
    local p, status = provider()
    if not p then return false, status end
    if not B.owned or B.owned.provider ~= p or not status.active or B.owned.path ~= status.path then
        return false, "No Dash Reality recording is active."
    end
    local called, stopped, result = pcall(p.Stop, "cancelled")
    if not called or stopped ~= true then return false, "Could not stop recording: " .. tostring(result or stopped) end
    B.owned = nil
    return true, result
end
