-- General session controls. Reading the current engine values does not change
-- the session; the server applies a setting only when an authorized user asks.
local RT = DashReality

RT.GeneralSettings = {
    {
        id = "gravity", convar = "sv_gravity", realm = "server",
        label = "World gravity", min = 0, max = 2000, decimals = 0,
        help = "Affects players, NPCs and physics objects across the server.",
    },
    {
        id = "ai_disabled", convar = "ai_disabled", realm = "server", type = "bool",
        label = "Pause native NPC AI", min = 0, max = 1,
        help = "Pauses engine NPC thinking across the session. Scripted AI may keep running; this does not freeze physics or preserve a pose.",
    },
    {
        id = "ai_ignoreplayers", convar = "ai_ignoreplayers", realm = "server", type = "bool",
        label = "Native NPC AI ignores players", min = 0, max = 1,
        help = "Uses the game's native ignore-players setting. Custom NPC frameworks can use their own targeting rules.",
    },
    {
        id = "fov", convar = "fov_desired", realm = "client",
        label = "Field of view", min = 75, max = 120, decimals = 0,
        help = "Your preferred view angle; the server may impose its own limits.",
    },
    {
        id = "net_graph", convar = "net_graph", realm = "client",
        label = "Network and frame graph", min = 0, max = 3, decimals = 0,
        help = "Controls your local network graph display (0 turns it off).",
    },
    {
        id = "death_notice", convar = "hud_deathnotice_time", realm = "client",
        label = "Death notice duration", min = 0, max = 15, decimals = 0,
        help = "How long death notices remain on your HUD, in seconds.",
    },
}

if not SERVER then return end

local serverSettings = {}
for _, def in ipairs(RT.GeneralSettings) do
    if def.realm == "server" then serverSettings[def.id] = def end
end

-- Native AI convars are not replicated. Mirror their state on change rather
-- than polling, including changes made through the game's own NPC controls.
-- -1 marks an unavailable engine control on this server.
for _, item in ipairs(RT.GeneralSettings) do
    if item.realm == "server" and item.type == "bool" then
        local def = item
        local function publish()
            local cv = GetConVar(def.convar)
            SetGlobalInt("DashReality.Environment." .. def.id, cv and (cv:GetBool() and 1 or 0) or -1)
        end
        local callbackID = "DashReality.Environment." .. def.id
        cvars.RemoveChangeCallback(def.convar, callbackID)
        cvars.AddChangeCallback(def.convar, publish, callbackID)
        publish()
    end
end

local function canAdjust(ply)
    return not IsValid(ply) or game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin()
end

-- The ID is a whitelist, not an arbitrary console command or convar name.
-- Reject non-finite input before applying the control's bounds.
function RT.SetEnvironment(ply, id, rawValue)
    if not canAdjust(ply) then return false end
    local def = serverSettings[id or ""]
    local value = tonumber(rawValue)
    if not def or not value or value ~= value or math.abs(value) == math.huge then return false end
    if def.type == "bool" and value ~= 0 and value ~= 1 then return false end
    local cvar = GetConVar(def.convar)
    if not cvar then return false end
    value = math.Clamp(value, def.min, def.max)
    if def.type == "bool" then cvar:SetInt(value) else cvar:SetFloat(value) end
    return true
end

concommand.Add("rt_environment", function(ply, _, args)
    RT.SetEnvironment(ply, args[1], args[2])
end, nil, "Changes an allowed Dash Reality environment setting (host or superadmin only).")
