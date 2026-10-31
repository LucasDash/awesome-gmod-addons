-- Experimental opt-in adapter for one exact Workshop gWater2 source version.
-- The original addon files and globals remain intact. Only compatible weapon
-- instances receive temporary server-realm method overrides.
if not SERVER then return end

DashReality = DashReality or {}
local NAME, SETTING = "DashReality.GWaterWorkshopPatch", "rt_gwater_vfire_contact"
local CLASS, SOURCE = "weapon_gw2_watergun", "weapons/weapon_gw2_watergun.lua"
local SOURCE_SHA256 = "0dde994f93bdc388212abeeba9c1c9348ed9b39e17917900c4b213b0b0bfdc3b"
local previous = DashReality.GWaterWorkshopPatch
if previous and isfunction(previous.Shutdown) then previous.Shutdown() end
local function particleOwns()
    local monitor = DashReality.FluidParticleReadiness
    if not game.SinglePlayer() or not monitor or not isfunction(monitor.IsReady) then return false end
    local ok, value = pcall(monitor.IsReady)
    return ok and value == true
end
local enabled = GetConVar(SETTING) or CreateConVar(SETTING, "0", FCVAR_ARCHIVE + FCVAR_NOTIFY,
    "Experimental gWater gun exposure approximation, not particle contact.", 0, 1)
local records = setmetatable({}, {__mode = "k"})
local primary, secondary, status = nil, nil, "disabled"
local count, skipped = 0, 0
local function publishStatus()
    if isfunction(SetGlobal2String) then SetGlobal2String("DashReality.GWaterGunPatch", status) end
end

local function replaceOnce(text, needle, replacement)
    local first, last = string.find(text, needle, 1, true)
    if not first or string.find(text, needle, last + 1, true) then return nil end
    return string.sub(text, 1, first - 1) .. replacement .. string.sub(text, last + 1)
end

local function compileCompatible()
    if not debug or not isfunction(debug.getinfo) then return false, "runtime_unavailable" end
    local source = file.Read(SOURCE, "LUA")
    if not isstring(source) or not isfunction(util.SHA256)
        or string.lower(util.SHA256(source)) ~= SOURCE_SHA256 then return false, "source_mismatch" end
    local insert = [[local function __dash_fluid_emit(weapon, actor, pos, velocity, radius)
    pcall(hook.Run, "GWater2FluidEmission", {version=1, source=weapon, actor=actor,
        origin=Vector(pos.x,pos.y,pos.z), velocity=Vector(velocity.x,velocity.y,velocity.z),
        shape="sphere", radius=radius})
end

function SWEP:PrimaryAttack()]]
    source = replaceOnce(source, "function SWEP:PrimaryAttack()", insert)
    if not source then return false, "patch_mismatch" end
    local first = "gwater2.AddSphere(gwater2.quick_matrix(pos), 4, {vel = owner:EyeAngles():Forward() * math.max(radius, 5) + owner:GetVelocity() * FrameTime()})"
    local firstPatch = "local __dash_velocity = owner:EyeAngles():Forward() * math.max(radius, 5) + owner:GetVelocity() * FrameTime()\n\tgwater2.AddSphere(gwater2.quick_matrix(pos), 4, {vel = __dash_velocity})"
    source = replaceOnce(source, first, firstPatch)
    if not source then return false, "patch_mismatch" end
    local second = "gwater2.AddSphere(gwater2.quick_matrix(pos), 20, {vel = owner:EyeAngles():Forward() * math.Clamp(gwater2.parameters.radius or 10, 5, 10)})"
    local secondPatch = "local __dash_velocity = owner:EyeAngles():Forward() * math.Clamp(gwater2.parameters.radius or 10, 5, 10)\n\tgwater2.AddSphere(gwater2.quick_matrix(pos), 20, {vel = __dash_velocity})"
    source = replaceOnce(source, second, secondPatch)
    if not source then return false, "patch_mismatch" end
    source = replaceOnce(source, 'owner:EmitSound("Water.ImpactSoft")', 'owner:EmitSound("Water.ImpactSoft")\n\t__dash_fluid_emit(self, owner, pos, __dash_velocity, 4)')
    if not source then return false, "patch_mismatch" end
    source = replaceOnce(source, 'self:SetNextSecondaryFire(CurTime() + 1 / 4)', 'self:SetNextSecondaryFire(CurTime() + 1 / 4)\n\t__dash_fluid_emit(self, owner, pos, __dash_velocity, 20)')
    if not source then return false, "patch_mismatch" end
    local compiled = CompileString(source, "DashReality.GWaterCompatibleWeapon", false)
    if not isfunction(compiled) then return false, "compile_failed" end
    local definition = {Primary = {}, Secondary = {}}
    setfenv(compiled, setmetatable({SWEP = definition}, {__index = _G}))
    local ok = pcall(compiled)
    if not ok or not isfunction(definition.PrimaryAttack) or not isfunction(definition.SecondaryAttack) then
        return false, "initialization_failed"
    end
    primary, secondary = definition.PrimaryAttack, definition.SecondaryAttack
    return true
end

local function isOriginal(fn)
    if not isfunction(fn) or not debug or not isfunction(debug.getinfo) then return false end
    local info = debug.getinfo(fn, "S")
    return info and isstring(info.short_src) and string.sub(info.short_src, -#SOURCE) == SOURCE
end

local function apply(weapon)
    if not enabled:GetBool() or not primary or not IsValid(weapon) or weapon:GetClass() ~= CLASS
        or records[weapon] then return end
    local values = weapon:GetTable()
    if not istable(values) or not isOriginal(weapon.PrimaryAttack) or not isOriginal(weapon.SecondaryAttack) then
        skipped = skipped + 1
        return
    end
    records[weapon] = {primary = rawget(values, "PrimaryAttack"), secondary = rawget(values, "SecondaryAttack")}
    values.PrimaryAttack, values.SecondaryAttack = primary, secondary
    count = count + 1
end

local function stop()
    hook.Remove("WeaponEquip", NAME)
    hook.Remove("EntityRemoved", NAME)
    for weapon, record in pairs(records) do
        if IsValid(weapon) then
            local values = weapon:GetTable()
            if istable(values) then
                if values.PrimaryAttack == primary then values.PrimaryAttack = record.primary end
                if values.SecondaryAttack == secondary then values.SecondaryAttack = record.secondary end
            end
        end
    end
    records = setmetatable({}, {__mode = "k"})
    primary, secondary, count = nil, nil, 0
    status = "disabled"
    publishStatus()
end

local function start()
    stop()
    if not enabled:GetBool() then return end
    if particleOwns() then status = "particle_only"; publishStatus(); return end
    local ok, reason = compileCompatible()
    if not ok then status = reason; publishStatus(); return end
    status = "ready"
    publishStatus()
    hook.Add("WeaponEquip", NAME, function(weapon) apply(weapon) end)
    hook.Add("EntityRemoved", NAME, function(weapon)
        if records[weapon] then records[weapon] = nil; count = math.max(0, count - 1) end
    end)
    for _, weapon in ipairs(ents.FindByClass(CLASS)) do apply(weapon) end
end

cvars.AddChangeCallback(SETTING, start, NAME)
hook.Add("DashReality.FluidDetectorModeChanged", NAME, start)
DashReality.GWaterWorkshopPatch = {
    Status = function() return {status=status, patched=count, skipped=skipped, source=SOURCE_SHA256} end,
    Shutdown = function() stop(); hook.Remove("DashReality.FluidDetectorModeChanged", NAME); cvars.RemoveChangeCallback(SETTING, NAME) end
}
if enabled:GetBool() then start() end
if not enabled:GetBool() then publishStatus() end
