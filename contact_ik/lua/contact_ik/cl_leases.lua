-- One compositor per entity. Explicit caller leases outrank passive fallback.
local K = ContactIK
-- GLua may refresh this module directly rather than through autorun. Preserve
-- the registry until its previous shutdown has removed all owned callbacks.
if K.Shutdown then K.Shutdown() end
local leases = K.PoseLeases or setmetatable({}, {__mode="k"})
K.PoseLeases=leases
K.Reports = setmetatable({}, {__mode="k"})
function K.Release(ent, owner)
    local state = leases[ent]
    if not owner or not state or state.owner ~= owner then return false end
    state.owner,state.reader=nil,nil
    if not state.passiveOwner then
        if IsValid(ent) then ent:RemoveCallback("BuildBonePositions", state.callback) end
        leases[ent], K.Reports[ent] = nil, nil
    end
    return true
end
function K.ReleaseOwner(owner)
    for ent, state in pairs(leases) do if state.owner == owner then K.Release(ent,owner) end end
end
local function ensure(ent)
    if leases[ent] then return leases[ent] end
    local state={passiveState={}}
    leases[ent]=state
    state.callback=ent:AddCallback("BuildBonePositions",function(model)
        local c=state.reader and state.reader(model)
        local fallback=state.passiveReader and state.passiveReader(model)
        if not c then
            if fallback and not state.owner then
                local pose,r=K.BuildContactsPose(model,fallback,state.passiveState)
                for id,m in pairs(pose) do model:SetBoneMatrix(id,m) end
                r.owner=state.owner and "explicit idle / passive" or "passive"
                K.Reports[model]=r
            else K.Reports[model]=nil end
            return
        end
        local other=K.Arms[c.arm==1 and 2 or 1]
        local bone=other and model:LookupBone(other.prefix.."Hand")
        local matrix=bone and model:GetBoneMatrix(bone)
        local prior=matrix and matrix:GetTranslation()
        local matrices,report,bodyTransform
        local secondary=fallback and (c.allowPassive or c.freeHand) and not c.anchorBone and fallback[c.arm==1 and 2 or 1]
        local contact=c
        if secondary and c.freeHand then contact=table.Copy(c) contact.freeHand=false end
        if c.anchorBone then matrices,report,bodyTransform=K.BuildAnchorPose(model,contact,state)
        else matrices,report,bodyTransform=K.BuildArmPose(model,contact,state) end
        if secondary and matrices then
            local pose,r=K.BuildContactsPose(model,{[c.arm==1 and 2 or 1]=secondary},state.passiveState,matrices)
            for id,m in pairs(pose) do matrices[id]=m end
            if report then report.passive=r end
        end
        if matrices then for id,m in pairs(matrices) do model:SetBoneMatrix(id,m) end end
        if report and prior then
            local after=model:GetBoneMatrix(bone)
            report.inactiveHandError=after and after:GetTranslation():Distance(bodyTransform and bodyTransform*prior or prior) or -1
            report.inactiveHandWritten=matrices and matrices[bone]~=nil or false
        end
        if report then report.owner="explicit" end
        K.Reports[model]=report
    end)
    return state
end
function K.Acquire(ent,owner,reader)
    if not IsValid(ent) or not owner or not isfunction(reader) then return false,"invalid lease" end
    local state=leases[ent]
    if state and state.owner and state.owner~=owner then return false,"pose already owned" end
    state=ensure(ent)
    if state.owner~=owner then state.target,state.weight,state.profile,state.frame=nil,nil,nil,nil state.arm,state.model,state.scale=nil,nil,nil end
    state.owner,state.reader=owner,reader
    return true
end
function K.AcquirePassive(ent,owner,reader)
    if not IsValid(ent) or not owner or not isfunction(reader) then return false,"invalid passive lease" end
    local state=leases[ent]
    if state and state.passiveOwner and state.passiveOwner~=owner then return false,"passive pose already owned" end
    state=ensure(ent) state.passiveOwner,state.passiveReader=owner,reader
    return true
end
function K.ReleasePassive(ent,owner)
    local state=leases[ent]
    if not owner or not state or state.passiveOwner~=owner then return false end
    state.passiveOwner,state.passiveReader=nil,nil state.passiveState={}
    if not state.owner then
        if IsValid(ent) then ent:RemoveCallback("BuildBonePositions",state.callback) end
        leases[ent],K.Reports[ent]=nil,nil
    end
    return true
end
function K.LeaseCount() return table.Count(leases) end
hook.Add("EntityRemoved","ContactIK.Leases",function(ent)
    local state=leases[ent]
    if state then leases[ent],K.Reports[ent]=nil,nil end
end)
function K.Shutdown()
    if K.StopPassive then K.StopPassive() end
    hook.Remove("EntityRemoved","ContactIK.Leases")
    hook.Remove("PopulateToolMenu","ContactIK.Settings")
    for ent,state in pairs(leases) do
        if IsValid(ent) then ent:RemoveCallback("BuildBonePositions",state.callback) end
        leases[ent],K.Reports[ent]=nil,nil
    end
end
