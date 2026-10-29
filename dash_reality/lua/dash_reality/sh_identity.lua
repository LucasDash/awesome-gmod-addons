-- NPC-inspired player profiles. These values are illustrative, not NPC class changes.
local D = DashReality
D.IdentityProfiles = {
    {id="citizen", label="Citizen", walk=125, run=210, slow=75, jump=180, health=100},
    {id="combine", label="Combine", walk=160, run=250, slow=90, jump=180, health=150},
    {id="zombie", label="Zombie", walk=70, run=125, slow=45, jump=110, health=150},
}
if not SERVER then return end

local profiles = {}
for _, profile in ipairs(D.IdentityProfiles) do profiles[profile.id] = profile end
local states = D.IdentityStates or setmetatable({}, {__mode="k"})
D.IdentityStates = states
local attributes = {
    {key="walk", get="GetWalkSpeed", set="SetWalkSpeed"},
    {key="run", get="GetRunSpeed", set="SetRunSpeed"},
    {key="slow", get="GetSlowWalkSpeed", set="SetSlowWalkSpeed"},
    {key="jump", get="GetJumpPower", set="SetJumpPower"},
    {key="health", get="GetMaxHealth", set="SetMaxHealth"},
}

local function permitted(ply)
    return IsValid(ply) and ply:IsPlayer()
        and (game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin())
end
local function same(a, b)
    return isnumber(a) and isnumber(b) and math.abs(a - b) < 0.001
end
local function changeMaxHealth(ply, target)
    local old = ply:GetMaxHealth()
    if old == target then return end
    local health = ply:Health()
    ply:SetMaxHealth(target)
    -- Preserve the current health fraction through apply/reset, including damage
    -- received while the profile was active. Never revive a dead player.
    if ply:Alive() and health > 0 and old > 0 then
        ply:SetHealth(math.max(1, math.floor(health * target / old + 0.5)))
    end
end

-- Only the requesting player is changed; no arbitrary target argument exists.
function D.ApplyIdentity(ply, id)
    if not permitted(ply) or not ply:Alive() then return false, "not permitted or not alive" end
    local profile = profiles[id or ""]
    if not profile then return false, "unknown identity" end
    local values = {}
    for _, attr in ipairs(attributes) do
        local getter, setter = ply[attr.get], ply[attr.set]
        if not isfunction(getter) or not isfunction(setter) then return false, "player attribute unavailable" end
        local ok, value = pcall(getter, ply)
        if not ok or not isnumber(value) or value ~= value or math.abs(value) == math.huge
            or attr.key == "health" and value <= 0 then return false, "invalid player attribute" end
        values[attr.key] = value
    end
    local state = states[ply]
    if not state then state={original={}, applied={}} states[ply]=state end
    for _, attr in ipairs(attributes) do
        local current = values[attr.key]
        -- A change by another addon becomes the new restoration baseline when
        -- the user explicitly switches profiles.
        if state.original[attr.key] == nil or not same(current, state.applied[attr.key]) then
            state.original[attr.key] = current
        end
        local target = profile[attr.key]
        if attr.key == "health" then changeMaxHealth(ply, target) else ply[attr.set](ply, target) end
        state.applied[attr.key] = target
    end
    state.id = profile.id
    ply:SetNW2String("DashReality.Identity", profile.id)
    return true
end

function D.ClearIdentity(ply)
    if not IsValid(ply) then return false end
    local state = states[ply]
    if not state then return false end
    -- Restore only values still owned by this profile; leave later changes by
    -- other systems in place. Max-health restoration follows the same rule.
    for _, attr in ipairs(attributes) do
        local current = ply[attr.get](ply)
        local original = state.original[attr.key]
        if original ~= nil and same(current, state.applied[attr.key]) then
            if attr.key == "health" then changeMaxHealth(ply, original) else ply[attr.set](ply, original) end
        end
    end
    states[ply] = nil
    ply:SetNW2String("DashReality.Identity", "")
    return true
end

concommand.Add("dash_identity", function(ply, _, args)
    if not permitted(ply) then return end
    if args[1] == "clear" then D.ClearIdentity(ply) else D.ApplyIdentity(ply, args[1]) end
end, nil, "Apply or clear your Dash Reality identity profile (host or superadmin only).")

-- Identity belongs to this life, not the next gamemode spawn. Restore safely
-- without changing health when dead and do not overwrite changed attributes.
for _, event in ipairs({"PlayerDeath", "PlayerSilentDeath", "PlayerSpawn"}) do
    hook.Add(event, "DashReality.IdentityClear", function(ply) D.ClearIdentity(ply) end)
end
hook.Add("PlayerDisconnected", "DashReality.IdentityClear", function(ply) states[ply] = nil end)
hook.Add("ShutDown", "DashReality.IdentityClear", function()
    for ply in pairs(states) do if IsValid(ply) then D.ClearIdentity(ply) end end
end)
