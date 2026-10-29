-- Player experience (server): Drop Weapon and Death Perception's server half.
-- Settings live in RT.SettingList (group "Player") so the dashboard and rt_setting manage them.

local RT = DashReality

local cvEnabled = GetConVar("rt_player_dropweapon_enable")
local cvOnDeath = GetConVar("rt_player_dropweapon_ondeath")
local cvActiveOnly = GetConVar("rt_player_dropweapon_activeonly")
local cvTools = GetConVar("rt_player_dropweapon_tools")
local cvNoEarRing = GetConVar("rt_player_dp_noearring")

local DROP_COOLDOWN = 0.4

-- Only these built-in utility weapons are covered; other addons can veto any
-- weapon through DashReality.CanDropWeapon.
local utilityWeapons = {
    weapon_fists = true,
    weapon_physgun = true,
    weapon_physcannon = true,
    gmod_tool = true,
    gmod_camera = true,
}

local function isGhost(ply)
    return ply:GetNW2Bool("NoclipGhost", false)
end

local function canDrop(ply, wep, forced)
    if not IsValid(ply) or not IsValid(wep) or wep:GetOwner() ~= ply then return false end
    if isGhost(ply) and not forced then return false end
    if cvTools and not cvTools:GetBool() and utilityWeapons[wep:GetClass()] then return false end
    return hook.Run("DashReality.CanDropWeapon", ply, wep) ~= false
end

function RT.DropWeapon(ply, wep, forced)
    if not canDrop(ply, wep, forced) then return false end
    ply:DropWeapon(wep)
    return true
end

local function dropActive(ply)
    if not IsValid(ply) or not ply:Alive() or not cvEnabled:GetBool() then return end
    if (ply.RT_NextDrop or 0) > CurTime() then return end
    ply.RT_NextDrop = CurTime() + DROP_COOLDOWN
    RT.DropWeapon(ply, ply:GetActiveWeapon())
end

concommand.Add("dash_dropweapon", dropActive, nil, "Drops the weapon in your hands.")

-- The standalone Drop Weapon addon binds +drop; keep that binding working without clobbering it.
local existing = concommand.GetTable()
local previous = existing["+drop"]
local info = previous and debug.getinfo(previous, "S")
local source = info and info.source or ""
if not previous or string.find(source, "dash_reality/sv_player.lua", 1, true) then
    concommand.Add("+drop", dropActive)
    concommand.Add("-drop", function() end)
end

hook.Add("DoPlayerDeath", "DashReality.DropOnDeath", function(ply)
    if not cvEnabled:GetBool() or not cvOnDeath:GetBool() then return end
    if cvActiveOnly:GetBool() then
        RT.DropWeapon(ply, ply:GetActiveWeapon(), true)
        return
    end
    for _, wep in ipairs(ply:GetWeapons()) do RT.DropWeapon(ply, wep, true) end
end)

-- Death Perception: a dying player hears silence, not blast tinnitus.
hook.Add("OnDamagedByExplosion", "DashReality.DeathPerception", function(ply)
    if not cvNoEarRing:GetBool() then return end
    if IsValid(ply) and ply:Health() <= 0 and ply:GetViewEntity() == ply then return true end
end)
