TOOL.Tab = "DashReality"
TOOL.Category = "Development"
TOOL.Name = "#tool.rt_inspector.name"
TOOL.Information = {{name = "left"}, {name = "right"}}

if CLIENT then
    language.Add("tool.rt_inspector.name", "Entity Inspector")
    language.Add("tool.rt_inspector.desc", "Read an entity's collision, physics and actor state in the console.")
    language.Add("tool.rt_inspector.left", "Print server inspection (host or superadmin)")
    language.Add("tool.rt_inspector.right", "Print client inspection")
end

function TOOL:LeftClick(trace)
    if not IsValid(trace.Entity) then return false end
    if CLIENT then return true end
    local dev = DashReality and DashReality.Development
    return dev and dev.PrintEntityReport(self:GetOwner(), trace.Entity) or false
end

function TOOL:RightClick(trace)
    if not IsValid(trace.Entity) then return false end
    if CLIENT and IsFirstTimePredicted() then
        local dev = DashReality and DashReality.Development
        if dev then dev.PrintEntityReport(self:GetOwner(), trace.Entity) end
    end
    return true
end

function TOOL.BuildCPanel(panel)
    panel:Help("Aim at an entity. Left click prints server state; right click prints client state. Open the developer console to read the report.")
    panel:ControlHelp("Inspections do not change the entity. Server reports require the host or a superadmin; Tool Gun permissions also apply.")
end
