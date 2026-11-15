TOOL.Tab = "DashReality"
TOOL.Category = "NPC"
TOOL.Name = "#tool.rt_npc_camera.name"
TOOL.Information = {{name = "left"}, {name = "right"}, {name = "reload"}}

if CLIENT then
    language.Add("tool.rt_npc_camera.name", "NPC Camera")
    language.Add("tool.rt_npc_camera.desc", "View an NPC or NextBot without taking control of it.")
    language.Add("tool.rt_npc_camera.left", "View from its eyes")
    language.Add("tool.rt_npc_camera.right", "View from behind it")
    language.Add("tool.rt_npc_camera.reload", "Exit camera view")
else
    util.AddNetworkString("DashReality.NPCCamera")
end

local function selectActor(tool, trace, mode)
    local ent = trace and trace.Entity
    if not IsValid(ent) or not (ent:IsNPC() or ent:IsNextBot()) then return false end
    if CLIENT then return true end
    local ply = tool:GetOwner()
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
    -- Sandbox calls CanTool before this method. The server uses its own trace,
    -- never an entity index submitted by a client. Viewing changes no server state.
    net.Start("DashReality.NPCCamera")
    net.WriteEntity(ent)
    net.WriteUInt(mode, 2)
    net.Send(ply)
    return true
end

function TOOL:LeftClick(trace) return selectActor(self, trace, 1) end
function TOOL:RightClick(trace) return selectActor(self, trace, 2) end
function TOOL:Reload(trace)
    if CLIENT then
        if DashReality and DashReality.NPCCamera then DashReality.NPCCamera.Stop() end
        return true
    end
    local ply = self:GetOwner()
    if not IsValid(ply) or not ply:IsPlayer() then return false end
    net.Start("DashReality.NPCCamera")
    net.WriteEntity(NULL)
    net.WriteUInt(0, 2)
    net.Send(ply)
    return true
end

function TOOL.BuildCPanel(panel)
    panel:Help("Left click an NPC or NextBot for its eye view; right click for a view behind it.")
    panel:ControlHelp("In the trailing view, hold the context menu key (normally C) and drag middle mouse to orbit. Run dash_npc_camera_orbit_reset to reset the angle.")
    panel:ControlHelp("Reload exits. You may bind a key to dash_npc_camera_exit for a reliable independent exit. Switching tools, player death, losing the entity or a map cleanup also ends the view.")
    panel:ControlHelp("This changes your camera only. Your player stays where they were; movement and sound still belong to your player. Distant entities may leave network visibility.")
end
