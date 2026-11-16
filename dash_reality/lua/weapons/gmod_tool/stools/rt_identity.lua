TOOL.Tab = "DashReality"
TOOL.Category = "Player"
TOOL.Name = "#tool.rt_identity.name"
TOOL.ClientConVar["profile"] = "citizen"
TOOL.ClientConVar["recognition"] = "1"
TOOL.Information = {{name = "left"}, {name = "right"}, {name = "reload"}}

if CLIENT then
    language.Add("tool.rt_identity.name", "Identity Certificate")
    language.Add("tool.rt_identity.desc", "Apply an identity to a player or native NPC.")
    language.Add("tool.rt_identity.left", "Apply the selected identity to the aimed actor")
    language.Add("tool.rt_identity.right", "Apply the selected identity to yourself")
    language.Add("tool.rt_identity.reload", "Clear the aimed actor's identity, or your own")
end

local function apply(tool, trace, action)
    if CLIENT then return true end
    local owner = tool:GetOwner()
    local d = DashReality
    if not d or not d.CanManageIdentity or not d.CanManageIdentity(owner) then return false end
    local target = action == "self" and owner or trace and trace.Entity
    if action == "clear" and (not IsValid(target) or target:IsWorld()) then target = owner end
    if not IsValid(target) then return false end
    if target ~= owner then
        local hit = trace and trace.HitPos
        if not isvector(hit) or hit.x ~= hit.x or hit.y ~= hit.y or hit.z ~= hit.z
            or hit:DistToSqr(owner:GetShootPos()) > 1024 * 1024 then return false end
    end
    if target:GetClass() == "rt_time_carrier" then
        if not isfunction(d.ResolveTarget) then return false end
        local original, frozen = d.ResolveTarget(target)
        if not frozen or not IsValid(original) then return false end
        local originalTrace = table.Copy(trace)
        originalTrace.Entity = original
        local button = action == "clear" and 3 or 1
        local ok, allowed = pcall(gamemode.Call, "CanTool", owner, originalTrace, "rt_identity", tool, button)
        if not ok or allowed ~= true then return false end
        target = original
    end
    local ok, reason
    if action == "clear" then
        ok, reason = d.ClearActorIdentity(owner, target)
    else
        ok, reason = d.ApplyActorIdentity(owner, target, tool:GetClientInfo("profile"), tool:GetClientNumber("recognition", 1) ~= 0)
    end
    owner:ChatPrint(ok and (action == "clear" and "Identity cleared." or "Identity applied.")
        or (reason or "No identity was changed."))
    return ok == true
end

function TOOL:LeftClick(trace) return apply(self, trace, "target") end
function TOOL:RightClick(trace) return apply(self, trace, "self") end
function TOOL:Reload(trace) return apply(self, trace, "clear") end

function TOOL.BuildCPanel(panel)
    panel:Help("Left click an NPC or player; right click applies the selected identity to yourself. Reload clears the aimed identity or yours when aiming at the world.")
    local profiles = panel:ComboBox("Identity", "rt_identity_profile")
    for _, profile in ipairs(DashReality.IdentityProfiles or {}) do profiles:AddChoice(profile.label, profile.id) end
    panel:CheckBox("Recognize matching factions", "rt_identity_recognition")
    panel:ControlHelp("For NPCs, the tool changes faction recognition only; models, health and native class stay the same. Only native NPCs are supported. Host or superadmin permission is required.")
end
