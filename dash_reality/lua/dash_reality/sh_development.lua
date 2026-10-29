-- Read-only, on-demand diagnostics. No entity scans, render hooks, bone setup,
-- custom RPCs or polling; each command samples only the aimed entity and, at
-- most, the original actor represented by a Dash Reality carrier.
local D = DashReality
D.Development = D.Development or {}
local Dev = D.Development
Dev.API_VERSION = 1

local function vector(v)
    return v and {x = v.x, y = v.y, z = v.z} or nil
end

local function reference(ent)
    if not IsValid(ent) then return nil end
    return {
        index = ent:EntIndex(), creation_id = ent:GetCreationID(),
        class = ent:GetClass(), model = ent:GetModel(),
    }
end

local function snapshot(ent)
    local mins, maxs = ent:GetCollisionBounds()
    local renderMins, renderMaxs = ent:GetModelRenderBounds()
    local angles = ent:GetAngles()
    local result = {
        entity = reference(ent),
        position = vector(ent:GetPos()),
        angles = {pitch = angles.p, yaw = angles.y, roll = angles.r},
        velocity = vector(ent:GetVelocity()),
        model_scale = ent:GetModelScale(),
        collision = {
            mins = vector(mins), maxs = vector(maxs), solid = ent:GetSolid(),
            group = ent:GetCollisionGroup(), move_type = ent:GetMoveType(),
        },
        model_render_bounds = {mins = vector(renderMins), maxs = vector(renderMaxs)},
        parent = reference(ent:GetParent()), owner = reference(ent:GetOwner()),
        actor = {
            player = ent:IsPlayer(), npc = ent:IsNPC(), nextbot = ent:IsNextBot(),
            scripted = ent:IsScripted(), health = ent:Health(), max_health = ent:GetMaxHealth(),
        },
        frozen_flag = ent:GetNW2Bool("RT_TimeFrozen", false),
        physics = {count = ent:GetPhysicsObjectCount()},
    }
    if ent:IsPlayer() then
        local standMin, standMax = ent:GetHull()
        local duckMin, duckMax = ent:GetHullDuck()
        result.player_hulls = {
            standing = {mins = vector(standMin), maxs = vector(standMax)},
            crouching = {mins = vector(duckMin), maxs = vector(duckMax)},
            view_offset = vector(ent:GetViewOffset()),
            ducked_view_offset = vector(ent:GetViewOffsetDucked()),
        }
    elseif SERVER and ent:IsNPC() then
        result.actor.hull_type = ent:GetHullType()
        result.actor.weapon_proficiency = ent:GetCurrentWeaponProficiency()
    end
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        result.physics.primary = {
            mass_kg = phys:GetMass(), motion_enabled = phys:IsMotionEnabled(),
            collisions_enabled = phys:IsCollisionEnabled(), asleep = phys:IsAsleep(),
        }
    end
    if SERVER then
        result.creator = reference(ent:GetCreator())
        result.time_frozen = D.IsTimeFrozen and D.IsTimeFrozen(ent) or false
    else
        result.render_origin = vector(ent:GetRenderOrigin())
    end
    return result
end

-- API-1 returns ordinary Lua data without entity userdata or nested live
-- registries. Server snapshots may include the authoritative carrier subject;
-- client snapshots report only what that client actually knows.
function Dev.InspectEntity(ent)
    if not IsValid(ent) then return nil, "No valid entity selected." end
    local result = {
        api_version = Dev.API_VERSION, realm = SERVER and "server" or "client",
        map = game.GetMap(), sampled_at = CurTime(), selected = snapshot(ent),
    }
    if SERVER and D.ResolveTarget then
        local subject = D.ResolveTarget(ent)
        if IsValid(subject) and subject ~= ent then result.subject = snapshot(subject) end
    end
    return result
end

local nextRequest = setmetatable({}, {__mode = "k"})
local function permitted(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return false end
    if SERVER and not (game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin()) then
        ply:ChatPrint("Dash Reality server inspection requires the host or a superadmin.")
        return false
    end
    return true
end

-- The Tool Gun supplies its actual trace target, avoiding an independent eye
-- trace that could select another entity. Permission and rate limits are shared
-- with console inspection. This function prints; InspectEntity remains pure.
function Dev.PrintEntityReport(ply, ent)
    if not permitted(ply) then return false end
    if (nextRequest[ply] or 0) > RealTime() then return false end
    nextRequest[ply] = RealTime() + 0.5
    local data, reason = Dev.InspectEntity(ent)
    local json = data and util.TableToJSON(data, true)
    local lines = string.Explode("\n", json or reason or "Inspection could not be serialized.")
    local header = "[Dash Reality / " .. (SERVER and "server" or "client") .. "] Entity inspection"
    if SERVER then
        ply:PrintMessage(HUD_PRINTCONSOLE, header .. "\n")
        for _, line in ipairs(lines) do ply:PrintMessage(HUD_PRINTCONSOLE, line .. "\n") end
    else
        MsgN(header)
        for _, line in ipairs(lines) do MsgN(line) end
    end
    return data ~= nil
end

local function inspectCommand(ply)
    if CLIENT then ply = LocalPlayer() end
    if not permitted(ply) then return end
    -- Reject rapid repeated requests before doing an extra trace.
    if (nextRequest[ply] or 0) > RealTime() then return end
    local trace = ply:GetEyeTrace()
    return Dev.PrintEntityReport(ply, trace and trace.Entity)
end

if SERVER then
    concommand.Add("dash_dev_inspect", inspectCommand, nil, "Inspect the aimed entity on the server (host or superadmin).")
else
    concommand.Add("dash_dev_inspect_client", inspectCommand, nil, "Inspect the aimed entity on this client.")
end
