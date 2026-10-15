-- A distinct startup entry also repairs installations with older cached autorun
-- chunks. The provider remains independent of all gameplay consumers.
if SERVER then AddCSLuaFile("autorun/contact_ik_runtime.lua") end
local source=assert(file.Read("autorun/contact_ik.lua","LUA"))
local chunk=CompileString(source,"autorun/contact_ik.lua",false)
assert(isfunction(chunk),chunk)
chunk()
