-- Identity certificate and profile controls; server remains authoritative.
local D = DashReality
local factionPreference = CreateClientConVar("rt_identity_faction", "0", true, false, "Let supported native NPCs recognize the chosen identity.")
local function canAdjust()
    if game.SinglePlayer() then return true end
    local ply = LocalPlayer()
    return IsValid(ply) and (ply:IsSuperAdmin() or (ply.IsListenServerHost and ply:IsListenServerHost())) or false
end
function D.BuildIdentitySettings(panel)
    local heading = panel:Help("Identity Certificate")
    heading:SetFont("DermaDefaultBold")
    panel:ControlHelp("Apply a player profile inspired by an NPC. Values are approximate and can be restored.")
    panel:CheckBox("Recognize identity faction", "rt_identity_faction")
    panel:ControlHelp("Applied when choosing a profile. Supported native NPCs of that faction treat you as friendly. Scripted NPCs can use separate relationship rules.")
    panel:ControlHelp("The Identity Tool Gun mode can apply or clear a profile on yourself, another player, or a native NPC.")
    local status = panel:Help("Current identity: none")
    status.Think = function(self)
        if (self.nextRefresh or 0) > RealTime() then return end
        self.nextRefresh = RealTime() + 0.25
        local ply = LocalPlayer()
        local id = IsValid(ply) and ply:GetNW2String("DashReality.Identity", "") or ""
        local name = "none"
        for _, profile in ipairs(D.IdentityProfiles or {}) do if profile.id == id then name = profile.label break end end
        local text = "Current identity: " .. name
        if self:GetText() ~= text then self:SetText(text) self:InvalidateLayout(true) end
    end
    for _, item in ipairs(D.IdentityProfiles or {}) do
        local profile = item
        panel:Help(string.format("%s: walk %d, run %d, slow walk %d, jump %d, maximum health %d.",
            profile.label, profile.walk, profile.run, profile.slow, profile.jump, profile.health))
        local button = panel:Button("Apply " .. profile.label)
        button.DoClick = function() RunConsoleCommand("dash_identity", profile.id, factionPreference:GetBool() and "1" or "0") end
        button.Think = function(self) self:SetEnabled(canAdjust() and IsValid(LocalPlayer()) and LocalPlayer():Alive()) end
    end
    local clear = panel:Button("Restore previous identity settings", "dash_identity", "clear")
    clear.Think = function(self) self:SetEnabled(canAdjust()) end
    panel:Help("Applying or restoring preserves your current health percentage. Profiles clear on death. Player class and physics mass are unchanged.")
end
