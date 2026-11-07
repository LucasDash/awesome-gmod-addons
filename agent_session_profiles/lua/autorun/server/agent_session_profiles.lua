-- Optional, server-owned session profiles. No profile activates on startup.
if not SERVER then return end

local previous = AgentSessionProfiles
if previous and type(previous.Shutdown) == 'function' then
    local called, ended, reason = pcall(previous.Shutdown)
    if not called or ended == false then
        ErrorNoHalt('[Agent Session] Previous manager could not clean up: '..tostring(reason or ended)..'\n')
        return
    end
end

local hookID = 'AgentSessionProfiles.NPCTest'
local disconnectID = 'AgentSessionProfiles.Pending'
local commandName = 'agent_session_profile'
local existingCommands = concommand.GetTable()
local existingHooks = hook.GetTable()
if existingCommands[commandName] or (existingHooks.PlayerDisconnected or {})[disconnectID]
    or (existingHooks.ShutDown or {})[disconnectID] then
    ErrorNoHalt('[Agent Session] A reserved command or lifecycle hook is already owned by another addon.\n')
    return
end

local api = {}
AgentSessionProfiles = api
local privilege = 'Agent Session Profiles'
local active, issuedOrder, acceptedOrder, stopped = 'none', 0, 0, false
local counters = {npcKills=0}
local pending = setmetatable({}, {__mode='k'})
local registeredCAMI
local validActions = {none=true, observer=true, npc_experiment=true}
local npcHook, disconnectHook, shutdownHook
local MAX_PENDING = 16

local function removeOwnedHook(event, id, fn)
    if (hook.GetTable()[event] or {})[id] == fn then hook.Remove(event, id) end
end

local function tell(ply, message)
    if IsValid(ply) and ply:IsPlayer() then ply:ChatPrint('[Agent Session] '..message)
    else print('[Agent Session] '..message) end
end

local function stopCurrent()
    if active == 'npc_experiment' then
        removeOwnedHook('OnNPCKilled', hookID, npcHook)
        npcHook = nil
    end
    active = 'none'
    return true
end

local function observerReady()
    local cv = GetConVar('noclip_ghost_enabled')
    return type(DashReality) == 'table' and type(DashReality.GhostStates) == 'table'
        and cv ~= nil and type(cv.GetBool) == 'function' and cv:GetBool() == true
end

function api.GetStatus()
    -- Return a new bounded value; callers cannot mutate private state.
    return {active=active, npcKills=active == 'npc_experiment' and counters.npcKills or 0,
        observerReady=active == 'observer' and observerReady() or false,
        experimentReady=active == 'npc_experiment' and (hook.GetTable().OnNPCKilled or {})[hookID] == npcHook or false}
end

local function activate(id)
    if stopped then return false, 'session profile manager is shut down' end
    if not validActions[id] then return false, 'unknown profile' end
    if active == id then
        if id == 'npc_experiment' and (hook.GetTable().OnNPCKilled or {})[hookID] ~= npcHook then
            return false, 'NPC experiment hook was replaced'
        end
        return true, 'already active: '..id
    end
    if id == 'observer' and not observerReady() then
        return false, 'enable Dash Reality Ghost before selecting observer'
    end
    if id == 'npc_experiment' and (hook.GetTable().OnNPCKilled or {})[hookID] then
        return false, 'NPC experiment hook is already owned by another addon'
    end
    local ok, reason = stopCurrent()
    if not ok then return false, reason end
    if id == 'npc_experiment' then
        counters = {npcKills=0}
        npcHook = function(victim)
            if active == 'npc_experiment' and IsValid(victim) and victim:IsNPC() then
                counters.npcKills = math.min(counters.npcKills + 1, 2147483647)
            end
        end
        local hookOK = pcall(hook.Add, 'OnNPCKilled', hookID, npcHook)
        if not hookOK or (hook.GetTable().OnNPCKilled or {})[hookID] ~= npcHook then
            removeOwnedHook('OnNPCKilled', hookID, npcHook)
            npcHook = nil
            return false, 'could not install NPC experiment hook'
        end
    end
    active = id
    return true, 'active profile: '..id
end

local function nextOrder()
    issuedOrder = issuedOrder + 1
    return issuedOrder
end

local function accept(id, order)
    if order < acceptedOrder then return false, 'superseded by a later authorized command' end
    -- An authorized no-op is still a new intent and supersedes older requests.
    acceptedOrder = order
    return activate(id)
end

local function ensureCAMI()
    if not CAMI then return false, 'absent' end
    if type(CAMI) ~= 'table' or type(CAMI.RegisterPrivilege) ~= 'function' or type(CAMI.PlayerHasAccess) ~= 'function' then
        return false, 'CAMI unavailable'
    end
    if registeredCAMI ~= CAMI then
        local ok = pcall(CAMI.RegisterPrivilege, {Name=privilege, MinAccess='superadmin', Description='Change the active agent session profile'})
        if not ok then return false, 'CAMI privilege registration failed' end
        registeredCAMI = CAMI
    end
    return true
end

local function fallbackAdmin(ply)
    return game.SinglePlayer() or (type(ply.IsListenServerHost) == 'function' and ply:IsListenServerHost())
        or (type(ply.IsSuperAdmin) == 'function' and ply:IsSuperAdmin())
end

local function command(ply, _, args)
    if stopped then return end
    local id = args[1] or 'status'
    if id == 'status' then
        local status = api.GetStatus()
        tell(ply, 'active='..status.active..' npcKills='..status.npcKills..' observerReady='..tostring(status.observerReady)..' experimentReady='..tostring(status.experimentReady))
        return
    end
    if not validActions[id] then tell(ply, 'use status, none, observer or npc_experiment') return end
    if not IsValid(ply) then local _, message=accept(id,nextOrder()); tell(ply,message); return end
    if not ply:IsPlayer() then return end
    local camiAvailable, why = ensureCAMI()
    if not camiAvailable then
        if why ~= 'absent' then tell(ply,why); return end
        if not fallbackAdmin(ply) then tell(ply,'not permitted'); return end
        local _, message=accept(id,nextOrder()); tell(ply,message)
        return
    end
    local requests = pending[ply]
    if not requests then requests={count=0}; pending[ply]=requests end
    if requests.count >= MAX_PENDING then tell(ply,'too many pending permission checks'); return end
    local request, capturedCAMI, order = {}, CAMI, nextOrder()
    requests[request] = true
    requests.count = requests.count + 1
    local ok, err = pcall(CAMI.PlayerHasAccess, ply, privilege, function(allowed)
        if stopped or not IsValid(ply) or not ply:IsPlayer() or pending[ply] ~= requests
            or not requests[request] then return end
        requests[request] = nil
        requests.count = requests.count - 1
        if CAMI ~= capturedCAMI then return end
        if allowed ~= true then tell(ply, 'not permitted'); return end
        local _, message = accept(id, order)
        tell(ply, message)
    end)
    if not ok then
        if requests[request] then requests[request]=nil; requests.count=requests.count-1 end
        tell(ply,'permission check failed: '..tostring(err))
    elseif requests[request] then
        -- A synchronous provider has already removed its request and needs no timer.
        local scheduled = pcall(timer.Simple, 15, function()
            if pending[ply] == requests and requests[request] then
                requests[request] = nil
                requests.count = requests.count - 1
            end
        end)
        if not scheduled then
            requests[request]=nil; requests.count=requests.count-1
            tell(ply,'could not schedule permission check expiry')
        end
    end
end

function api.Shutdown()
    if stopped then return true end
    local ok, reason = stopCurrent()
    if not ok then return false, reason end
    stopped = true
    removeOwnedHook('PlayerDisconnected', disconnectID, disconnectHook)
    removeOwnedHook('ShutDown', disconnectID, shutdownHook)
    if concommand.GetTable()[commandName] == command then concommand.Remove(commandName) end
    return true
end

disconnectHook = function(ply) pending[ply]=nil end
shutdownHook = function()
    local ok, reason = api.Shutdown()
    if not ok then ErrorNoHalt('[Agent Session] '..tostring(reason)..'\n') end
end
local disconnectOK = pcall(hook.Add, 'PlayerDisconnected', disconnectID, disconnectHook)
local shutdownOK = pcall(hook.Add, 'ShutDown', disconnectID, shutdownHook)
local commandOK = pcall(concommand.Add, commandName, command, nil, 'Inspect or select a server session profile.')
if not disconnectOK or not shutdownOK or not commandOK or concommand.GetTable()[commandName] ~= command
    or (hook.GetTable().PlayerDisconnected or {})[disconnectID] ~= disconnectHook
    or (hook.GetTable().ShutDown or {})[disconnectID] ~= shutdownHook then
    stopped = true
    removeOwnedHook('PlayerDisconnected', disconnectID, disconnectHook)
    removeOwnedHook('ShutDown', disconnectID, shutdownHook)
    if concommand.GetTable()[commandName] == command then concommand.Remove(commandName) end
    if AgentSessionProfiles == api then AgentSessionProfiles = nil end
    ErrorNoHalt('[Agent Session] Could not register the session-profile command or lifecycle hooks.\n')
    return
end
-- Register if CAMI already exists; a later-loaded provider is registered on use.
if CAMI then ensureCAMI() end
