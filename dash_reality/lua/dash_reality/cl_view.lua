-- Composable first-person view pipeline (client).
-- Several features want to adjust the camera, but the first CalcView hook that returns a table wins.
-- Features register a modifier here instead; one CalcView hook runs them in priority order on a shared
-- view table. This gives the same stacking the standalone Extended Calcview addon offers without
-- replacing hook.Call. If that addon is mounted its CalcViewEx hooks still run, because they wrap the
-- hook.Call that invokes this hook.

local RT = DashReality

RT.View = RT.View or {modifiers = {}, sorted = {}}
local View = RT.View

local function resort()
    local list = {}
    for _, mod in pairs(View.modifiers) do list[#list + 1] = mod end
    table.sort(list, function(a, b)
        if a.priority == b.priority then return a.id < b.id end
        return a.priority < b.priority
    end)
    View.sorted = list
end

-- fn(ply, view) edits view.origin/angles/fov/znear/zfar/drawviewer in place and returns true when it
-- changed the camera. Returning "stop" additionally prevents lower-priority modifiers from running.
function RT.AddViewModifier(id, priority, fn)
    if not isstring(id) or not isfunction(fn) then return false end
    View.modifiers[id] = {id = id, priority = tonumber(priority) or 100, fn = fn}
    resort()
    return true
end

function RT.RemoveViewModifier(id)
    View.modifiers[id] = nil
    resort()
end

hook.Add("CalcView", "DashReality.View", function(ply, origin, angles, fov, znear, zfar)
    if #View.sorted == 0 then return end

    local view = {origin = origin, angles = angles, fov = fov, znear = znear, zfar = zfar}
    local changed = false
    for _, mod in ipairs(View.sorted) do
        local ok, result = pcall(mod.fn, ply, view)
        if not ok then
            ErrorNoHalt("[DashReality] view modifier '", mod.id, "' failed: ", result, "\n")
        elseif result then
            changed = true
            if result == "stop" then break end
        end
    end

    if changed then return view end
end)
