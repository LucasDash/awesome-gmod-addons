-- Identity certificate and profile controls; server remains authoritative.
local D = DashReality
local function canAdjust()
    if game.SinglePlayer() then return true end
    local ply = LocalPlayer()
    return IsValid(ply) and (ply:IsSuperAdmin() or (ply.IsListenServerHost and ply:IsListenServerHost())) or false
end
function D.BuildIdentitySettings(panel)
    local heading = panel:Help("Identity Certificate")
    heading:SetFont("DermaDefaultBold")
    panel:ControlHelp("Choose an identity for yourself or another actor. Selecting this page equips the Tool Gun.")
    local choices = panel:ComboBox("Identity", "rt_identity_profile")
    for _, profile in ipairs(D.IdentityProfiles or {}) do choices:AddChoice(profile.label, profile.id) end
    panel:CheckBox("Recognize matching factions", "rt_identity_recognition")
    panel:ControlHelp("Applies to both the button and the Tool Gun. Native NPCs of the same faction treat the actor as friendly; scripted NPCs may use separate rules.")
    panel:ControlHelp("Left click an actor to apply the selected identity; right click applies it to you. Reload clears the aimed actor's identity or yours when aiming at the world.")
    panel:ControlHelp("NPC certificates affect recognition only; they do not change the NPC's model or attributes.")
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
    local details = panel:Help("")
    details.Think = function(self)
        if (self.nextRefresh or 0) > RealTime() then return end
        self.nextRefresh = RealTime() + 0.25
        local selection = GetConVar("rt_identity_profile")
        local id = selection and selection:GetString() or "citizen"
        for _, profile in ipairs(D.IdentityProfiles or {}) do
            if profile.id == id then
                local text = string.format("%s: walk %d, run %d, slow walk %d, jump %d, maximum health %d.",
                    profile.label, profile.walk, profile.run, profile.slow, profile.jump, profile.health)
                if self:GetText() ~= text then self:SetText(text) self:InvalidateLayout(true) end
                break
            end
        end
    end
    local apply = panel:Button("Apply selected identity to myself")
    apply.DoClick = function()
        local selected, recognition = GetConVar("rt_identity_profile"), GetConVar("rt_identity_recognition")
        RunConsoleCommand("dash_identity", selected and selected:GetString() or "citizen", recognition and recognition:GetBool() and "1" or "0")
    end
    apply.Think = function(self) self:SetEnabled(canAdjust() and IsValid(LocalPlayer()) and LocalPlayer():Alive()) end
    local clear = panel:Button("Restore previous identity settings", "dash_identity", "clear")
    clear.Think = function(self) self:SetEnabled(canAdjust()) end
    panel:Help("Applying or restoring preserves your current health percentage. Profiles clear on death. Player class and physics mass are unchanged.")
end
