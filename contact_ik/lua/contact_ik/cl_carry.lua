-- Optional draw-only correction. The native controller and collision stay put.
local K=ContactIK
if K.StopCarryAlignment then K.StopCarryAlignment() end
local enabled=CreateClientConVar("contact_ik_carry_alignment","1",true,false,"Visually bring native carried props into hand reach; collision stays native")
local states=setmetatable({}, {__mode="k"})
local function release(held,state)
    if IsValid(held) and held.RenderOverride==state.draw then held.RenderOverride=nil end
    states[held]=nil
end
function K.CarryAlignmentAvailable(held)
    if not enabled:GetBool() or not IsValid(held) or held:GetRenderOrigin() then return false end
    local state=states[held]
    return held.RenderOverride==nil or state~=nil and held.RenderOverride==state.draw
end
local function desiredOffset(held,state)
    local ent=state.owner
    local point=held:LocalToWorld(state.localPoint)
    local normal=(held:LocalToWorld(state.localPoint+state.localNormal)-point):GetNormalized()
    local tangent=(held:LocalToWorld(state.localPoint+state.localTangent)-point):GetNormalized()
    local wrist=K.TargetWrist(ent,state.arm,point,normal,tangent,state.profile)
    local delta=wrist-K.SubjectToWorld(ent,state.rootLocal)
    return -delta:GetNormalized()*math.Clamp(delta:Length()-state.reach+2*state.scale,0,32*state.scale)
end
local function advance(held,state)
    local owner=state.owner
    local active=enabled:GetBool() and IsValid(owner) and K.NativeCarriedEntity(owner)==held
        and K.PassiveReports[owner] and K.PassiveEligibility(owner,true)
    if active then state.releasedAt=nil state.desired=desiredOffset(held,state)*(state.clearFraction or 1)
    elseif not state.releasedAt then state.releasedAt=CurTime()end
    -- Ease acquisition/release, not the native motion of an established hold.
    if state.frame~=FrameNumber() then
        state.frame=FrameNumber()
        state.strength=Lerp(1-math.exp(-18*FrameTime()),state.strength or 0,active and 1 or 0)
    end
    state.offset=(state.desired or Vector())*(state.strength or 0)
    return state.offset
end
function K.CarryAlignedPoint(held,point)
    local state=states[held]
    if state and held.RenderOverride==state.draw and not held:GetRenderOrigin() then return point+advance(held,state) end
    return point
end
function K.RecordCarryPalm(ent,held,index,palm,target,weight)
    local state=states[held]
    if not state or state.owner~=ent or not state.armMask[index] then return end
    state.palms=state.palms or {}
    local origin=held:GetPos()
    state.palms[index]={error=held:WorldToLocal(origin+palm-target)-held:WorldToLocal(origin),
        weight=math.Clamp(((weight or 0)-.85)/.15,0,1),time=CurTime()}
end
function K.CarryRenderedPoint(held,point)
    local state=states[held]
    if not state or held.RenderOverride~=state.draw or held:GetRenderOrigin() then return point end
    local nominal=advance(held,state)
    if not state.releasedAt then
        local correction=Vector()local count=0 local origin=held:GetPos()
        for index,sample in pairs(state.palms or {})do
            if state.armMask[index] and CurTime()-sample.time<.1 then
                correction=correction+(held:LocalToWorld(sample.error)-origin)*sample.weight count=count+1
            end
        end
        if count>0 then correction=correction/count end
        -- Translation that best fits the solved palms, bounded so an entering
        -- arm or an obstructed pose cannot drag the prop across the body.
        if correction:Length()>4*state.scale then correction=correction:GetNormalized()*4*state.scale end
        state.correction=correction
    end
    local offset=nominal+(state.correction or Vector())*(state.strength or 0)
    if offset:Length()>32*state.scale then offset=offset:GetNormalized()*32*state.scale end
    return point+offset
end
function K.UpdateCarryAlignment(ent,held,contacts)
    if not K.CarryAlignmentAvailable(held) then return 0 end
    local carry={}
    for index,c in pairs(contacts)do
        if c.entity==held and c.role=="carry" and c.localPoint and (not c.lostAt or K.PassiveContactWeight(c)>.15)then carry[index]=c end
    end
    contacts=carry if not next(contacts)then return 0 end
    local state=states[held]
    if held:GetRenderOrigin() or held.RenderOverride and (not state or held.RenderOverride~=state.draw) then return 0 end
    local chosen=state and contacts[state.arm]
    if not chosen then for _,c in pairs(contacts) do if not chosen or c.score<chosen.score then chosen=c end end end
    local a=K.SensingArm(ent,chosen.arm)if not a then return 0 end
    local spec={owner=ent,arm=chosen.arm,localPoint=chosen.localPoint,localNormal=chosen.localNormal,
        localTangent=chosen.localTangent,rootLocal=K.SubjectToLocal(ent,a.root),reach=a.reach,
        scale=ent:GetModelScale(),profile=K.HandProfile(ent,chosen.arm),armMask={[1]=contacts[1]~=nil,[2]=contacts[2]~=nil}}
    local desired=desiredOffset(held,spec)
    local traces=0
    local clearFraction=1
    if desired:LengthSqr()>.001 then
        local origin=held:GetPos()local low,high=held:WorldSpaceAABB()
        local tr=util.TraceHull({start=origin,endpos=origin+desired,mins=low-origin,maxs=high-origin,
            filter={ent,held},mask=MASK_SOLID})
        clearFraction=tr.StartSolid and 0 or math.max((tr.Fraction or 1)-.02,0)
        desired=desired*clearFraction traces=1
    end
    if not state then
        if desired:LengthSqr()<.001 then return traces end
        state={offset=Vector(),strength=0}
        state.draw=function(subject)
            if subject:GetRenderOrigin() then return subject:DrawModel() end
            -- SetRenderOrigin also changes GetPos while drawing. Restore it
            -- even on an error; no origin override survives this callback.
            subject:SetRenderOrigin(K.CarryRenderedPoint(held,subject:GetPos()))
            subject:InvalidateBoneCache()
            local ok,err=pcall(subject.DrawModel,subject)
            subject:SetRenderOrigin(nil)subject:InvalidateBoneCache()
            if not ok then release(subject,state)ErrorNoHalt(tostring(err).."\n")end
        end
        states[held]=state held.RenderOverride=state.draw
    end
    if state.owner~=ent then state.palms,state.correction=nil,nil end
    for key,value in pairs(spec)do state[key]=value end
    state.desired,state.clearFraction=desired,clearFraction
    return traces
end
function K.StopCarryAlignment(keepHook)
    if not keepHook then hook.Remove("Think","ContactIK.CarryAlignment")end
    for held,state in pairs(states) do release(held,state)end
end
hook.Add("Think","ContactIK.CarryAlignment",function()
    for held,state in pairs(states) do
        if not IsValid(held) or held.RenderOverride~=state.draw then release(held,state)
        else
            advance(held,state)
            if state.releasedAt and (state.offset:LengthSqr()<.0001 or CurTime()-state.releasedAt>1) then release(held,state)end
        end
    end
end)
