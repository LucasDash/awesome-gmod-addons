-- Client-side favorites for the stock Tool Gun selection mechanism.
local RT = DashReality
local PATH = "dash_reality/tool_shortcuts.json"
local enabled = CreateClientConVar("rt_tool_shortcuts_enabled", "0", true, false,
    "Use the mouse wheel to cycle selected Tool Gun modes.")
local wheelUp, wheelDown = input.GetKeyCode("MWHEELUP"), input.GetKeyCode("MWHEELDOWN")
local previousKey = CreateClientConVar("rt_tool_shortcuts_previous", tostring(wheelUp), true, false,
    "Button code for the previous Tool Gun shortcut.")
local nextKey = CreateClientConVar("rt_tool_shortcuts_next", tostring(wheelDown), true, false,
    "Button code for the next Tool Gun shortcut.")
-- Existing menu controls can outlive a Lua refresh. Share their selection with
-- the new input hook so they never write into a disconnected old list.
local state = RT.ToolShortcutsState
local initial = not istable(state) or not istable(state.chosen) or not istable(state.lookup)
if initial then
    state = {chosen = {}, lookup = {}}
    RT.ToolShortcutsState = state
end
local chosen, lookup = state.chosen, state.lookup
local pending, pendingUntil

local function validMode(mode)
    return isstring(mode) and mode ~= "" and mode:match("^[%w_%-]+$") ~= nil
end

local function add(mode)
    if validMode(mode) and not lookup[mode] then
        chosen[#chosen + 1] = mode
        lookup[mode] = true
    end
end

local raw = initial and file.Read(PATH, "DATA") or nil
if raw then
    local ok, saved = pcall(util.JSONToTable, raw)
    if ok and istable(saved) then
        for _, mode in ipairs(saved) do add(mode) end
    end
end

local function selectMode(mode, selected)
    if not validMode(mode) then return end
    if selected then
        add(mode)
    elseif lookup[mode] then
        lookup[mode] = nil
        for i, value in ipairs(chosen) do
            if value == mode then table.remove(chosen, i) break end
        end
    end
    file.CreateDir("dash_reality")
    file.Write(PATH, util.TableToJSON(chosen, true))
end

local function catalog()
    local stored = weapons.GetStored("gmod_tool")
    local registered = stored and stored.Tool
    if not istable(registered) or not isfunction(spawnmenu.GetTools) then return {} end
    local result, seen = {}, {}
    for _, tab in ipairs(spawnmenu.GetTools() or {}) do
        for _, category in ipairs(tab.Items or {}) do
            for _, item in ipairs(category) do
                local mode = item.ItemName
                if validMode(mode) and registered[mode] and not seen[mode] then
                    local label = isstring(item.Text) and item.Text or mode
                    if label:sub(1, 1) == "#" then label = language.GetPhrase(label:sub(2)) end
                    result[#result + 1] = {mode = mode, label = label, category = category.Text or tab.Name or ""}
                    seen[mode] = true
                end
            end
        end
    end
    table.sort(result, function(a, b)
        local x, y = a.label:lower(), b.label:lower()
        return x == y and a.mode < b.mode or x < y
    end)
    return result
end

local function buildPanel(panel)
    panel:Help("Tool shortcuts (this client)")
    panel:CheckBox("Cycle selected tools", "rt_tool_shortcuts_enabled")
    local function addBinding(label, convar, setting)
        local caption = vgui.Create("DLabel", panel)
        caption:SetText(label); caption:SetDark(true)
        local binder = vgui.Create("DBinder", panel)
        binder:SetValue(setting:GetInt())
        binder:SetConVar(convar)
        panel:AddItem(caption, binder)
    end
    addBinding("Previous tool", "rt_tool_shortcuts_previous", previousKey)
    addBinding("Next tool", "rt_tool_shortcuts_next", nextKey)
    panel:ControlHelp("Choose at least two tools and different buttons. Right-click a binding to restore its default. Existing game actions may also run for some buttons.")
    local scroll = vgui.Create("DScrollPanel", panel)
    scroll:SetTall(220)
    panel:AddItem(scroll)
    local tools = catalog()
    if #tools == 0 then
        local label = vgui.Create("DLabel", scroll)
        scroll:AddItem(label)
        label:Dock(TOP)
        label:SetText("No Tool Gun modes are available yet. Reopen this page after tools load.")
        label:SetWrap(true)
        label:SetAutoStretchVertical(true)
        return
    end
    for _, entry in ipairs(tools) do
        local box = vgui.Create("DCheckBoxLabel", scroll)
        scroll:AddItem(box)
        box:Dock(TOP)
        box:DockMargin(4, 2, 4, 2)
        box:SetText(entry.label .. " (" .. entry.mode .. ")")
        box:SetValue(lookup[entry.mode] and 1 or 0)
        box:SizeToContents()
        box.OnChange = function(_, value) selectMode(entry.mode, value) end
    end
end

local function directionFor(code)
    if not isnumber(code) or code <= 0 then return end
    local previous, nextButton = previousKey:GetInt(), nextKey:GetInt()
    if previous == nextButton then return end
    if code == previous then return -1 end
    if code == nextButton then return 1 end
end

local function cycle(ply, direction)
    if not direction or not enabled:GetBool() or ply ~= LocalPlayer() or vgui.CursorVisible()
        or gui.IsGameUIVisible() or input.IsKeyTrapping() then return end
    local weapon = IsValid(ply) and ply:GetActiveWeapon()
    if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" then return end
    local stored = weapons.GetStored("gmod_tool")
    local registered = stored and stored.Tool
    if not istable(registered) then return end
    local available = {}
    for _, mode in ipairs(chosen) do
        if registered[mode] then available[#available + 1] = mode end
    end
    if #available < 2 then return end
    local mode = pending and RealTime() < pendingUntil and pending or weapon:GetMode()
    local index
    for i, value in ipairs(available) do if value == mode then index = i break end end
    if not index then index = direction > 0 and 0 or 1 end
    local target = available[(index - 1 + direction) % #available + 1]
    if not isfunction(spawnmenu.ActivateTool) then return end
    local ok = pcall(spawnmenu.ActivateTool, target, false)
    if not ok then return end
    pending, pendingUntil = target, RealTime() + 0.5
    return true
end

local lastFunctionFrame = -1
local function onBind(ply, bind, pressed, code)
    if not pressed then return end
    local changed = cycle(ply, directionFor(code))
    if changed and code >= KEY_F1 and code <= KEY_F12 then lastFunctionFrame = FrameNumber() end
    return changed
end

-- Function keys are not consistently delivered to PlayerBindPress. Poll only
-- configured F-keys here; ordinary keys and wheel remain bind-hook events.
local function onMove()
    local frame = FrameNumber()
    if lastFunctionFrame == frame then return end
    local previous, nextButton = previousKey:GetInt(), nextKey:GetInt()
    if previous == nextButton then return end
    if previous >= KEY_F1 and previous <= KEY_F12 and input.WasKeyPressed(previous) then
        if cycle(LocalPlayer(), -1) then lastFunctionFrame = frame end
    elseif nextButton >= KEY_F1 and nextButton <= KEY_F12 and input.WasKeyPressed(nextButton) then
        if cycle(LocalPlayer(), 1) then lastFunctionFrame = frame end
    end
end

local function updateHooks()
    hook.Remove("PlayerBindPress", "DashReality.ToolShortcuts")
    hook.Remove("CreateMove", "DashReality.ToolShortcuts.FunctionKeys")
    if not enabled:GetBool() then return end
    hook.Add("PlayerBindPress", "DashReality.ToolShortcuts", onBind)
    hook.Add("CreateMove", "DashReality.ToolShortcuts.FunctionKeys", onMove)
end
cvars.RemoveChangeCallback("rt_tool_shortcuts_enabled", "DashReality.ToolShortcuts")
cvars.AddChangeCallback("rt_tool_shortcuts_enabled", updateHooks, "DashReality.ToolShortcuts")
updateHooks()

RT.ToolShortcuts = {BuildPanel = buildPanel}
