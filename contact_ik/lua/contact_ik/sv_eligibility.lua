-- Presentation hints only; native Use, pickup physics and NPC goals stay native.
local K=ContactIK
if K.StopPlayerInput then K.StopPlayerInput() end
local published=setmetatable({}, {__mode="k"})
local inputs=setmetatable({}, {__mode="k"})
local relevant={[IN_USE]=true,[IN_ATTACK]=true,[IN_ATTACK2]=true,[IN_RELOAD]=true}
local carries=K.NativeCarries or setmetatable({}, {__mode="k"})
K.NativeCarries=carries
local function publishCarry(ply,ent)
    if not IsValid(ply) then return end
    ent=IsValid(ent) and ent or NULL
    if ply:GetNW2Entity("ContactIK.NativeCarry")~=ent then ply:SetNW2Entity("ContactIK.NativeCarry",ent) end
    carries[ply]=ent~=NULL and ent or nil
end
local function reconcileCarry(ply)
    local ent=carries[ply] or ply:GetNW2Entity("ContactIK.NativeCarry")
    local controller=ply:GetEntityInUse()
    if not ply:Alive() or not IsValid(controller) or controller:GetClass()~="player_pickup"
        or not IsValid(ent) or not ent:IsPlayerHolding() then ent=NULL end
    publishCarry(ply,ent)
end
local function publishInput(ply,key,pressed)
    if not IsValid(ply) then return end
    local function down(button)if button==key then return pressed end return ply:KeyDown(button)end
    local use=ply:Alive() and down(IN_USE) or false
    local busy=ply:Alive() and (down(IN_ATTACK) or down(IN_ATTACK2) or down(IN_RELOAD)) or false
    local previous=inputs[ply] or {}
    if previous.use~=use then ply:SetNW2Bool("ContactIK.UseHeld",use) end
    if previous.busy~=busy then ply:SetNW2Bool("ContactIK.PlayerBusy",busy) end
    inputs[ply]={use=use,busy=busy}
end
hook.Add("KeyPress","ContactIK.PlayerInput",function(ply,key)if relevant[key] then publishInput(ply,key,true) end end)
hook.Add("KeyRelease","ContactIK.PlayerInput",function(ply,key)if relevant[key] then publishInput(ply,key,false) end end)
hook.Add("PlayerDeath","ContactIK.PlayerInput",function(ply)
    inputs[ply]=nil ply:SetNW2Bool("ContactIK.UseHeld",false) ply:SetNW2Bool("ContactIK.PlayerBusy",false)
    publishCarry(ply,NULL)
end)
hook.Add("PlayerSpawn","ContactIK.PlayerInput",function(ply)publishInput(ply)publishCarry(ply,NULL)end)
-- Post-pickup notifications observe successful +use only. Never call pickup
-- permission hooks or infer a holder from a nearby/aimed-at entity.
hook.Add("OnPlayerPhysicsPickup","ContactIK.NativeCarry",function(ply,ent)publishCarry(ply,ent)end)
hook.Add("OnPlayerPhysicsDrop","ContactIK.NativeCarry",function(ply,ent)
    if carries[ply]==ent then publishCarry(ply,NULL) end
end)
hook.Add("EntityRemoved","ContactIK.NativeCarry",function(ent)
    for ply,held in pairs(carries) do if held==ent then publishCarry(ply,NULL) end end
end)
function K.StopPlayerInput()
    for _,event in ipairs({"KeyPress","KeyRelease","PlayerDeath","PlayerSpawn"}) do hook.Remove(event,"ContactIK.PlayerInput") end
    for _,event in ipairs({"OnPlayerPhysicsPickup","OnPlayerPhysicsDrop","EntityRemoved"}) do hook.Remove(event,"ContactIK.NativeCarry") end
    for ply in pairs(carries) do if IsValid(ply) then ply:SetNW2Entity("ContactIK.NativeCarry",NULL) end end
    -- The private weak cache survives source refresh, but public hints clear
    -- on shutdown. The replacement validates cached native controllers.
    for ply in pairs(inputs) do if IsValid(ply) then ply:SetNW2Bool("ContactIK.UseHeld",false) ply:SetNW2Bool("ContactIK.PlayerBusy",false) end end
    inputs=setmetatable({}, {__mode="k"})
end
for _,ply in ipairs(player.GetAll()) do publishInput(ply)reconcileCarry(ply) end
function K.NPCPresentationBlocked(ent)
    if not IsValid(ent) or not ent:IsNPC() or ent:IsScripted() or ent:Health()<=0 then return true end
    local state=ent:GetNPCState()
    return state==NPC_STATE_SCRIPT or state==NPC_STATE_DEAD or state==NPC_STATE_COMBAT or IsValid(ent:GetActiveWeapon())
end
function K.RefreshNPCEligibility()
    -- Reconcile missed key hooks (another addon can short-circuit a hook).
    -- Cached values publish only changes; no extra per-frame player polling.
    for _,ply in ipairs(player.GetAll()) do publishInput(ply)reconcileCarry(ply) end
    for _,ent in ipairs(ents.FindByClass("npc_*")) do
        if ent:IsNPC() and not ent:IsScripted() then
            local rig=K.Describe(ent)
            if rig.arms[1] or rig.arms[2] then
                local blocked=K.NPCPresentationBlocked(ent)
                if published[ent]~=blocked then ent:SetNW2Bool("ContactIK.NPCBlocked",blocked) end
                published[ent]=blocked
            end
        end
    end
end
function K.Shutdown()
    K.StopPlayerInput()
    timer.Remove("ContactIK.NPCEligibility")
    for ent in pairs(published) do if IsValid(ent) then ent:SetNW2Bool("ContactIK.NPCBlocked",true) end end
    published=setmetatable({}, {__mode="k"})
end
timer.Create("ContactIK.NPCEligibility",.5,0,K.RefreshNPCEligibility)
K.RefreshNPCEligibility()
