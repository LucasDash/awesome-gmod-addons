-- Server-owned session profiles; building the panel does not read or apply one.
local D = DashReality
local boxes = setmetatable({}, {__mode="k"})
net.Receive("DashReality.ProfileList", function()
    local names = {}
    for i=1, net.ReadUInt(8) do names[i] = net.ReadString() end
    for box in pairs(boxes) do
        if IsValid(box) then
            box:Clear()
            for _, name in ipairs(names) do box:AddChoice(name) end
        end
    end
end)
function D.BuildProfileSettings(panel, canAdjust)
    panel:Help("Named server profiles save environment controls and Dash Reality server settings. They do not change local view settings or player identity.")
    local entry = panel:TextEntry("Profile name")
    local list = vgui.Create("DComboBox", panel)
    list:SetValue("Available profiles")
    panel:AddItem(list)
    boxes[list] = true
    list.OnSelect = function(_, _, name) entry:SetText(name) end
    local function request(action, replacement)
        if not canAdjust() then return end
        if action == "list" then return RunConsoleCommand("dash_profile", action) end
        local name = entry:GetValue() or ""
        if #name < 1 or #name > 32 or not string.match(name, "^[%w_-]+$") then
            notification.AddLegacy("Use 1–32 letters, numbers, underscores or hyphens for the profile name.", NOTIFY_ERROR, 4)
            return
        end
        if replacement then RunConsoleCommand("dash_profile", action, name, "replace")
        else RunConsoleCommand("dash_profile", action, name) end
    end
    local refresh = panel:Button("Refresh profile list")
    refresh.DoClick = function() request("list") end
    local create = panel:Button("Save as new profile")
    create.DoClick = function() request("save") end
    local update = panel:Button("Update saved profile")
    update.DoClick = function() request("save", true) end
    local apply = panel:Button("Load profile")
    apply.DoClick = function() request("load") end
    for _, control in ipairs({entry,list,refresh,create,update,apply}) do
        control.Think = function(self) self:SetEnabled(canAdjust()) end
    end
end
