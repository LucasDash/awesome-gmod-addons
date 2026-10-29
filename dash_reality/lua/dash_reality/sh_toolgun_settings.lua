-- Settings for the existing Universal Tool Gun provider, whether bundled or standalone.
local D = DashReality
D.ToolgunSettings = {
    {id="npc_remover", convar="universal_toolgun_npc_remover", label="NPCs can use the Remover"},
    {id="instakill", convar="universal_toolgun_instakill", label="Remover instantly eliminates NPCs"},
    {id="kill_players", convar="universal_toolgun_kill_players", label="NPC Remover can kill players"},
    {id="enemy_assist", convar="universal_toolgun_enemy_assist", label="Assist NPC aim at their enemy"},
}
if not SERVER then return end
local byID, last, watched = {}, {}, {}
local DISCOVERY_TIMER = "DashReality.ToolgunSettings"
local CALLBACK_PREFIX = "DashReality.ToolgunSettings."
for _,def in ipairs(D.ToolgunSettings) do byID[def.id] = def end
local function authorized(ply)
    return not IsValid(ply) or game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin()
end
local publish
publish = function()
    local ready = true
    for _,item in ipairs(D.ToolgunSettings) do
        local def = item
        local cv = GetConVar(def.convar)
        if not cv then ready = false else
            if not watched[def.id] then
                -- Replace only this module's callback when source is refreshed.
                cvars.RemoveChangeCallback(def.convar, CALLBACK_PREFIX .. def.id)
                cvars.AddChangeCallback(def.convar, publish, CALLBACK_PREFIX .. def.id)
                watched[def.id] = true
            end
            local value = cv:GetBool()
            if last[def.id] ~= value then
                SetGlobal2Bool("DashReality.Toolgun." .. def.id, value)
                last[def.id] = value
            end
        end
    end
    if last.ready ~= ready then SetGlobal2Bool("DashReality.Toolgun.Ready", ready) last.ready = ready end
    if ready then timer.Remove(DISCOVERY_TIMER) end
    return ready
end

local function discover()
    timer.Remove(DISCOVERY_TIMER)
    if publish() then return end
    -- Dash Reality's settings loader can run before either provider creates
    -- its convars. Discover for at most 20 seconds, stopping as soon as all are
    -- present. Ordinary initialization and source reload reopen that window.
    -- Once ready, change callbacks handle console, profiles and UI changes.
    timer.Create(DISCOVERY_TIMER, 0.25, 80, publish)
end
D.RefreshToolgunSettings = discover
function D.SetToolgunSetting(ply, id, raw)
    if not authorized(ply) then return false end
    local def = byID[id or ""]
    local value = tonumber(raw)
    if not def or (value ~= 0 and value ~= 1) then return false end
    local cv = GetConVar(def.convar)
    if not cv then return false end
    cv:SetInt(value)
    publish()
    return true
end
concommand.Add("dash_toolgun_setting", function(ply, _, args)
    D.SetToolgunSetting(ply, args[1], args[2])
end, nil, "Changes a whitelisted Universal Tool Gun setting (host or superadmin only).")
hook.Add("InitPostEntity", "DashReality.ToolgunSettings", discover)
hook.Add("OnReloaded", "DashReality.ToolgunSettings", discover)
discover()
