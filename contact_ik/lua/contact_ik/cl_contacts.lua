-- Automatic upper-body presentation. No input, forces, movement or AI setters.
local K=ContactIK
if K.StopPassive then K.StopPassive() end
local enabled=CreateClientConVar("contact_ik_enabled","1",true,false,"Automatic environmental hand posing")
local players=CreateClientConVar("contact_ik_players","1",true,false,"Pose compatible player world models")
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

function K.PassiveEligibility(ent)
    if not IsValid(ent) or ent:IsDormant() or ent:GetNoDraw() then return end
    local isPlayer=ent:IsPlayer()
    if isPlayer then
        if not players:GetBool() or not ent:Alive() or ent:InVehicle() then return end
    elseif not npcs:GetBool() or not ent:IsNPC() or ent:IsScripted() or ent:Health()<=0 then return end
    -- Native NPC state is server-only. A server-owned presentation hint keeps
    -- client posing out of scripted sequences, combat and occupied weapon arms.
    if not isPlayer and ent:GetNW2Bool("ContactIK.NPCBlocked",true) then return end
    if ent.IsProne and ent:IsProne() then return end
    local rig=K.Describe(ent)
    if not rig.arms[1] and not rig.arms[2] then return end
    local allowed={rig.arms[1],rig.arms[2]}
    local weapon=ent.GetActiveWeapon and ent:GetActiveWeapon()
    if IsValid(weapon) then
        local class=weapon:GetClass()
        if class~="weapon_functional_hands" and class~="weapon_fists" and class~="gmod_camera" then
            if class=="gmod_tool" or class=="weapon_physgun" or class=="weapon_physcannon" then allowed[2]=false
            else return end -- combat/reload/aiming animation retains ownership
        end
    end
    if isPlayer and (ent:KeyDown(IN_ATTACK) or ent:KeyDown(IN_ATTACK2)) and
        (not IsValid(weapon) or weapon:GetClass()~="weapon_functional_hands") then return end
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
-- Diagnostic entry also used by the normal controller; no synthetic contacts.
function K.FindPassiveContacts(ent,allowed,previous)
    local scale=ent:GetModelScale() local mins,maxs=ent:GetCollisionBounds()
    local pos=ent:GetPos()
    local arms={} local low,high=pos.z+maxs.z,pos.z+mins.z
    for index=1,2 do
        if allowed[index] then
            local a=K.Arm(ent,index) arms[index]=a
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
                entity=ray.Entity,role=role,score=score,weight=1,collision=true,passive=true})
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
    local allowed=K.PassiveEligibility(ent) if not allowed then return end
    local result={}
    for index,c in pairs(state.contacts) do
        if allowed[index] then
            c=resolve(ent,c)
            if c then c.weight=K.PassiveContactWeight(c) result[index]=c end
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
    candidates={}
end
local function update(ent)
    local allowed=K.PassiveEligibility(ent) local lp=LocalPlayer()
    if not allowed or not IsValid(lp) or ent:GetPos():DistToSqr(lp:GetPos())>math.Clamp(range:GetFloat(),128,2000)^2 then release(ent) return end
    local state=active[ent] or {contacts={}}
    local contacts=K.FindPassiveContacts(ent,allowed,state.contacts) local now=CurTime()
    for index,old in pairs(state.contacts) do
        if not contacts[index] and allowed[index] and resolve(ent,old) then
            old.lostAt=old.lostAt or now old.weight=K.PassiveContactWeight(old,now)
            if now-old.lostAt<grace+math.Clamp(fade:GetFloat(),.15,1.5)+.2 then contacts[index]=old end
        end
    end
    if not next(contacts) then release(ent) return end
    state.contacts=contacts active[ent]=state
    K.AcquirePassive(ent,owner,reader)
    K.PassiveReports[ent]={contacts=contacts,presentationOnly=true}
end
hook.Add("Think","ContactIK.Passive",function()
    local now=CurTime()
    if not enabled:GetBool() then for ent in pairs(active) do release(ent) end return end
    if now>=nextDiscovery then
        local nearby={} local distances={} local lp=LocalPlayer()
        local limit=math.Clamp(range:GetFloat(),128,2000)^2
        local all=player.GetAll()
        for _,ent in ipairs(ents.FindByClass("npc_*")) do all[#all+1]=ent end
        if IsValid(lp) then
            for _,ent in ipairs(all) do
                local distance=ent:GetPos():DistToSqr(lp:GetPos())
                if distance<=limit and K.PassiveEligibility(ent) then nearby[#nearby+1]=ent distances[ent]=distance end
            end
            table.sort(nearby,function(a,b)return distances[a]<distances[b]end)
        end
        candidates={} local selected={}
        for i=1,math.min(#nearby,32) do candidates[i]=nearby[i] selected[nearby[i]]=true end
        for ent in pairs(active) do if not selected[ent] then release(ent) end end
        nextDiscovery=now+1 cursor=1
    end
    if now<nextTick then return end nextTick=now+.1
    K.PassiveStats.traces=0 K.PassiveStats.updates=0
    -- At most four subjects per poll, at most 30 discovery traces each.
    for _=1,math.min(#candidates,4) do
        if cursor>#candidates then cursor=1 end
        local ent=candidates[cursor] cursor=cursor+1 update(ent)
        K.PassiveStats.updates=K.PassiveStats.updates+1
    end
    K.PassiveStats.entities=table.Count(active)
    for ent in pairs(active) do if not IsValid(ent) or ent:IsDormant() then release(ent) end end
end)
