-- Isolated cross-addon contract: load the actual session candidate, actual
-- Agent Bridge capability implementation and actual GTerm package declaration.
-- The engine APIs below are test doubles; no game process is touched.
SERVER=true
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local hooks,commands={},{}
local writes={file=0,convar=0,console=0,group=0,model=0}
hook={}
function hook.Add(event,id,fn) hooks[event]=hooks[event] or {};hooks[event][id]=fn end
function hook.Remove(event,id) if hooks[event] then hooks[event][id]=nil end end
function hook.GetTable() return hooks end
concommand={}
function concommand.Add(name,fn) commands[name]=fn end
function concommand.Remove(name) commands[name]=nil end
function concommand.GetTable() return commands end
timer={Simple=function() error('unexpected timer created by console profile fixture') end}
game={SinglePlayer=function() return false end}
function IsValid(x) return type(x)=='table' and x.valid==true end
function ErrorNoHalt(msg) error(msg) end
file={Write=function() writes.file=writes.file+1 end}
function RunConsoleCommand() writes.console=writes.console+1 end
local observerPlayer={valid=true,IsPlayer=function() return true end,
    SetUserGroup=function() writes.group=writes.group+1 end,
    SetModel=function() writes.model=writes.model+1 end}
player={GetAll=function() return {observerPlayer} end}
local ghost={enabled=false}
function ghost:GetBool() return self.enabled end
function ghost:SetBool(value) writes.convar=writes.convar+1;self.enabled=value end
function GetConVar(name) if name=='noclip_ghost_enabled' then return ghost end end

assert(loadfile(arg[1]))() -- actual server session-profile candidate
AgentBridge={Version=1}
assert(loadfile(arg[2]))() -- actual Agent Bridge capability implementation
local package=assert(loadfile(arg[3]))() -- actual GTerm tool package declaration
local tool
for _,entry in ipairs(package.tools) do
    if entry.name=='inspect_server_capabilities' then
        check(tool==nil,'capability tool must be unique')
        tool=entry
    end
end
check(tool and tool.realm=='server','package exposes server capability tool')
check(tool.inputSchema.type=='object' and tool.inputSchema.additionalProperties==false,'package accepts an empty bounded input')
local function inspect() return tool.run({}) end
local function assertNoWrites(label)
    check(writes.file==0 and writes.convar==0 and writes.console==0 and writes.group==0 and writes.model==0,label..': unexpected file, convar, command or player write')
end
local function activate(id)
    check(type(commands.agent_session_profile)=='function','session command available')
    commands.agent_session_profile(nil,'agent_session_profile',{id})
end
local first=inspect()
check(first.schema==1,'capability schema')
check(first.session_profile.state=='available' and first.session_profile.active=='none','none profile reported')
check(first.session_profile.npcKills==0 and first.session_profile.observerReady==false and first.session_profile.experimentReady==false,'inactive readiness values preserved as false')
check(first.providers.dash_reality.state=='unavailable','absent Dash provider is unavailable')
assertNoWrites('initial inspection')

activate('npc_experiment')
local result=inspect()
check(result.session_profile.active=='npc_experiment' and result.session_profile.experimentReady==true,'active experiment reported ready')
check(result.session_profile.npcKills==0 and result.session_profile.observerReady==false,'experiment counters and observer state')
local killed=hooks.OnNPCKilled['AgentSessionProfiles.NPCTest']
check(type(killed)=='function','real experiment hook installed')
killed({valid=true,IsNPC=function() return true end,
    SetUserGroup=function() writes.group=writes.group+1 end,
    SetModel=function() writes.model=writes.model+1 end})
killed({valid=true,IsNPC=function() return false end})
result=inspect()
check(result.session_profile.npcKills==1,'real NPC event count crosses the package boundary')
local detached=inspect();detached.session_profile.active='forged';detached.session_profile.npcKills=999
check(inspect().session_profile.active=='npc_experiment' and inspect().session_profile.npcKills==1,'returned data cannot mutate provider state')
assertNoWrites('experiment inspection')

DashReality={GhostStates={},Development={API_VERSION=1,InspectEntity=function() end}}
activate('observer') -- Ghost is disabled, so prior profile must stay active.
result=inspect()
check(result.session_profile.active=='npc_experiment' and result.session_profile.experimentReady==true,'disabled Ghost does not displace experiment')
check(result.providers.dash_reality.state=='available','Dash provider contract detected independently')
ghost.enabled=true -- test fixture simulates the operator's separate action.
activate('observer')
result=inspect()
check(result.session_profile.active=='observer' and result.session_profile.observerReady==true,'enabled observer reported ready')
check(result.session_profile.npcKills==0 and result.session_profile.experimentReady==false,'old experiment removed and count is scoped')
check(not hooks.OnNPCKilled['AgentSessionProfiles.NPCTest'],'experiment hook removed after switch')
ghost.enabled=false -- operator later disables the dependency.
result=inspect()
check(result.session_profile.active=='observer' and result.session_profile.observerReady==false,'false observer readiness survives package response')
assertNoWrites('observer inspection and transitions')

activate('none')
result=inspect()
check(result.session_profile.active=='none' and result.session_profile.observerReady==false and result.session_profile.experimentReady==false,'none reports clean inactive state')
check(AgentSessionProfiles.Shutdown(),'session manager shuts down')
check(commands.agent_session_profile==nil,'owned command removed')
check(not hooks.PlayerDisconnected['AgentSessionProfiles.Pending'] and not hooks.ShutDown['AgentSessionProfiles.Pending'],'owned lifecycle hooks removed')
result=inspect()
check(result.session_profile.active=='none','shutdown status remains bounded')
AgentSessionProfiles=nil
result=inspect()
check(result.session_profile.state=='unknown' and result.session_profile.reason=='provider_not_detected','absence is unknown, not inferred installation state')
assertNoWrites('cleanup and absent-provider inspection')
print('PASS: '..checks..' real-source cross-addon session/bridge contracts')
