if SERVER then
    AddCSLuaFile("autorun/contact_ik.lua")
    AddCSLuaFile("contact_ik/sh_geometry.lua")
    AddCSLuaFile("contact_ik/cl_arm.lua")
    AddCSLuaFile("contact_ik/cl_leases.lua")
    AddCSLuaFile("contact_ik/cl_body.lua")
    AddCSLuaFile("contact_ik/cl_legs.lua")
    AddCSLuaFile("contact_ik/cl_contacts.lua")
    AddCSLuaFile("contact_ik/cl_settings.lua")
end
ContactIK = ContactIK or {}
if ContactIK.Shutdown then ContactIK.Shutdown() end
-- Read the mounted source explicitly: include can execute an older downloaded
-- chunk after local development files have changed in the same installation.
ContactIK.LoadedSourceHashes={}
local function load(path)
    local source=assert(file.Read(path,"LUA"),"Contact IK source missing: "..path)
    local chunk=CompileString(source,"contact_ik/"..path,false)
    assert(isfunction(chunk),chunk)
    chunk()
    ContactIK.LoadedSourceHashes[path]=util.SHA256(source)
end
load("contact_ik/sh_geometry.lua")
if SERVER then load("contact_ik/sv_eligibility.lua") end
if CLIENT then
    load("contact_ik/cl_arm.lua")
    load("contact_ik/cl_body.lua")
    load("contact_ik/cl_legs.lua")
    load("contact_ik/cl_leases.lua")
    load("contact_ik/cl_contacts.lua")
    load("contact_ik/cl_settings.lua")
end
hook.Run("ContactIKReady",ContactIK)
