SERVER=true
local checks=0
local function check(value,message) checks=checks+1; assert(value,message) end
local hooks,commands,messages,cvarsByName,callbacks={},{},{},{},{}
hook={}
function hook.Add(event,id,fn) hooks[event]=hooks[event] or {}; hooks[event][id]=fn end
function hook.Remove(event,id) if hooks[event] then hooks[event][id]=nil end end
function hook.GetTable() return hooks end
concommand={}
function concommand.Add(name,fn) commands[name]=fn end
function concommand.Remove(name) commands[name]=nil end
function concommand.GetTable() return commands end
local timers={}
timer={Simple=function(_,fn) timers[#timers+1]=fn end}
function IsValid(x) return type(x)=='table' and x.valid==true end
game={SinglePlayer=function() return false end}
function GetConVar(name) return cvarsByName[name] end
cvars={}
function cvars.AddChangeCallback(name,fn,id) callbacks[name]=callbacks[name] or {};callbacks[name][id]=fn end
function cvars.RemoveChangeCallback(name,id) if callbacks[name] then callbacks[name][id]=nil end end
function ErrorNoHalt(s) messages[#messages+1]=s end
local function player(admin)
    return {valid=true,admin=admin,IsPlayer=function() return true end,
        IsListenServerHost=function() return false end,IsSuperAdmin=function(self) return self.admin end,
        ChatPrint=function(_,s) messages[#messages+1]=s end}
end
local function cv(initial)
    local x={value=initial,writes=0}
    function x:GetBool() return self.value end
    function x:SetBool(v)
        self.writes=self.writes+1
        local old=self.value;self.value=v
        if old~=v then for _,fn in pairs(callbacks.noclip_ghost_enabled or {}) do fn('noclip_ghost_enabled',tostring(old),tostring(v)) end end
    end
    return x
end
local function invoke(ply,id) assert(commands.agent_session_profile)(ply,'agent_session_profile',{id}) end
local src=assert(io.open(arg[1]..'/lua/autorun/server/agent_session_profiles.lua','rb'))
local code=src:read('*a');src:close()
assert(loadstring(code))()
local api=AgentSessionProfiles
check(api.GetStatus().active=='none','no automatic activation')
check(not hooks.OnNPCKilled,'no initial experiment hook')
local ordinary,admin=player(false),player(true)
invoke(ordinary,'npc_experiment')
check(api.GetStatus().active=='none','ordinary player denied without CAMI')
invoke(admin,'npc_experiment')
check(api.GetStatus().active=='npc_experiment','fallback admin activation')
check(api.GetStatus().experimentReady,'experiment hook is installed')
local target={valid=true,IsNPC=function() return true end}
local other={valid=true,IsNPC=function() return false end}
hooks.OnNPCKilled['AgentSessionProfiles.NPCTest'](target)
hooks.OnNPCKilled['AgentSessionProfiles.NPCTest'](other)
check(api.GetStatus().npcKills==1,'counts only NPC kill events')
local copy=api.GetStatus();copy.active='observer';copy.npcKills=999
check(api.GetStatus().active=='npc_experiment' and api.GetStatus().npcKills==1,'status is copied')
invoke(admin,'observer')
check(api.GetStatus().active=='npc_experiment','missing dependency leaves previous profile intact')
DashReality={GhostStates={}}
local ghost=cv(false); cvarsByName.noclip_ghost_enabled=ghost
invoke(admin,'observer')
check(api.GetStatus().active=='npc_experiment' and not ghost.value,'disabled Ghost leaves experiment unchanged')
ghost.value=true; invoke(admin,'observer')
check(api.GetStatus().active=='observer' and api.GetStatus().observerReady,'observer checks pre-enabled Ghost')
check(not hooks.OnNPCKilled['AgentSessionProfiles.NPCTest'],'old experiment hook removed')
ghost.value=false
check(not api.GetStatus().observerReady,'status reflects later Ghost disable')
invoke(admin,'none')
check(not ghost.value and api.GetStatus().active=='none','observer cleanup does not change Ghost')
ghost.value=true; invoke(admin,'observer'); invoke(admin,'none')
check(ghost.value,'preexisting Ghost enable preserved')

-- CAMI queries may complete asynchronously. Newer actions and lifecycle changes
-- invalidate stale callbacks, including callbacks for disconnected players.
local calls,registered={},0
CAMI={RegisterPrivilege=function(def) registered=registered+1;check(def.MinAccess=='superadmin','CAMI default privilege') end,
    PlayerHasAccess=function(p,name,callback) calls[#calls+1]={ply=p,callback=callback,name=name} end}
invoke(ordinary,'npc_experiment')
check(api.GetStatus().active=='none' and #calls==1,'CAMI waits for callback')
calls[1].callback(true)
check(api.GetStatus().active=='npc_experiment','CAMI may explicitly grant non-admin')
invoke(ordinary,'observer'); calls[2].callback(false)
check(api.GetStatus().active=='npc_experiment','CAMI denial preserves profile')
invoke(ordinary,'observer'); invoke(ordinary,'none')
calls[4].callback(true)
check(api.GetStatus().active=='none','latest callback applies')
calls[3].callback(true)
check(api.GetStatus().active=='none','older authorized callback ignored')
invoke(ordinary,'npc_experiment'); invoke(nil,'observer'); calls[5].callback(true)
check(api.GetStatus().active=='observer','console transition invalidates pending callback')
invoke(ordinary,'npc_experiment'); hooks.PlayerDisconnected['AgentSessionProfiles.Pending'](ordinary)
calls[6].callback(true)
check(api.GetStatus().active=='observer','disconnect invalidates pending callback')
check(registered==1,'CAMI privilege registered only once')
invoke(ordinary,'npc_experiment'); local oldCAMI=CAMI;CAMI={};calls[7].callback(true)
check(api.GetStatus().active=='observer','replaced CAMI invalidates pending callback')
CAMI=oldCAMI
invoke(ordinary,'npc_experiment');calls[8].callback('yes')
check(api.GetStatus().active=='observer','non-boolean CAMI approval denied')
ordinary.valid=true; invoke(ordinary,'npc_experiment'); check(#calls==9,'later request queued')
check(api.Shutdown(),'clean shutdown')
calls[9].callback(true)
check(api.GetStatus().active=='none' and ghost.value,'shutdown preserves Ghost and cancels callback')
check(commands.agent_session_profile==nil,'shutdown removes command')

-- An authorized no-op supersedes older pending approvals, while an unapproved
-- or denied request, even from the same player, cannot supersede one.
AgentSessionProfiles=nil;CAMI=nil
assert(loadstring(code))();api=AgentSessionProfiles
local queue={}
CAMI={RegisterPrivilege=function() end,PlayerHasAccess=function(_,_,cb) queue[#queue+1]=cb end}
invoke(ordinary,'npc_experiment')
invoke(nil,'none')
queue[1](true)
check(api.GetStatus().active=='none','console no-op supersedes older approval')
invoke(ordinary,'npc_experiment')
invoke(ordinary,'none')
queue[3](false)
queue[2](true)
check(api.GetStatus().active=='npc_experiment','denied newer request does not cancel earlier authorized request')
invoke(nil,'none')
invoke(ordinary,'npc_experiment')
invoke(ordinary,'none')
queue[5](false)
queue[4](true)
check(api.GetStatus().active=='npc_experiment','same-player denied no-op cannot invalidate allowed request')
invoke(nil,'none')
local seq=#queue
invoke(ordinary,'npc_experiment')
invoke(admin,'none')
queue[seq+2](true)
queue[seq+1](true)
check(api.GetStatus().active=='none','CAMI-approved no-op supersedes another player pending approval')
seq=#queue
invoke(ordinary,'npc_experiment')
invoke(admin,'none')
queue[seq+2](false)
queue[seq+1](true)
check(api.GetStatus().active=='npc_experiment','another player denied cannot cancel pending authorized request')
invoke(nil,'none')
local before=#queue
for i=1,16 do invoke(ordinary,'npc_experiment') end
invoke(ordinary,'observer')
check(#queue==before+16,'pending permission checks capped')
for _,fn in ipairs(timers) do fn() end
queue[before+1](true)
check(api.GetStatus().active=='none','expired approval is ignored')
invoke(ordinary,'npc_experiment')
check(#queue==before+17,'timed-out permission checks release capacity')
queue[#queue](true)
check(api.GetStatus().active=='npc_experiment','new approval works after timeout')
check(api.Shutdown(),'async race fixture cleanup')

-- A partial CAMI installation must not fall back to broad admin access.
AgentSessionProfiles=nil
CAMI={PlayerHasAccess=function() end}
assert(loadstring(code))()
api=AgentSessionProfiles
invoke(admin,'npc_experiment')
check(api.GetStatus().active=='none','partial CAMI fails closed')
check(api.Shutdown(),'partial CAMI cleanup')

-- Hot reload invokes the previous manager's cleanup without changing Ghost.
AgentSessionProfiles=nil;CAMI=nil
assert(loadstring(code))();api=AgentSessionProfiles
ghost.value=true;cvarsByName.noclip_ghost_enabled=ghost
invoke(admin,'observer')
assert(loadstring(code))()
check(AgentSessionProfiles~=api and AgentSessionProfiles.GetStatus().active=='none','reload removes old profile')
check(ghost.value,'reload does not alter Ghost')
check(AgentSessionProfiles.Shutdown(),'reloaded manager shuts down')
check(ghost.writes==0,'profiles never write the shared Ghost setting')

-- A synchronous CAMI decision must not schedule a redundant expiry timer.
AgentSessionProfiles=nil
CAMI={RegisterPrivilege=function() end,PlayerHasAccess=function(_,_,done) done(true) end}
assert(loadstring(code))();api=AgentSessionProfiles
local priorTimers=#timers
invoke(ordinary,'npc_experiment')
check(api.GetStatus().active=='npc_experiment','synchronous CAMI grants action')
check(#timers==priorTimers,'synchronous CAMI does not schedule expiry')
check(api.Shutdown(),'synchronous CAMI fixture cleanup')

-- Shutdown must not remove a later replacement owned by another addon.
AgentSessionProfiles=nil;CAMI=nil
assert(loadstring(code))();api=AgentSessionProfiles
invoke(admin,'npc_experiment')
local foreignCommand=function() end
local foreignNpcHook=function() end
local foreignDisconnect=function() end
local ownedCommand=commands.agent_session_profile
commands.agent_session_profile=foreignCommand
hooks.OnNPCKilled['AgentSessionProfiles.NPCTest']=foreignNpcHook
hooks.PlayerDisconnected['AgentSessionProfiles.Pending']=foreignDisconnect
check(not api.GetStatus().experimentReady,'status detects replacement of experiment hook')
ownedCommand(admin,'agent_session_profile',{'npc_experiment'})
check(hooks.OnNPCKilled['AgentSessionProfiles.NPCTest']==foreignNpcHook,'reselecting active profile does not overwrite foreign hook')
check(api.Shutdown(),'shutdown with foreign replacements')
check(commands.agent_session_profile==foreignCommand,'foreign replacement command preserved')
check(hooks.OnNPCKilled['AgentSessionProfiles.NPCTest']==foreignNpcHook,'foreign replacement NPC hook preserved')
check(hooks.PlayerDisconnected['AgentSessionProfiles.Pending']==foreignDisconnect,'foreign lifecycle hook preserved')
assert(loadstring(code))()
check(AgentSessionProfiles==api,'reload refuses conflicting reserved command')
commands.agent_session_profile=nil
hooks.OnNPCKilled['AgentSessionProfiles.NPCTest']=nil
hooks.PlayerDisconnected['AgentSessionProfiles.Pending']=nil

-- Engine command collisions can make concommand.Add silently fail even when
-- concommand.GetTable had no Lua command at preflight.
AgentSessionProfiles=nil;CAMI=nil
local oldAdd=concommand.Add
concommand.Add=function() end
assert(loadstring(code))()
check(AgentSessionProfiles==nil,'silent command-registration failure leaves no manager')
check(not (hooks.PlayerDisconnected or {})['AgentSessionProfiles.Pending'],'failed command registration removes owned disconnect hook')
check(not (hooks.ShutDown or {})['AgentSessionProfiles.Pending'],'failed command registration removes owned shutdown hook')
check(commands.agent_session_profile==nil,'failed registration has no command')
concommand.Add=oldAdd

-- A rejected experiment hook cannot leave a falsely active profile.
AgentSessionProfiles=nil
assert(loadstring(code))();api=AgentSessionProfiles
local oldHookAdd=hook.Add
hook.Add=function(event,id,fn) if event~='OnNPCKilled' then oldHookAdd(event,id,fn) end end
invoke(admin,'npc_experiment')
check(api.GetStatus().active=='none' and not api.GetStatus().experimentReady,'silent experiment hook failure stays inactive')
hook.Add=oldHookAdd
check(api.Shutdown(),'failed experiment hook fixture cleanup')
print('PASS: '..checks..' session profile contracts')
