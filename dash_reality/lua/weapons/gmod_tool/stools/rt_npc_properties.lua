TOOL.Tab = "DashReality"
TOOL.Category = "NPC"
TOOL.Name = "#tool.rt_npc_properties.name"
TOOL.ClientConVar["health"] = "100"
TOOL.ClientConVar["proficiency"] = "1"
TOOL.Information = {{name = "left"}, {name = "right"}, {name = "reload"}}

if CLIENT then
    language.Add("tool.rt_npc_properties.name", "NPC Properties")
    language.Add("tool.rt_npc_properties.desc", "Adjust an NPC's health, proficiency or Tool Gun action.")
    language.Add("tool.rt_npc_properties.left", "Set current and maximum health")
    language.Add("tool.rt_npc_properties.right", "Set weapon proficiency")
    language.Add("tool.rt_npc_properties.reload", "Toggle Freeze Entity action for an NPC you created")
end

local function subject(trace)
    local ent = trace and trace.Entity
    if not IsValid(ent) then return nil end
    if SERVER and ent:GetClass() == "rt_time_carrier" then
        if not DashReality or not isfunction(DashReality.ResolveTarget) then return nil end
        local resolved, frozen = DashReality.ResolveTarget(ent)
        if not frozen then return nil end
        ent = resolved
    end
    if IsValid(ent) and ent:IsNPC() then return ent end
end

local function apply(tool, trace, action)
    if CLIENT then return IsValid(trace.Entity) end
    local npc = subject(trace)
    local owner = tool:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() or not IsValid(npc) or npc:Health() <= 0 then return false end
    -- Frozen NPCs are reached through a carrier. Check Sandbox permissions on
    -- the original NPC as well as the carrier already checked by the Tool Gun.
    if npc ~= trace.Entity then
        local original = table.Copy(trace)
        original.Entity = npc
        local button = action == "health" and 1 or action == "proficiency" and 2 or 3
        local ok, allowed = pcall(gamemode.Call, "CanTool", owner, original, "rt_npc_properties", tool, button)
        if not ok or allowed ~= true then return false end
    end
    if action == "health" then
        local value = tonumber(tool:GetClientNumber("health", 100)) or 100
        if value ~= value or math.abs(value) == math.huge then return false end
        value = math.Clamp(math.floor(value), 1, 5000)
        npc:SetMaxHealth(value)
        npc:SetHealth(value)
        owner:ChatPrint("NPC health set to " .. value .. ".")
    elseif action == "proficiency" then
        local value = tonumber(tool:GetClientNumber("proficiency", 1)) or 1
        if value ~= value or math.abs(value) == math.huge then return false end
        value = math.Clamp(math.floor(value), 0, 4)
        npc:SetCurrentWeaponProficiency(value)
        owner:ChatPrint("NPC weapon proficiency set to " .. ({"Poor", "Average", "Good", "Very good", "Perfect"})[value + 1] .. ".")
    elseif action == "toolgun" then
        local d = DashReality
        if not d or not isfunction(d.SetNPCToolgunAction) or not isfunction(d.GetNPCToolgunAction) then return false end
        local previous = d.GetNPCToolgunAction(npc)
        if previous ~= nil and previous ~= "freeze" then
            owner:ChatPrint("This NPC has another Tool Gun action; it was not changed.")
            return false
        end
        local wanted = previous == "freeze" and "off" or "freeze"
        local ok, reason = d.SetNPCToolgunAction(owner, npc, wanted)
        if not ok then
            owner:ChatPrint(reason or "NPC Tool Gun action was not changed.")
            return false
        end
        owner:ChatPrint(wanted == "freeze" and "NPC Tool Gun action: Freeze Entity. Equip the NPC separately."
            or "NPC Tool Gun action cleared; its normal action resumes and may be Remover.")
    else
        return false
    end
    return true
end

function TOOL:LeftClick(trace) return apply(self, trace, "health") end
function TOOL:RightClick(trace) return apply(self, trace, "proficiency") end

function TOOL:Reload(trace)
    if not trace or not trace.Hit or not IsValid(trace.Entity) then return false end
    if CLIENT then return true end
    local owner, hit = self:GetOwner(), trace.HitPos
    if not IsValid(owner) or not owner:IsPlayer() or not isvector(hit) or hit.x ~= hit.x or hit.y ~= hit.y or hit.z ~= hit.z
        or math.abs(hit.x) == math.huge or math.abs(hit.y) == math.huge or math.abs(hit.z) == math.huge
        or hit:DistToSqr(owner:GetShootPos()) > 1024 * 1024 then return false end
    return apply(self, trace, "toolgun")
end

function TOOL.BuildCPanel(panel)
    panel:Help("Left click: set current and maximum health. Right click: set weapon proficiency.")
    panel:ControlHelp("Reload: toggle Freeze Entity on a living native NPC you created (host or superadmin). Equip the NPC with a Tool Gun separately.")
    panel:ControlHelp("Clearing the action restores its normal Tool Gun behavior, which may be Remover.")
    panel:NumSlider("Health", "rt_npc_properties_health", 1, 5000, 0)
    local choices = panel:ComboBox("Weapon proficiency", "rt_npc_properties_proficiency")
    for i, name in ipairs({"Poor", "Average", "Good", "Very good", "Perfect"}) do choices:AddChoice(name, tostring(i - 1)) end
    panel:ControlHelp("Some scripted NPCs and weapons use their own combat rules. Frozen NPCs can be selected through their carrier.")
end
