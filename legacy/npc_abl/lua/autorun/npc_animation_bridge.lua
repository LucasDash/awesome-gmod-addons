if SERVER then
	if NPCAnimationBridge and NPCAnimationBridge.Preview then NPCAnimationBridge.Preview.Shutdown() end
	AddCSLuaFile()
	AddCSLuaFile("npc_animation_bridge/sh_catalog.lua")
	AddCSLuaFile("npc_animation_bridge/sh_controllers.lua")
	AddCSLuaFile("npc_animation_bridge/sh_pose_sync.lua")
	AddCSLuaFile("npc_animation_bridge/sh_provider.lua")
	AddCSLuaFile("npc_animation_bridge/cl_carrier_pose.lua")
	AddCSLuaFile("npc_animation_bridge/cl_appearance.lua")
end
include("npc_animation_bridge/sh_catalog.lua")
include("npc_animation_bridge/sh_controllers.lua")
include("npc_animation_bridge/sh_pose_sync.lua")
include("npc_animation_bridge/sh_provider.lua")
if CLIENT then
	include("npc_animation_bridge/cl_carrier_pose.lua")
	include("npc_animation_bridge/cl_appearance.lua")
end
if SERVER then
	include("npc_animation_bridge/sv_executor.lua")
	include("npc_animation_bridge/sv_fullbody.lua")
	include("npc_animation_bridge/sv_layers.lua")
	include("npc_animation_bridge/sv_carrier.lua")
	include("npc_animation_bridge/sv_preview.lua")
end
