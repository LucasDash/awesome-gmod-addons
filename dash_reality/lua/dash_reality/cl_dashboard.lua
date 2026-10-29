local RT = DashReality

timer.Remove("RealityTools.FrozenScan")
hook.Remove("PreDrawHalos", "RealityTools.FrozenHalo")

local cvHalo = CreateClientConVar("rt_freeze_halo", "1", true, false, "Outline time-frozen NPCs.")
local HALO_COLOR = Color(90, 200, 255)
local frozenList = {}

local function scanFrozen()
    frozenList = {}
    if not cvHalo:GetBool() then return end
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:GetNW2Bool("RT_TimeFrozen") then frozenList[#frozenList + 1] = ent end
    end
end

-- Disabled halos have no polling timer or entity scans. Replace our callback
-- and timer on refresh so an older closure cannot retain its frozen list.
local function updateHaloEnabled()
    timer.Remove("DashReality.FrozenScan")
    frozenList = {}
    if not cvHalo:GetBool() then return end
    scanFrozen()
    timer.Create("DashReality.FrozenScan", 0.5, 0, scanFrozen)
end
cvars.RemoveChangeCallback("rt_freeze_halo", "DashReality.FrozenHalo")
cvars.AddChangeCallback("rt_freeze_halo", updateHaloEnabled, "DashReality.FrozenHalo")
updateHaloEnabled()

hook.Add("PreDrawHalos", "DashReality.FrozenHalo", function()
    if not cvHalo:GetBool() or #frozenList == 0 then return end
    -- Do not draw deleted or newly thawed entities while awaiting the next scan.
    for index = #frozenList, 1, -1 do
        local ent = frozenList[index]
        if not IsValid(ent) or not ent:GetNW2Bool("RT_TimeFrozen") then table.remove(frozenList, index) end
    end
    if #frozenList == 0 then return end
    halo.Add(frozenList, HALO_COLOR, 2, 2, 2, true, true)
end)

-- The server remains authoritative. Disabled controls also resync after a
-- denied change, so a client cannot mistake a local edit for a server setting.
local function canAdjust()
    if game.SinglePlayer() then return true end
    local ply = LocalPlayer()
    return IsValid(ply) and (ply:IsSuperAdmin() or (ply.IsListenServerHost and ply:IsListenServerHost())) or false
end

local function serverCheckbox(panel, def)
    local cv = GetConVar(def.name)
    local box = panel:CheckBox(def.label)
    local initial = cv and cv:GetBool() or false
    box:SetChecked(initial)
    box.OnChange = function(self, value)
        if self.syncing or not canAdjust() or not cv then return end
        self.pendingUntil = RealTime() + 0.7
        RunConsoleCommand("rt_setting", def.name, value and "1" or "0")
    end
    box.Think = function(self)
        if (self.nextRefresh or 0) > RealTime() then return end
        self.nextRefresh = RealTime() + 0.25
        local allowed = cv ~= nil and canAdjust()
        self:SetEnabled(allowed)
        self.Button:SetEnabled(allowed)
        self.Label:SetMouseInputEnabled(allowed)
        if cv and RealTime() >= (self.pendingUntil or 0) and self:GetChecked() ~= cv:GetBool() then
            self.syncing = true
            self:SetChecked(cv:GetBool())
            self.syncing = false
        end
    end
    return box
end

local function serverSlider(panel, label, cvarName, min, max, decimals, command, key)
    local cv = GetConVar(cvarName)
    local slider = panel:NumSlider(label, nil, min, max, decimals)
    if cv then slider:SetValue(cv:GetFloat()) end
    slider.OnValueChanged = function(self, value)
        if self.syncing or not canAdjust() or not cv then return end
        self.pendingUntil = RealTime() + 0.7
        local requested = tonumber(value)
        if not requested then return end
        timer.Create("DashReality.Dashboard.Set." .. key, 0.25, 1, function()
            RunConsoleCommand(command, key, tostring(requested))
        end)
    end
    slider.Think = function(self)
        if (self.nextRefresh or 0) > RealTime() then return end
        self.nextRefresh = RealTime() + 0.25
        local allowed = cv ~= nil and canAdjust()
        self:SetEnabled(allowed)
        self.Slider:SetEnabled(allowed)
        self.Scratch:SetEnabled(allowed)
        self.TextArea:SetEnabled(allowed)
        if cv and not self:IsEditing() and RealTime() >= (self.pendingUntil or 0) then
            local actual = math.Clamp(cv:GetFloat(), min, max)
            if math.abs(self:GetValue() - actual) > 0.0001 then
                self.syncing = true
                self:SetValue(actual)
                self.syncing = false
            end
        end
    end
    return slider
end

local function heading(panel, title, detail)
    local label = panel:Help(title)
    if IsValid(label) then label:SetFont("DermaDefaultBold") end
    if detail then panel:ControlHelp(detail) end
end

local function settingGroup(panel, ghost)
    panel:ControlHelp("Server settings: host or superadmin.")
    for _, item in ipairs(RT.SettingList) do
        local isGhost = string.StartWith(item.name, "noclip_ghost_")
        if isGhost == ghost and item.group ~= "Physics" and item.group ~= "Player" then
            local def = item
            if def.type == "bool" then
                serverCheckbox(panel, def)
            else
                serverSlider(panel, def.label, def.name, def.min, def.max, 1, "rt_setting", def.name)
            end
            if def.help then panel:ControlHelp(def.help) end
        end
    end
end

-- The existing freeze tool panel continues to use this builder.
function RT.BuildSettings(panel)
    heading(panel, "Entity behavior", "Configure freezing, ragdolls and Physgun undo.")
    settingGroup(panel, false)
    panel:CheckBox("Outline frozen NPCs (this client)", "rt_freeze_halo")
end

function RT.BuildFreezeSettings(panel)
    heading(panel, "Freeze Entity", "Freeze NPCs, physics props and ragdolls with the Tool Gun.")
    for _, def in ipairs(RT.SettingList) do
        if def.name == "rt_freeze_rewind" or def.name == "rt_freeze_nextbots" then serverCheckbox(panel, def) end
    end
    panel:CheckBox("Outline frozen entities (this client)", "rt_freeze_halo")
end

function RT.BuildGhostSettings(panel)
    heading(panel, "Ghost Mode", "Choose how your player behaves while noclipping.")
    settingGroup(panel, true)
    panel:Button("Toggle my Ghost Mode", "noclip_ghost")
    panel:Help("Toggle your own player independently of the server settings above.")
end

local function generalControl(panel, def)
        if def.realm == "server" and def.type == "bool" then
            local box = panel:CheckBox(def.label)
            local key = "DashReality.Environment." .. def.id
            box:SetChecked(GetGlobalInt(key, -1) == 1)
            box.OnChange = function(self, value)
                if self.syncing or not canAdjust() or GetGlobalInt(key, -1) < 0 then return end
                self.pendingUntil = RealTime() + 0.7
                RunConsoleCommand("rt_environment", def.id, value and "1" or "0")
            end
            box.Think = function(self)
                if (self.nextRefresh or 0) > RealTime() then return end
                self.nextRefresh = RealTime() + 0.25
                local value = GetGlobalInt(key, -1)
                local allowed = canAdjust() and value >= 0
                self:SetEnabled(allowed)
                self.Button:SetEnabled(allowed)
                self.Label:SetMouseInputEnabled(allowed)
                if RealTime() >= (self.pendingUntil or 0) and self:GetChecked() ~= (value == 1) then
                    self.syncing = true
                    self:SetChecked(value == 1)
                    self.syncing = false
                end
            end
        elseif def.realm == "server" then
            serverSlider(panel, def.label, def.convar, def.min, def.max, def.decimals, "rt_environment", def.id)
        else
            panel:NumSlider(def.label, def.convar, def.min, def.max, def.decimals)
        end
        if def.help then panel:ControlHelp(def.help) end
end

function RT.BuildGeneralSettings(panel)
    heading(panel, "Environment", "World settings apply to the whole session and require the host or a superadmin.")
    for _, def in ipairs(RT.GeneralSettings or {}) do
        if def.realm == "server" and def.id ~= "ai_disabled" and def.id ~= "ai_ignoreplayers" then
            generalControl(panel, def)
        end
    end
end

function RT.BuildSessionProfiles(panel)
    heading(panel, "Session profiles", "Save or restore a named set of server settings.")
    if RT.BuildProfileSettings then RT.BuildProfileSettings(panel, canAdjust) end
end

-- Retain the prior public builder API while placing sections in a tool-menu
-- tab alongside Tools and Utilities. The native stool supplies Freeze NPCs.
function RT.BuildToolgunSettings(panel)
    heading(panel, "Universal Tool Gun", "Server settings require the host or a superadmin.")
    for _, item in ipairs(RT.ToolgunSettings or {}) do
        local def = item
        local key = "DashReality.Toolgun." .. def.id
        local box = panel:CheckBox(def.label)
        box:SetChecked(GetGlobal2Bool(key, false))
        box.OnChange = function(self, value)
            if self.syncing or not canAdjust() or not GetGlobal2Bool("DashReality.Toolgun.Ready", false) then return end
            self.pendingUntil = RealTime() + 0.7
            RunConsoleCommand("dash_toolgun_setting", def.id, value and "1" or "0")
        end
        box.Think = function(self)
            if (self.nextRefresh or 0) > RealTime() then return end
            self.nextRefresh = RealTime() + 0.25
            local allowed = canAdjust() and GetGlobal2Bool("DashReality.Toolgun.Ready", false)
            self:SetEnabled(allowed) self.Button:SetEnabled(allowed) self.Label:SetMouseInputEnabled(allowed)
            local actual = GetGlobal2Bool(key, false)
            if RealTime() >= (self.pendingUntil or 0) and self:GetChecked() ~= actual then
                self.syncing = true
                self:SetChecked(actual)
                self.syncing = false
            end
        end
    end
    heading(panel, "NPC Tool Gun action", "Use NPC Properties and press Reload while aiming at a nearby native NPC you created to toggle Freeze Entity. This requires the host or a superadmin. Equip the NPC separately.")
    panel:ControlHelp("Clearing the action restores the NPC's normal Tool Gun behavior, which may be Remover.")
end

function RT.BuildPhysicsSettings(panel)
    heading(panel, "Interaction physics", "Adjust NPC weight and forces used by ropes, balloons and props.")
    for _, def in ipairs(RT.SettingList) do
        if def.group == "Physics" then
            serverSlider(panel, def.label, def.name, def.min, def.max, 2, "rt_setting", def.name)
            if def.help then panel:ControlHelp(def.help) end
        end
    end
end

function RT.BuildPlayerSettings(panel)
    heading(panel, "Appearance and view", "These settings apply only to your client.")
    heading(panel, "First-person legs")
    panel:CheckBox("Show first-person legs", "rt_legs_mode")
    panel:NumSlider("Distance behind the camera", "rt_legs_offset", 0, 45, 0)
    panel:CheckBox("Hide body while noclipping", "rt_legs_hide_noclip")
    panel:CheckBox("Show body in vehicles", "rt_legs_vehicle")
    panel:ControlHelp("Optional legs only; first-person weapon hands remain under the weapon's control.")

    heading(panel, "View and HUD")
    for _, def in ipairs(RT.GeneralSettings or {}) do
        if def.realm == "client" then generalControl(panel, def) end
    end
end

function RT.BuildDeathSettings(panel)
    heading(panel, "Death perception", "Adjust visual and audio effects after death.")
    panel:CheckBox("Enable death perception", "rt_dp_enable")
    panel:NumSlider("Seconds until senses cut off", "rt_dp_delay", 0, 3, 2)
    panel:CheckBox("See death through the ragdoll's eyes", "rt_dp_pov")
    panel:CheckBox("Blur vision while dying", "rt_dp_blur")
    panel:CheckBox("Silence sound after the cutoff", "rt_dp_hearing")
    local color = panel:ComboBox("Colour change", "rt_dp_colormode")
    for i, name in ipairs({"None", "Black and white", "High contrast", "Red"}) do color:AddChoice(name, tostring(i - 1)) end
    local cvColor = GetConVar("rt_dp_colormode")
    if cvColor then color:SetValue(color:GetOptionText(math.Clamp(cvColor:GetInt() + 1, 1, 4))) end
    local cutoff = panel:ComboBox("Vision cutoff", "rt_dp_cutoff")
    for i, name in ipairs({"Keep vision", "Instant black", "Fade to black"}) do cutoff:AddChoice(name, tostring(i - 1)) end
    local cvCutoff = GetConVar("rt_dp_cutoff")
    if cvCutoff then cutoff:SetValue(cutoff:GetOptionText(math.Clamp(cvCutoff:GetInt() + 1, 1, 3))) end

    for _, def in ipairs(RT.SettingList) do
        if def.name == "rt_player_dp_noearring" then
            serverCheckbox(panel, def)
            if def.help then panel:ControlHelp(def.help) end
        end
    end
end

function RT.BuildWeaponSettings(panel)
    heading(panel, "Weapon drops", "Server settings require the host or a superadmin.")
    for _, def in ipairs(RT.SettingList) do
        if def.group == "Player" and string.StartWith(def.name, "rt_player_dropweapon_") then
            serverCheckbox(panel, def)
            if def.help then panel:ControlHelp(def.help) end
        end
    end
    panel:Button("Drop my weapon", "dash_dropweapon")
    panel:ControlHelp("Bind a key with: bind g +drop")
end

function RT.BuildNPCSettings(panel)
    heading(panel, "NPC behavior", "Native AI settings require the host or a superadmin.")
    for _, def in ipairs(RT.GeneralSettings or {}) do
        if def.id == "ai_disabled" or def.id == "ai_ignoreplayers" then generalControl(panel, def) end
    end
    heading(panel, "NPC properties", "Use NPC Properties in this category to change health or proficiency, or Reload to toggle an NPC's Tool Gun action.")
    panel:ControlHelp("Some scripted NPCs and weapons use their own combat rules.")
end

function RT.BuildDevelopmentSettings(panel)
    heading(panel, "Entity Inspector", "Select Entity Inspector in this category, then aim the Tool Gun at an entity.")
    panel:ControlHelp("Left click prints a server report; right click prints a client report in the developer console. Server reports require the host or a superadmin.")
    heading(panel, "Performance recording", "Optional Mod Workbench integration records ten seconds of client frame delivery. It does not measure GPU time or identify a cause.")
    local statusLabel = panel:Help("Checking Workbench recorder...")
    local start = panel:Button("Record frame delivery")
    local stop = panel:Button("Stop my recording")
    local nextCheck, current = 0, {available = false}
    local function state()
        if RealTime() >= nextCheck then
            nextCheck = RealTime() + 1
            current = RT.WorkbenchBridge and RT.WorkbenchBridge.Status() or {available = false}
        end
        return current
    end
    local function message(text)
        if IsValid(LocalPlayer()) then LocalPlayer():ChatPrint("[Dash Reality] " .. text) end
        nextCheck = 0
    end
    start.DoClick = function()
        if not RT.WorkbenchBridge then return message("Workbench integration is unavailable.") end
        local ok, result = RT.WorkbenchBridge.Start()
        message(ok and ("Performance recording started: " .. result) or result)
    end
    stop.DoClick = function()
        if not RT.WorkbenchBridge then return message("Workbench integration is unavailable.") end
        local ok, result = RT.WorkbenchBridge.Stop()
        message(ok and ("Performance recording stopped: " .. tostring(result)) or result)
    end
    start.Think = function(self) local s = state() self:SetEnabled(s.available and not s.active) end
    stop.Think = function(self) local s = state() self:SetEnabled(s.available and s.owned == true) end
    statusLabel.Think = function(self)
        local s = state()
        local text
        if not s.available then text = "Workbench performance recorder is not available."
        elseif s.active then text = s.owned and "Recording started by Dash Reality." or "A Workbench recording is already active."
        elseif s.path and s.saved == false then text = "Report failed: " .. (s.error or "could not save the report.")
        elseif s.path and s.saved then text = "Last report: " .. s.path
        else text = "Workbench performance recorder is ready." end
        if self:GetText() ~= text then self:SetText(text) self:InvalidateLayout(true) end
    end
end

RT.DashboardSections = RT.DashboardSections or {}
function RT.RegisterDashboardSection(id, title, build, icon, order, category)
    if not isstring(id) or id == "" or not isstring(title) or not isfunction(build) then return false end
    RT.DashboardSections[id] = {id=id, title=title, build=build, icon=icon, order=tonumber(order) or 100, category=category}
    return true
end
RT.RegisterDashboardSection("general", "Environment", RT.BuildGeneralSettings, "icon16/cog.png", 10, "Session")
RT.RegisterDashboardSection("profiles", "Session Profiles", RT.BuildSessionProfiles, "icon16/disk.png", 11, "Session")
RT.RegisterDashboardSection("player", "Appearance and View", RT.BuildPlayerSettings, "icon16/user.png", 20, "Player")
RT.RegisterDashboardSection("identity", "Identity Certificate", RT.BuildIdentitySettings, "icon16/user.png", 21, "Player")
RT.RegisterDashboardSection("ghost", "Ghost Mode", RT.BuildGhostSettings, "icon16/user_gray.png", 22, "Player")
RT.RegisterDashboardSection("weapons", "Weapon Drops", RT.BuildWeaponSettings, "icon16/gun.png", 23, "Player")
RT.RegisterDashboardSection("death", "Death Perception", RT.BuildDeathSettings, "icon16/heart.png", 24, "Player")
RT.RegisterDashboardSection("npc", "NPC Behavior", RT.BuildNPCSettings, "icon16/group.png", 30, "NPC")
RT.RegisterDashboardSection("reality", "Entity Behavior", RT.BuildSettings, "icon16/wrench.png", 40, "Entities")
RT.RegisterDashboardSection("physics", "Interaction Physics", RT.BuildPhysicsSettings, "icon16/weight.png", 50, "Physics")
RT.RegisterDashboardSection("toolgun", "Tool Gun Settings", RT.BuildToolgunSettings, "icon16/gun.png", 60, "Universal Tool Gun")
RT.RegisterDashboardSection("development", "Development Settings", RT.BuildDevelopmentSettings, "icon16/bug.png", 70, "Development")

-- Remove the old left-side creation-tab registration from prior live builds.
if spawnmenu.GetCreationTabs then spawnmenu.GetCreationTabs()["Dash Reality"] = nil end
hook.Remove("PopulateToolMenu", "RealityTools.SettingsPage")
hook.Add("AddToolMenuTabs", "DashReality.Tab", function()
    spawnmenu.AddToolTab("DashReality", "Dash Reality", "icon16/world.png")
end)
hook.Add("AddToolMenuCategories", "DashReality.Categories", function()
    for _, name in ipairs({"Session", "Player", "NPC", "Entities", "Physics", "Universal Tool Gun", "Development"}) do
        spawnmenu.AddToolCategory("DashReality", name, name)
    end
end)
hook.Add("PopulateToolMenu", "DashReality.Sections", function()
    hook.Run("DashRealityRegisterSections", RT)
    local sections = {}
    for _, section in pairs(RT.DashboardSections) do sections[#sections + 1] = section end
    table.sort(sections, function(a,b) if a.order == b.order then return a.id < b.id end return a.order < b.order end)
    for _, section in ipairs(sections) do
        local category = section.category or section.title
        spawnmenu.AddToolCategory("DashReality", category, category)
        spawnmenu.AddToolMenuOption("DashReality", category, "dash_reality_"..section.id,
            section.title, "", "", section.build)
    end
end)
