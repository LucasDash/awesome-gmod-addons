-- Upper-body presentation only; observes Use input, never consumes it.
local K=ContactIK
if K.StopPassive then K.StopPassive() end
local enabled=CreateClientConVar("contact_ik_enabled","1",true,false,"Automatic environmental hand posing")
local players=CreateClientConVar("contact_ik_players","1",true,false,"Pose compatible player world models")
local requireUse=CreateClientConVar("contact_ik_require_use","1",true,false,"Hold Use (E by default) for player contact; NPCs remain automatic")
local weapons=CreateClientConVar("contact_ik_weapons","1",true,false,"Allow the free hand with weapons while idle")
local nativeCarry=CreateClientConVar("contact_ik_native_carry","1",true,false,"Follow objects held with native Use, without changing pickup physics")
local npcs=CreateClientConVar("contact_ik_npcs","1",true,false,"Pose compatible native humanoid NPCs")
local proximity=CreateClientConVar("contact_ik_distance","10",true,false,"Contact proximity in model-scaled Source units",2,24)
local range=CreateClientConVar("contact_ik_range","900",true,false,"Maximum entity evaluation distance",128,2000)
local fade=CreateClientConVar("contact_ik_fade_time","0.45",true,false,"Passive contact fade-out duration",.15,1.5)
local settling=CreateClientConVar("contact_ik_finger_settle","0.25",true,false,"Subtle passive finger settling strength",0,1)
local speedBrace=CreateClientConVar("contact_ik_speed_brace","1",true,false,"Respond more firmly when approaching a surface")
local transition=CreateClientConVar("contact_ik_transition_time","0.18",true,false,"Passive pose transition time",.08,.4)
-- One settings/relative-speed calculation per composed subject, not per joint.
function K.PassiveResponse(ent,contacts)
    local approach=0 local velocity=ent:GetVelocity()
    if speedBrace:GetBool() then
        for _,c in pairs(contacts) do
            local other=IsValid(c.entity) and not c.entity:IsWorld() and c.entity:GetVelocity() or Vector()
            approach=math.max(approach,-(velocity-other):Dot(c.normal))
        end
    end
    local firmness=math.Clamp(approach/160,0,1)
    return {rate=(2.16/math.Clamp(transition:GetFloat(),.08,.4))*(1+firmness*.65),
        firmness=firmness,settle=math.Clamp(settling:GetFloat(),0,1)*.2}
end
local grace=.12
local owner={}
local active=setmetatable({}, {__mode="k"})
local candidates={} local nextDiscovery,nextTick=0,0 local cursor=1
K.PassiveReports=setmetatable({}, {__mode="k"})
K.PassiveStats={entities=0,traces=0,updates=0}

function K.NativeCarriedEntity(ent)
    if nativeCarry:GetBool() and ent:IsPlayer() and ent.GetNW2Entity then
        local held=ent:GetNW2Entity("ContactIK.NativeCarry")
        if IsValid(held) and not held:IsDormant() then return held end
    end
end
function K.PassiveInputRequested(ent)
    if not ent:IsPlayer() or not requireUse:GetBool() then return true end
    if K.NativeCarriedEntity(ent) then return true end
    local lease=K.PoseLeases and K.PoseLeases[ent]
    -- Existing API-1 consumers explicitly opting into a free arm remain in
    -- control of their pose; the default Use gate governs standalone players.
    if lease and lease.owner and lease.passiveBlocked==false then return true end
    if ent==LocalPlayer() then return ent:KeyDown(IN_USE) end
    return ent:GetNW2Bool("ContactIK.UseHeld",false)
end
function K.PassiveEligibility(ent,fading)
    if not IsValid(ent) or ent:IsDormant() or ent:GetNoDraw() then return end
    local isPlayer=ent:IsPlayer()
    if isPlayer then
        if not players:GetBool() or not ent:Alive() or ent:InVehicle() then return end
        if not fading and not K.PassiveInputRequested(ent) then return end
    elseif not npcs:GetBool() or not ent:IsNPC() or ent:IsScripted() or ent:Health()<=0 then return end
    -- Native NPC state is server-only. A server-owned presentation hint keeps
    -- client posing out of scripted sequences, combat and occupied weapon arms.
    if not isPlayer and ent:GetNW2Bool("ContactIK.NPCBlocked",true) then return end
    if ent.IsProne and ent:IsProne() then return end
    local lease=K.PoseLeases and K.PoseLeases[ent]
    if lease and lease.owner and lease.passiveBlocked then return end
    local rig=K.Describe(ent)
    if not rig.arms[1] and not rig.arms[2] then return end
    local allowed={rig.arms[1],rig.arms[2]}
    local weapon=ent.GetActiveWeapon and ent:GetActiveWeapon()
    -- Native carrying holsters/hides the weapon. Visible weapons and explicit
    -- pose owners keep the normal arbitration policy.
    local carrying=K.NativeCarriedEntity(ent)
    if IsValid(weapon) and not (carrying and weapon:GetNoDraw()) then
        local class=weapon:GetClass()
        if class~="weapon_functional_hands" and class~="weapon_fists" and class~="gmod_camera" then
            if class=="gmod_tool" or class=="weapon_physgun" or class=="weapon_physcannon" then allowed[2]=false
            elseif weapons:GetBool() then
                local hold=weapon.GetHoldType and weapon:GetHoldType() or ""
                if hold=="duel" or hold=="melee2" then return end
                allowed[2]=false
            else return end
        end
        if weapon.ContactIKArms==false then return end
        if istable(weapon.ContactIKArms) then
            for index=1,2 do allowed[index]=rig.arms[index] and weapon.ContactIKArms[index]==true end
        end
        allowed.preserveBody=not allowed[1] or not allowed[2]
    end
    if isPlayer and (not IsValid(weapon) or weapon:GetClass()~="weapon_functional_hands") then
        local busy=ent==LocalPlayer() and (ent:KeyDown(IN_ATTACK) or ent:KeyDown(IN_ATTACK2) or ent:KeyDown(IN_RELOAD))
            or ent~=LocalPlayer() and ent:GetNW2Bool("ContactIK.PlayerBusy",false)
        if busy or IsValid(weapon) and not (carrying and weapon:GetNoDraw()) and ((weapon.GetReloading and weapon:GetReloading()==true)
            or (weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire()>CurTime()+.15)) then return end
    end
    if not allowed[1] and not allowed[2] then return end
    return allowed
end
local function trace(data,hull)
    K.PassiveStats.traces=K.PassiveStats.traces+1
    return hull and util.TraceHull(data) or util.TraceLine(data)
end
local function filter(ent)
    local list={ent}
    for _,child in ipairs(ent:GetChildren()) do list[#list+1]=child end
    local w=ent.GetActiveWeapon and ent:GetActiveWeapon()
    if IsValid(w) then list[#list+1]=w end
    return list
end
local function anchor(ent,c)
    if IsValid(c.entity) and not c.entity:IsWorld() then
        c.localPoint=c.entity:WorldToLocal(c.point)
        c.localNormal=c.entity:WorldToLocal(c.point+c.normal)-c.localPoint
        c.localTangent=c.entity:WorldToLocal(c.point+c.tangent)-c.localPoint
    end
    c.model=ent:GetModel() c.scale=ent:GetModelScale()
    return c
end
local function resolve(ent,c)
    if c.model~=ent:GetModel() or c.scale~=ent:GetModelScale() then return end
    if c.localPoint then
        if not IsValid(c.entity) or c.entity:IsDormant() then return end
        local p=c.entity:LocalToWorld(c.localPoint)
        c.point=p c.normal=(c.entity:LocalToWorld(c.localPoint+c.localNormal)-p):GetNormalized()
        c.tangent=(c.entity:LocalToWorld(c.localPoint+c.localTangent)-p):GetNormalized()
    end
    return c
end
local function retireCarry(ent,c)
    if c.role=="carry" and c.entity~=NULL and K.NativeCarriedEntity(ent)~=c.entity then
        -- Freeze the last visible point on release instead of chasing a thrown
        -- or removed prop during the normal fade-out.
        c.localPoint,c.localNormal,c.localTangent=nil,nil,nil
        c.entity=NULL c.lostAt=c.lostAt or CurTime()
    end
end
function K.FindNativeCarryContacts(ent,held,allowed,previous)
    local contacts={} local scale=ent:GetModelScale() local ignored=filter(ent)
    local center=held:WorldSpaceCenter() local radius=held:BoundingRadius()
    for index=1,2 do
        local a=allowed[index] and K.SensingArm(ent,index)
        if a then
            local prior=previous and previous[index]
            if prior and prior.entity==held and prior.role=="carry" and prior.targetModel==held:GetModel()
                and prior.targetScale==held:GetModelScale() then prior=resolve(ent,prior) else prior=nil end
            local endpoints={}
            if prior then endpoints[#endpoints+1]=prior.point-prior.normal*2*scale end
            local nearest=held:NearestPoint(a.root)
            endpoints[#endpoints+1]=nearest+(nearest-a.root):GetNormalized()*(radius*2+4*scale)
            endpoints[#endpoints+1]=center
            for attempt,endpoint in ipairs(endpoints) do
                local ray=trace({start=a.root,endpos=endpoint,filter=ignored,mask=MASK_SOLID},false)
                if ray.Hit and not ray.StartSolid and ray.Entity==held then
                    -- The first ray validates an existing planted point. Hitting
                    -- another facet of the SAME held prop does not move that
                    -- point or rotate the wrist onto the new facet. Replan when
                    -- the planted face turns behind the shoulder or is blocked.
                    local planted=prior and attempt==1 and prior.normal:Dot((a.root-prior.point):GetNormalized())>-.15
                    if planted then
                        ray.HitPos,ray.HitNormal=prior.point,prior.normal
                    end
                    local tangent=planted and prior.tangent or K.SurfaceTangent(ray.HitNormal,ent:GetForward())
                    local wrist=K.TargetWrist(ent,index,ray.HitPos,ray.HitNormal,tangent)
                    local distance=a.root:Distance(wrist)
                    -- Native carry distance is not authored arm length. Use a
                    -- bounded best-reach pose rather than changing that distance
                    -- or stretching a limb to manufacture exact contact.
                    local align=K.CarryAlignmentAvailable and K.CarryAlignmentAvailable(held)
                    if distance<=a.reach+((align or not allowed.preserveBody)and 32*scale or 0) and distance>=a.minimum then
                        contacts[index]=anchor(ent,{arm=index,point=ray.HitPos,normal=ray.HitNormal,tangent=tangent,
                            entity=held,role="carry",score=distance,weight=1,collision=true,passive=true,
                            preserveBody=allowed.preserveBody,bodyReach=16,bodyLean=35,
                            targetModel=held:GetModel(),targetScale=held:GetModelScale()})
                        if planted then
                            contacts[index].localPoint,contacts[index].localNormal,contacts[index].localTangent=
                                prior.localPoint,prior.localNormal,prior.localTangent
                        end
                        break
                    end
                end
            end
        end
    end
    -- A can should not attract two overlapping palms. Retain the existing hand
    -- when both can reach a small surface; broad props can accept both hands.
    local priorHands=0
    for _,c in pairs(previous or {})do
        if c.entity==held and c.role=="carry" and K.PassiveContactWeight(c)>.15 then priorHands=priorHands+1 end
    end
    local separation=(priorHands==2 and 6 or 12)*scale
    if contacts[1] and contacts[2] and contacts[1].point:Distance(contacts[2].point)<separation then
        local keep=contacts[1].score<=contacts[2].score and 1 or 2
        for index=1,2 do
            local prior=previous and previous[index]
            if prior and prior.entity==held and prior.role=="carry" and K.PassiveContactWeight(prior)>.15 then keep=index break end
        end
        contacts[3-keep]=nil
    end
    return contacts
end
-- Diagnostic entry also used by the normal controller; no synthetic contacts.
function K.FindPassiveContacts(ent,allowed,previous)
    local scale=ent:GetModelScale() local mins,maxs=ent:GetCollisionBounds()
    local pos=ent:GetPos()
    local arms={} local low,high=pos.z+maxs.z,pos.z+mins.z
    for index=1,2 do
        if allowed[index] then
            local a=K.SensingArm(ent,index) arms[index]=a
            if a then low=math.min(low,a.root.z-a.reach*.9) high=math.max(high,a.root.z+a.reach*.5) end
        end
    end
    low=math.max(low,pos.z+mins.z+2*scale) high=math.min(high,pos.z+maxs.z)
    local center=pos+Vector((mins.x+maxs.x)*.5,(mins.y+maxs.y)*.5,0) center.z=(low+high)*.5
    local half=Vector(math.max((maxs.x-mins.x)*.5-1,1),math.max((maxs.y-mins.y)*.5-1,1),math.max((high-low)*.5,1))
    local forward=ent:GetForward() forward.z=0 forward:Normalize()
    local right=ent:GetRight() right.z=0 right:Normalize()
    local dirs={{direction=forward,role="front"},{direction=-right,role="left",arm=1},{direction=right,role="right",arm=2},{direction=Vector(0,0,1),role="overhead"}}
    local contacts={} local ignored=filter(ent)
    local gap=math.Clamp(proximity:GetFloat(),2,24)*scale
    local function consider(index,ray,role,approach)
        local a=arms[index]
        if not a or not ray.Hit or ray.StartSolid then return end
        local tangent=K.SurfaceTangent(ray.HitNormal,approach or forward)
        local wrist=K.TargetWrist(ent,index,ray.HitPos,ray.HitNormal,tangent)
        local reach=a.root:Distance(wrist)
        if reach>a.reach+4*scale or reach<a.minimum then return end
        local prior=previous and previous[index]
        -- Keep a planted palm through small resampling/idle-animation changes.
        -- A newly traced point must still agree with its plane and be reachable.
        if prior and prior.entity==ray.Entity and prior.role==role and
            prior.normal:Dot(ray.HitNormal)>.98 and prior.point:Distance(ray.HitPos)<6*scale and
            math.abs((prior.point-ray.HitPos):Dot(ray.HitNormal))<.5*scale then
            local held=K.TargetWrist(ent,index,prior.point,prior.normal,prior.tangent)
            if a.root:Distance(held)<=a.reach+4*scale then
                ray.HitPos=prior.point ray.HitNormal=prior.normal
                tangent=prior.tangent reach=a.root:Distance(held)
            end
        end
        local score=reach+(role=="ledge" and -9*scale or role=="front" and 0 or 2*scale)
        if prior and prior.entity==ray.Entity and prior.role==role then score=score-5*scale end
        if not contacts[index] or score<contacts[index].score then
            contacts[index]=anchor(ent,{arm=index,point=ray.HitPos,normal=ray.HitNormal,tangent=tangent,
                entity=ray.Entity,role=role,score=score,weight=1,collision=true,passive=true,preserveBody=allowed.preserveBody})
        end
    end
    for _,d in ipairs(dirs) do
        local start=center local extent=half
        if d.role=="overhead" then start=pos+Vector((mins.x+maxs.x)*.5,(mins.y+maxs.y)*.5,maxs.z-1) extent=Vector(half.x,half.y,.5) end
        local distance=gap+(previous and next(previous) and 4*scale or 0)
        local broad=trace({start=start,endpos=start+d.direction*distance,mins=-extent,maxs=extent,filter=ignored,mask=MASK_SOLID},true)
        if broad.Hit and not broad.StartSolid and broad.HitNormal:Dot(-d.direction)>.35 then
            for index=1,2 do
                if allowed[index] and (not d.arm or d.arm==index) then
                    local a=arms[index]
                    if a then
                        local heights=d.role=="overhead" and {0} or {0,-a.reach*.7,a.reach*.3}
                        for _,height in ipairs(heights) do
                            local endpoint=a.root+d.direction*(a.reach+5*scale)+Vector(0,0,height)
                            if d.role=="overhead" then endpoint=endpoint+right*(index==1 and -3 or 3)*scale end
                            local ray=trace({start=a.root,endpos=endpoint,filter=ignored,mask=MASK_SHOT},false)
                            if ray.HitNormal:Dot(-d.direction)>.35 then consider(index,ray,d.role,forward) end
                        end
                    end
                end
            end
        end
    end
    -- A shoulder ray can pass straight through an opening. Sample upward-facing
    -- support beside the hull, in each hand's reachable vertical band instead.
    for index=1,2 do
        local a=arms[index]
        if a then
            for _,direction in ipairs({forward,right*(index==1 and -1 or 1)}) do
                local edge=math.abs(direction.x)*(maxs.x-mins.x)*.5+math.abs(direction.y)*(maxs.y-mins.y)*.5
                local previousInset
                for _,inset in ipairs({2,5,8}) do
                    local distance=math.min(inset*scale,gap)
                    if distance~=previousInset then
                        previousInset=distance
                        local horizontal=pos+direction*(edge+distance)
                        local lateral=right*((a.root-pos):Dot(right))
                        if direction:Dot(forward)>.9 then horizontal=horizontal+lateral end
                        local ray=trace({start=Vector(horizontal.x,horizontal.y,a.root.z+a.reach*.75),
                            endpos=Vector(horizontal.x,horizontal.y,a.root.z-a.reach),filter=ignored,mask=MASK_SOLID},false)
                        if ray.HitNormal.z>.6 then consider(index,ray,"ledge",direction) end
                    end
                end
            end
        end
    end
    return contacts
end
function K.PassiveContactWeight(c,now)
    if not c.lostAt then return 1 end
    local t=math.Clamp(((now or CurTime())-c.lostAt-grace)/math.Clamp(fade:GetFloat(),.15,1.5),0,1)
    return 1-t*t*(3-2*t)
end
local function reader(ent)
    local state=active[ent]
    if not state or not enabled:GetBool() or not IsValid(LocalPlayer()) or
        ent:GetPos():DistToSqr(LocalPlayer():GetPos())>math.Clamp(range:GetFloat(),128,2000)^2 then return end
    local allowed=K.PassiveEligibility(ent,true) if not allowed then return end
    local requested=K.PassiveInputRequested(ent)
    local result={}
    for index,c in pairs(state.contacts) do
        if allowed[index] then
            retireCarry(ent,c)
            c=resolve(ent,c)
            if c then
                if c.role=="carry" and c.entity~=NULL and K.CarryAlignedPoint then c.point=K.CarryAlignedPoint(c.entity,c.point)end
                if not requested then c.lostAt=c.lostAt or CurTime() end
                c.weight=K.PassiveContactWeight(c)
                c.preserveBody=allowed.preserveBody or c.role=="carry" and c.entity~=NULL
                    and K.CarryAlignmentAvailable and K.CarryAlignmentAvailable(c.entity) or nil
                result[index]=c
            end
        end
    end
    return next(result) and result or nil
end
local function release(ent)
    K.ReleasePassive(ent,owner) active[ent],K.PassiveReports[ent]=nil,nil
end
function K.StopPassive()
    hook.Remove("Think","ContactIK.Passive")
    for ent in pairs(active) do release(ent) end
    if K.StopCarryAlignment then K.StopCarryAlignment(true) end
    candidates={}
end
local function update(ent)
    local allowed=K.PassiveEligibility(ent,true) local lp=LocalPlayer()
    if not allowed or not IsValid(lp) or ent:GetPos():DistToSqr(lp:GetPos())>math.Clamp(range:GetFloat(),128,2000)^2 then release(ent) return end
    local requested=K.PassiveInputRequested(ent)
    if not requested and not active[ent] then return end
    local state=active[ent] or {contacts={}}
    local held=K.NativeCarriedEntity(ent)
    local contacts={} local now=CurTime()
    if requested then
        contacts=held and K.FindNativeCarryContacts(ent,held,allowed,state.contacts)
            or K.FindPassiveContacts(ent,allowed,state.contacts)
    end
    for index,old in pairs(state.contacts) do
        retireCarry(ent,old)
        if not contacts[index] and allowed[index] and resolve(ent,old) then
            old.lostAt=old.lostAt or now old.weight=K.PassiveContactWeight(old,now)
            if now-old.lostAt<grace+math.Clamp(fade:GetFloat(),.15,1.5)+.2 then contacts[index]=old end
        end
    end
    if held and K.UpdateCarryAlignment then K.PassiveStats.traces=K.PassiveStats.traces+K.UpdateCarryAlignment(ent,held,contacts)end
    if not next(contacts) then release(ent) return end
    state.contacts=contacts active[ent]=state
    K.AcquirePassive(ent,owner,reader)
    -- Same-frame memoization is opt-in for this stable reader only.
    local lease=K.PoseLeases[ent]
    if lease and lease.passiveOwner==owner then lease.automaticOwner=owner end
    K.PassiveReports[ent]={contacts=contacts,presentationOnly=true}
end
hook.Add("Think","ContactIK.Passive",function()
    local now=CurTime()
    if not enabled:GetBool() then
        for ent in pairs(active) do release(ent) end
        if K.StopCarryAlignment then K.StopCarryAlignment(true) end
        return
    end
    if now>=nextDiscovery then
        local nearby={} local distances={} local lp=LocalPlayer()
        local limit=math.Clamp(range:GetFloat(),128,2000)^2
        local all=players:GetBool() and player.GetAll() or {}
        if npcs:GetBool() then for _,ent in ipairs(ents.FindByClass("npc_*")) do all[#all+1]=ent end end
        if IsValid(lp) then
            for _,ent in ipairs(all) do
                local distance=ent:GetPos():DistToSqr(lp:GetPos())
                if ent~=lp and distance<=limit and K.PassiveEligibility(ent,true) then nearby[#nearby+1]=ent distances[ent]=distance end
            end
            table.sort(nearby,function(a,b)return distances[a]<distances[b]end)
        end
        candidates={} local selected={}
        for i=1,math.min(#nearby,31) do candidates[i]=nearby[i] selected[nearby[i]]=true end
        for ent in pairs(active) do if ent~=lp and not selected[ent] then release(ent) end end
        nextDiscovery=now+1 cursor=1
    end
    if now<nextTick then return end nextTick=now+.1
    K.PassiveStats.traces=0 K.PassiveStats.updates=0
    -- Local input gets a 0.1-second response without raising the four-subject budget.
    local lp=LocalPlayer() local budget=4
    if IsValid(lp) and (active[lp] or K.PassiveInputRequested(lp)) then
        update(lp) budget=budget-1 K.PassiveStats.updates=1
    end
    for _=1,math.min(#candidates,budget) do
        if cursor>#candidates then cursor=1 end
        local ent=candidates[cursor] cursor=cursor+1 update(ent)
        K.PassiveStats.updates=K.PassiveStats.updates+1
    end
    K.PassiveStats.entities=table.Count(active)
    for ent,state in pairs(active) do
        if not IsValid(ent) or ent:IsDormant() then release(ent)
        elseif not K.PassiveInputRequested(ent) then
            local alive=false
            for _,c in pairs(state.contacts) do
                c.lostAt=c.lostAt or now
                -- Keep zero-weight targets briefly so the compositor can
                -- finish easing, just as it does after losing a surface.
                if now-c.lostAt<grace+math.Clamp(fade:GetFloat(),.15,1.5)+.2 then alive=true end
            end
            if not alive then release(ent) end
        end
    end
end)
