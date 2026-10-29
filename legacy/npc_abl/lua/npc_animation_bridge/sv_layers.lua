local B=NPCAnimationBridge
if B.Layers then B.Layers.Shutdown() end
local Layers={version=1}
B.Layers=Layers
local active={}
local closed=false
local function baseCycle(context)
    local cycle=context.entity:GetCycle()
    if not B.Catalog.IsFinite(cycle) or cycle<0 or cycle>1 then error("base_cycle_unavailable") end
    return cycle
end
local function baseOwned(context)
    return B.FullBody.IsHandleOwned(context.base) and context.base.clip
        and context.base.clip.sequence==context.baseSequence and context.entity:GetModel()==context.model
end
local function inputsOwned(context)
    for name in pairs(context.poseNames) do
        local value=context.base.poseApplied and context.base.poseApplied[name]
        local present=context.entity:GetPoseParameter(name)
        if not B.Catalog.IsFinite(value) or not B.Catalog.IsFinite(present) or math.abs(value-present)>.0001 then return false end
    end
    return true
end
local function finish(context,reason)
    if active[context.entity]~=context then return false,"not_owned" end
    active[context.entity]=nil
    context.finished,context.reason=true,reason
    if context.overlay then
        local ok,err=pcall(B.Executor.Cancel,context.overlay)
        if not ok then context.cleanupError=tostring(err):sub(1,2048) end
    end
    return true
end
local function play(base,request)
    if not B.FullBody.IsHandleOwned(base) or not base.clip then return nil,"base_lease_required" end
    if type(request)~="table" or type(request.sequence)~="string" then return nil,"sequence_required" end
    local entity=base.entity
    if active[entity] or B.Executor.GetStatus(entity).active then return nil,"actor_busy" end
    local contract,reason=B.Controllers.ResolveSequence(entity,request)
    if not contract then return nil,reason end
    local clip=contract.clip
    if clip.gesture or not contract.baseRequired then return nil,"base_dependent_sequence_required" end
    local binding=request.binding
    if type(binding)~="table" or binding.model~=clip.model or binding.baseSequence~=base.clip.label or binding.layerSequence~=clip.label then
        return nil,"base_layer_mapping_mismatch"
    end
    local seconds,rate,cycle=request.seconds,request.rate or 1,request.cycle or 0
    local phase=request.phase or "independent"
    if not B.Catalog.IsFinite(seconds) or seconds<.1 or seconds>30
        or not B.Catalog.IsFinite(rate) or rate<.1 or rate>4 or not B.Catalog.IsFinite(cycle) or cycle<0 or cycle>=1
        or (phase~="base" and phase~="independent") then return nil,"invalid_options" end
    local names={}
    for name,value in pairs(contract.inputs.poses) do
        local applied=base.poseApplied and base.poseApplied[name]
        if not B.Catalog.IsFinite(applied) or math.abs(applied-value)>.0001 then return nil,"base_pose_input_not_owned" end
        names[name]=true
    end
    local context={entity=entity,base=base,baseSequence=base.clip.sequence,model=clip.model,clip=clip,
        seconds=seconds,phase=phase,poseNames=names,binding={model=binding.model,baseSequence=binding.baseSequence,layerSequence=binding.layerSequence}}
    if not inputsOwned(context) then return nil,"base_pose_input_not_owned" end
    active[entity]=context
    local overlay,failure=B.Executor.StartOverlay(entity,{sequence=clip.label,rate=rate,cycle=cycle,composition=true,compositionContext=context,
        weight=request.weight,priority=request.priority or 15,blendIn=request.blendIn,blendOut=request.blendOut})
    if not overlay then finish(context,failure); return nil,failure end
    context.overlay=overlay
    if active[entity]~=context or closed or context.finished then B.Executor.Cancel(overlay); return nil,"layer_start_preempted" end
    if phase=="base" then
        entity:SetLayerPlaybackRate(overlay.layer,0)
        entity:SetLayerCycle(overlay.layer,baseCycle(context))
    end
    base.layerFailure=nil
    return context
end
function Layers.Play(base,request)
    if closed then return nil,"module_shutting_down" end
    local entity=type(base)=="table" and base.entity
    local previous=entity and active[entity]
    local ok,result,reason=pcall(play,base,request)
    if ok then return result,reason end
    local context=entity and active[entity]
    if context and context~=previous then context.writeError=tostring(result):sub(1,2048); finish(context,"layer_write_failed") end
    return nil,"layer_write_failed"
end
function Layers.CanStartOverlay(entity,clip,requested)
    local context=active[entity]
    return context~=nil and context==requested and not context.finished and context.overlay==nil and context.clip.sequence==clip.sequence
        and baseOwned(context) and inputsOwned(context),context and context.seconds
end
function Layers.Stop(context)
    if type(context)~="table" then return false,"not_owned" end
    return finish(context,"cancelled")
end
function Layers.StopForBase(base,reason)
    local context=active[base.entity]
    if context and context.base==base then return finish(context,reason or "base_released") end
    return false,"not_owned"
end
-- Called after the cooperating owner's FrameAdvance, before it returns. Think
-- still provides lifecycle/phase maintenance for other engine update ordering.
function Layers.SyncForBase(base)
    if type(base)~="table" then return false,"base_lease_required" end
    local context=active[base.entity]
    if context and context.base~=base then return false,"not_owned" end
    local ok,result,reason=pcall(function()
        if not B.FullBody.IsHandleOwned(base) then
            if context then finish(context,"base_preempted") end
            return false,"base_lease_required"
        end
        if not context then return true end
        if not baseOwned(context) then finish(context,"base_preempted"); return false,"base_preempted" end
        if not inputsOwned(context) then finish(context,"base_pose_preempted"); return false,"base_pose_preempted" end
        if context.overlay and context.overlay.finished then finish(context,context.overlay.reason); return true end
        if not B.Executor.IsHandleOwned(context.overlay) then finish(context,"layer_preempted"); return false,"layer_preempted" end
        if context.phase=="base" then
            context.entity:SetLayerCycle(context.overlay.layer,baseCycle(context))
            context.phaseUpdates=(context.phaseUpdates or 0)+1
        end
        return true
    end)
    if not ok then
        if context and active[base.entity]==context then context.writeError=tostring(result):sub(1,2048); finish(context,"layer_update_failed") end
        return false,"layer_update_failed"
    end
    return result,reason
end
function Layers.Update()
    for _,context in pairs(active) do
        local ok,err=pcall(function()
            if not baseOwned(context) then finish(context,"base_preempted")
            elseif not inputsOwned(context) then finish(context,"base_pose_preempted")
            elseif context.overlay.finished then finish(context,context.overlay.reason)
            elseif not B.Executor.IsHandleOwned(context.overlay) then finish(context,"layer_preempted")
            elseif context.phase=="base" then
                context.entity:SetLayerCycle(context.overlay.layer,baseCycle(context))
            end
        end)
        if not ok then context.writeError=tostring(err):sub(1,2048); finish(context,"layer_update_failed") end
    end
end
function Layers.GetStatus(entity)
    local context=active[entity]
    if not context then return {schema=1,active=false} end
    local checked,valid=pcall(function() return baseOwned(context) and inputsOwned(context) and B.Executor.IsHandleOwned(context.overlay) end)
    return {schema=1,active=true,valid=checked and valid or false,phase=context.phase,
        baseSequence=context.baseSequence,sequence=context.clip.sequence,model=context.model,phaseUpdates=context.phaseUpdates or 0,
        failure=not checked and "layer_query_failed" or nil}
end
function Layers.GetActiveCount() local count=0; for _ in pairs(active) do count=count+1 end; return count end
function Layers.Shutdown()
    closed=true
    for _,context in pairs(active) do finish(context,"module_reload") end
    hook.Remove("Think","NPCAnimationBridge.Layers")
end
hook.Add("Think","NPCAnimationBridge.Layers",Layers.Update)
