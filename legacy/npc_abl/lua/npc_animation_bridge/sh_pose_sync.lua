local Bridge = NPCAnimationBridge
if Bridge.PoseSync then Bridge.PoseSync.Shutdown() end
local Sync = {version = 1}
Bridge.PoseSync = Sync
local channel = "NPCAnimationBridge.PoseInputs1"
local tokenKey = "NPCAnimationBridge.PoseInputToken"
local active = {}
local closed = false
local function finite(n) return Bridge.Catalog.IsFinite(n) and math.abs(n) <= 1000000 end

if SERVER then
    util.AddNetworkString(channel)
    local serial = 0
    local epoch = util.SHA256(tostring(SysTime()))
    local function send(state, stop)
        net.Start(channel)
        net.WriteEntity(state.entity)
        net.WriteString(state.token)
        net.WriteBool(stop)
        if not stop then
            net.WriteString(state.model)
            net.WriteUInt(state.sequence, 16)
            local names = {}
            for name in pairs(state.poses) do names[#names+1] = name end
            table.sort(names)
            net.WriteUInt(#names, 6)
            for _, name in ipairs(names) do
                net.WriteString(name); net.WriteFloat(state.poses[name]); net.WriteFloat(state.originals[name])
            end
        end
        net.Broadcast()
    end
    local function publish(handle, poses, preview)
        if closed then return false, "pose_sync_shutdown" end
        local owned = type(handle)=="table" and (preview and Bridge.Preview and Bridge.Preview.IsControllerOwned(handle)
            or not preview and Bridge.FullBody and Bridge.FullBody.IsHandleOwned(handle))
        if not owned or not handle.clip then return false, "not_owned" end
        local sequence=preview and handle.poseSequence or handle.clip.sequence
        if not finite(sequence) or sequence<0 or sequence>65535 or sequence%1~=0 then return false,"pose_sync_sequence_unavailable" end
        if type(poses)~="table" then return false,"invalid_poses" end
        if not next(poses) and not active[handle.entity] then return true end
        local state = active[handle.entity]
        if state and state.handle ~= handle then return false, "pose_sync_busy" end
        local merged, count = {}, 0
        for name, value in pairs(state and state.poses or {}) do merged[name] = value end
        for name, value in pairs(poses) do merged[name] = value end
        for name, value in pairs(merged) do
            count = count+1
            if count > 32 or type(name) ~= "string" or #name < 1 or #name > 96 or not finite(value) then
                return false, "pose_sync_capacity"
            end
            if not handle.poseOriginals or not finite(handle.poseOriginals[name]) then return false, "pose_sync_original_unavailable" end
        end
        if not state then
            local total=0; for _ in pairs(active) do total=total+1 end
            if total>=64 then return false,"pose_sync_capacity" end
            serial = serial+1
            state = {entity=handle.entity, handle=handle, model=preview and handle.playbackModel or handle.model, preview=preview,
                token=util.SHA256(epoch..":"..serial), lastSend=-math.huge, sends=0}
            active[handle.entity] = state
            handle.entity:SetNWString(tokenKey, state.token)
        end
        local originals={}
        for name in pairs(merged) do originals[name]=handle.poseOriginals[name] end
        state.poses, state.originals, state.dirty = merged, originals, true
        state.sequence = sequence
        return true
    end
    function Sync.Publish(handle, poses) return publish(handle,poses,false) end
    function Sync.PublishPreview(context, poses) return publish(context,poses,true) end
    function Sync.Stop(handle)
        local state = active[handle.entity]
        if not state or state.handle ~= handle then return false end
        active[handle.entity] = nil
        if IsValid(state.entity) then
            if state.entity:GetNWString(tokenKey) == state.token then state.entity:SetNWString(tokenKey, "") end
            local ok, error = pcall(send,state,true)
            if not ok then handle.syncError=tostring(error):sub(1,2048) end
        end
        return true
    end
    function Sync.Flush()
        local now = CurTime()
        for _, state in pairs(active) do
            local checked, owned = pcall(function()
                return state.preview and Bridge.Preview.IsControllerOwned(state.handle)
                    or not state.preview and Bridge.FullBody.IsHandleOwned(state.handle)
            end)
            if state.handle.finished or not IsValid(state.entity) or not checked or not owned then Sync.Stop(state.handle)
            elseif (state.dirty and now-state.lastSend >= .05) or now-state.lastSend >= .5 then
                local ok, error = pcall(send,state,false)
                state.error=not ok and tostring(error):sub(1,2048) or nil
                state.lastSend, state.dirty = now, false
                if ok then state.sends=state.sends+1 end
            end
        end
    end
    function Sync.GetStatus(entity)
        local state = active[entity]
        return state and {schema=1, active=true, sends=state.sends, dirty=state.dirty, failure=state.error} or {schema=1, active=false}
    end
    function Sync.Shutdown()
        closed=true
        for _, state in pairs(active) do Sync.Stop(state.handle) end
    end
else
    local failed = setmetatable({}, {__mode="k"})
    local function raw(entity, name)
        local id = entity:LookupPoseParameter(name)
        if not finite(id) or id < 0 then return nil end
        local low, high = entity:GetPoseParameterRange(id)
        local normalized = entity:GetPoseParameter(name)
        if not finite(low) or not finite(high) or not finite(normalized) then return nil end
        return low+(high-low)*normalized
    end
    local function detach(state)
        local entity = state.entity
        if IsValid(entity) and entity:GetModel() == state.model and entity:GetSequence() == state.sequence then
            local token = entity:GetNWString(tokenKey)
            if token == "" or token == state.token then
                pcall(function()
                    local changed = false
                    for name, saved in pairs(state.saved) do
                        local value = raw(entity, name)
                        if value and state.applied[name] and math.abs(value-state.applied[name]) < .0001 then
                            entity:SetPoseParameter(name, saved)
                            changed = true
                        end
                    end
                    if changed then entity:InvalidateBoneCache() end
                end)
            end
        end
        active[entity] = nil
    end
    net.Receive(channel, function(length)
        if closed or length > 40000 then return end
        local entity, token, stop = net.ReadEntity(), net.ReadString(), net.ReadBool()
        if not IsValid(entity) or entity:IsPlayer() or #token ~= 64 then return end
        local state = active[entity]
        if stop then
            if state and state.token == token then detach(state) end
            if failed[entity] and failed[entity].token == token then failed[entity]=nil end
            return
        end
        if failed[entity] and failed[entity].token == token then return end
        local model, sequence, count = net.ReadString(), net.ReadUInt(16), net.ReadUInt(6)
        if #model > 240 or count < 1 or count > 32 then return end
        local poses, originals = {}, {}
        for _ = 1, count do
            local name, value, original = net.ReadString(), net.ReadFloat(), net.ReadFloat()
            if #name < 1 or #name > 96 or poses[name] ~= nil or not finite(value) or not finite(original) then return end
            poses[name], originals[name] = value, original
        end
        if not Bridge.Catalog.IsActor(entity) then return end
        if state and state.token ~= token then detach(state); state=nil end
        if not state then
            local total=0; for _ in pairs(active) do total=total+1 end
            if total >= 64 then return end
            state = {entity=entity, token=token, model=model, sequence=sequence,
                saved={}, applied={}, updates=0}
            active[entity] = state
        end
        state.model, state.sequence, state.poses, state.originals, state.received = model, sequence, poses, originals, RealTime()
        state.generation = (state.generation or 0)+1
    end)
    function Sync.Maintain()
        for _,state in pairs(active) do
            if not IsValid(state.entity) or RealTime()-state.received>1.5 then detach(state) end
        end
    end
    function Sync.Tick()
        Sync.Maintain()
        for _, state in pairs(active) do
            local entity = state.entity
            if entity:GetNWString(tokenKey) ~= state.token then
                -- Token/entity replication may lag the packet. Never write until matched.
            elseif not entity:IsDormant() and entity:GetModel() == state.model and entity:GetSequence() == state.sequence then
                local ok, error = pcall(function()
                    local inputs, reason = Bridge.Controllers.Resolve(entity, {poses=state.poses})
                    if not inputs then error(reason) end
                    local changed=false
                    for name, value in pairs(inputs.poses) do
                        local current=raw(entity,name)
                        if current == nil then error("pose_value_unavailable") end
                        if state.saved[name] == nil then state.saved[name]=state.originals[name] end
                        if math.abs(current-value) > .00001 then entity:SetPoseParameter(name,value); changed=true end
                        state.applied[name]=raw(entity,name)
                    end
                    if changed then entity:InvalidateBoneCache() end
                    state.updates=state.updates+1
                    state.appliedGeneration, state.lastApplied = state.generation, RealTime()
                end)
                if not ok then
                    failed[entity]={token=state.token, reason=tostring(error):sub(1,2048)}
                    detach(state)
                end
            end
        end
    end
    function Sync.GetStatus(entity)
        local state=active[entity]
        local inputs, applied, current={}, {}, {}
        if state then for name,value in pairs(state.poses) do inputs[name]=value end end
        if state then for name,value in pairs(state.applied) do applied[name]=value end end
        local ready=state and IsValid(entity) and not entity:IsDormant() and entity:GetNWString(tokenKey)==state.token
            and entity:GetModel()==state.model and entity:GetSequence()==state.sequence
        local converged=ready and state.generation==state.appliedGeneration or false
        local queried,queryError=true,nil
        if ready then
            queried,queryError=pcall(function()
                for name,value in pairs(inputs) do
                    local present=raw(entity,name)
                    current[name]=present
                    if not finite(present) or math.abs(present-value)>.0001 then converged=false end
                end
            end)
            if not queried then converged=false end
        end
        return state and {schema=1, active=true, updates=state.updates,
            inputs=inputs, applied=applied, current=current, converged=converged,
            failure=not queried and "pose_query_failed" or nil,
            failureDetails=not queried and tostring(queryError):sub(1,2048) or nil,
            pending=state.generation~=state.appliedGeneration,
            applyAge=state.lastApplied and math.max(0,RealTime()-state.lastApplied) or nil,
            model=state.model, sequence=state.sequence,
            ready=ready,
            age=math.max(0,RealTime()-state.received)} or {schema=1, active=false,
                failure=failed[entity] and failed[entity].reason}
    end
    function Sync.Shutdown()
        closed=true
        for _, state in pairs(active) do detach(state) end
        hook.Remove("Think", "NPCAnimationBridge.PoseInputs")
        hook.Remove("PreRender", "NPCAnimationBridge.PoseInputs")
    end
    -- Apply at the render boundary rather than competing with engine pose
    -- interpolation during Think. Think retains expiry cleanup without drawing.
    hook.Add("Think", "NPCAnimationBridge.PoseInputs", Sync.Maintain)
    hook.Add("PreRender", "NPCAnimationBridge.PoseInputs", Sync.Tick)
end

function Sync.GetActiveCount()
    local count=0; for _ in pairs(active) do count=count+1 end
    return count
end
