TOOL.Tab = "DashReality"
TOOL.Category = "Universal Tool Gun"
TOOL.Name = "#tool.rt_timefreeze.name"
TOOL.ClientConVar["radius"] = "300"
TOOL.Information = {
    { name = "left" },
    { name = "right" },
    { name = "reload" },
}

if CLIENT then
    language.Add("tool.rt_timefreeze.name", "Freeze Entity")
    language.Add("tool.rt_timefreeze.desc", "Freeze NPCs, physics props and ragdolls; move frozen NPCs with the Physgun or use key.")
    language.Add("tool.rt_timefreeze.left", "Freeze or unfreeze the targeted entity")
    language.Add("tool.rt_timefreeze.right", "Freeze supported entities in the radius (unfreezes them if all are frozen)")
    language.Add("tool.rt_timefreeze.reload", "Release entities you froze")
end

function TOOL:LeftClick(trace)
    if not IsValid(trace.Entity) then return false end
    if CLIENT then return true end
    local ok = DashReality.ToolToggle(self:GetOwner(), trace.Entity, self, trace)
    if not ok then self:GetOwner():EmitSound("buttons/button10.wav", 60) end
    return ok
end

function TOOL:RightClick(trace)
    if CLIENT then return true end
    local radius = math.Clamp(self:GetClientNumber("radius", 300), 32, 4096)
    return DashReality.ToolArea(self:GetOwner(), trace.HitPos, radius, self)
end

function TOOL:Reload()
    if CLIENT then return true end
    return DashReality.ReleaseAll(self:GetOwner())
end

function TOOL.BuildCPanel(panel)
    panel:Help("#tool.rt_timefreeze.desc")
    panel:NumSlider("Area radius", "rt_timefreeze_radius", 32, 2048, 0)
    if DashReality and DashReality.BuildFreezeSettings then DashReality.BuildFreezeSettings(panel) end
end
