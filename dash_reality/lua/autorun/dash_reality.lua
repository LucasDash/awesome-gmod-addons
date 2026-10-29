-- Dash Reality: space/time/NPC-behaviour manipulation toolkit for Sandbox.

DashReality = DashReality or RealityTools or {}
RealityTools = DashReality -- Compatibility for existing integrations and live state.
local RT = DashReality

RT.SettingList = {
    { name = "rt_ragdoll_enable", type = "bool", default = 1, label = "NPCs ragdoll when picked up with the Physgun", help = "Physgun-held NPCs turn limp and stand back up after settling." },
    { name = "rt_ragdoll_delay", type = "float", default = 2.5, min = 0.5, max = 15, label = "Seconds at rest before standing up" },
    { name = "rt_ragdoll_damage_pass", type = "bool", default = 1, label = "Ragdoll damage hurts the NPC" },
    { name = "rt_freeze_rewind", type = "bool", default = 0, label = "Unfreezing rewinds the NPC to where it was frozen" },
    { name = "rt_freeze_nextbots", type = "bool", default = 1, label = "Freeze NPCs also affects NextBots (best effort)" },
    { name = "rt_undo_enable", type = "bool", default = 1, label = "Physgun moves can be undone (Undo key)", help = "Each finished physgun move becomes an undo entry." },
    { group = "Physics", name = "rt_phys_npc_mass_scale", type = "float", default = 1, min = 0.1, max = 5, label = "NPC weight multiplier", help = "NPCs have no VPhysics weight, so it is estimated from their size (an 80 kg citizen). Heavier NPCs are harder for ropes, balloons and props to move." },
    { group = "Physics", name = "rt_phys_max_force", type = "float", default = 4000, min = 200, max = 20000, label = "Maximum link force (newtons)", help = "Caps how hard any rope or balloon can push or pull a body; keeps heavy props from launching NPCs." },
    { group = "Physics", name = "rt_phys_carry_friction", type = "float", default = 10, min = 1, max = 40, label = "NPC sliding friction", help = "How quickly a grounded NPC that was pulled sideways stops sliding (per second). Lower is icier." },
    { group = "Player", name = "rt_player_dropweapon_enable", type = "bool", default = 1, label = "Players can drop their weapon (+drop / dash_dropweapon)", help = "Ghosts never drop weapons, since a dropped weapon would reveal them." },
    { group = "Player", name = "rt_player_dropweapon_tools", type = "bool", default = 1, label = "Allow dropping tools and fists", help = "Includes fists, Physgun, Gravity Gun, Tool Gun and Camera in manual and death drops. Other weapons are unaffected." },
    { group = "Player", name = "rt_player_dropweapon_ondeath", type = "bool", default = 0, label = "Players drop weapons on death" },
    { group = "Player", name = "rt_player_dropweapon_activeonly", type = "bool", default = 1, label = "Drop only the active weapon on death" },
    { group = "Player", name = "rt_player_dp_noearring", type = "bool", default = 1, label = "No blast tinnitus while dying (Death Perception)" },
    { group = "Noclip Ghost (optional)", name = "noclip_ghost_enabled", type = "bool", default = 1, label = "Noclipping players become undetectable observers" },
    { name = "noclip_ghost_adminonly", type = "bool", default = 1, label = "Only admins (and the singleplayer host)" },
    { name = "noclip_ghost_prevent_transmit", type = "bool", default = 1, label = "Hide ghost from other players' clients" },
    { name = "noclip_ghost_silent", type = "bool", default = 1, label = "Suppress ghost sounds" },
    { name = "noclip_ghost_block_damage", type = "bool", default = 1, label = "Ghosts take no damage" },
}

RT.Settings = {}
for _, def in ipairs(RT.SettingList) do
    RT.Settings[def.name] = def
    if def.type == "bool" then def.min, def.max = 0, 1 end
    CreateConVar(def.name, tostring(def.default), FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, def.help or def.label, def.min, def.max)
end

local cvarCache = {}
function RT.Float(name)
    local cvar = cvarCache[name]
    if not cvar then
        cvar = GetConVar(name)
        cvarCache[name] = cvar
    end
    return cvar and cvar:GetFloat() or RT.Settings[name].default
end

function RT.Bool(name)
    return RT.Float(name) ~= 0
end

if SERVER then
    AddCSLuaFile("dash_reality/sh_general_settings.lua")
    AddCSLuaFile("dash_reality/sh_toolgun_settings.lua")
    AddCSLuaFile("dash_reality/sh_universal_toolgun.lua")
    AddCSLuaFile("dash_reality/sh_physics.lua")
    AddCSLuaFile("dash_reality/sh_npc_ropes.lua")
    AddCSLuaFile("dash_reality/sh_identity.lua")
    AddCSLuaFile("dash_reality/sh_development.lua")
    AddCSLuaFile("dash_reality/cl_identity.lua")
    AddCSLuaFile("dash_reality/cl_profiles.lua")
    AddCSLuaFile("dash_reality/cl_workbench_bridge.lua")
end
include("dash_reality/sh_general_settings.lua")
include("dash_reality/sh_toolgun_settings.lua")
-- Shared units/mass/link-solver library; later features (ropes, weights) build on DashReality.Physics.
include("dash_reality/sh_physics.lua")
include("dash_reality/sh_npc_ropes.lua")
include("dash_reality/sh_identity.lua")
include("dash_reality/sh_development.lua")

-- A mounted standalone provider owns gmod_tool when present. Otherwise use
-- the bundled Workshop baseline; never install both patches in one session.
if not RT.ToolgunProvider then
    if file.Exists("autorun/universal_toolgun.lua", "LUA") then
        RT.ToolgunProvider = "standalone"
    else
        include("dash_reality/sh_universal_toolgun.lua")
        RT.ToolgunProvider = "bundled"
    end
end

if SERVER then
    include("dash_reality/sv_freeze_physics.lua")
    AddCSLuaFile("dash_reality/cl_dashboard.lua")
    AddCSLuaFile("dash_reality/cl_frozen_context.lua")
    AddCSLuaFile("dash_reality/sh_ghost.lua")
    AddCSLuaFile("dash_reality/cl_view.lua")
    AddCSLuaFile("dash_reality/cl_death_perception.lua")
    AddCSLuaFile("dash_reality/cl_firstperson_body.lua")
    -- Refreshing the dashboard must not discard active frozen NPCs, ragdoll
    -- swaps, ghost states or in-progress Physgun undo records.
    if not RT.ServerRuntimeLoaded then
        include("dash_reality/sh_ghost.lua")
        include("dash_reality/sv_player.lua")
        include("dash_reality/sv_freeze.lua")
        include("dash_reality/sv_ragdoll.lua")
        include("dash_reality/sv_undo.lua")
        include("dash_reality/sv_npc_ropes.lua")
        RT.ServerRuntimeLoaded = true
    end
    include("dash_reality/sv_profiles.lua")
    include("dash_reality/sv_npc_toolgun.lua")

    local function canAdjust(ply)
        return not IsValid(ply) or game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin()
    end

    concommand.Add("rt_setting", function(ply, _, args)
        local def = RT.Settings[args[1] or ""]
        local value = tonumber(args[2] or "")
        if not def or not value or value ~= value or math.abs(value) == math.huge or not canAdjust(ply) then return end
        local cv = GetConVar(def.name)
        if cv then cv:SetFloat(math.Clamp(value, def.min, def.max)) end
    end, nil, "Changes a Dash Reality server setting (host or superadmin only).")
else
    include("dash_reality/sh_ghost.lua")
    include("dash_reality/cl_view.lua")
    include("dash_reality/cl_death_perception.lua")
    include("dash_reality/cl_firstperson_body.lua")
    include("dash_reality/cl_frozen_context.lua")
    include("dash_reality/cl_identity.lua")
    include("dash_reality/cl_profiles.lua")
    include("dash_reality/cl_workbench_bridge.lua")
    include("dash_reality/cl_dashboard.lua")
end
