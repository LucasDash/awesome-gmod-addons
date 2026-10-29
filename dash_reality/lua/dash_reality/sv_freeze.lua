-- Freeze NPCs: stops an NPC in time and re-homes it onto a physgun-grabbable carrier prop.

local RT = DashReality

-- The registry survives a live source refresh so existing carriers and their
-- NPCs remain connected to the new callbacks.
local frozen = RT.Frozen or {}
RT.Frozen = frozen

-- Methods stubbed on scripted NPCs/NextBots so their own AI loops stop; removing the override restores them.
local AI_STUBS = {
    "Think", "BehaveUpdate", "BodyUpdate", "RunAI", "SelectSchedule", "DoRunAI", "OnThink",
    "RunBehaviour",
}
local function noop() end

function RT.IsTimeFrozen(ent)
    if not IsValid(ent) then return false end
    if IsValid(ent.RT_NPC) then ent = ent.RT_NPC end
    local rag = RT.RagdollState and RT.RagdollState(ent)
    return frozen[ent] ~= nil or (RT.FrozenPhysics and RT.FrozenPhysics[ent] ~= nil) or (rag and rag.timeFrozen == true) or false
end

local function isNextBot(ent)
    return ent.IsNextBot and ent:IsNextBot()
end

local function isScripted(ent)
    return isNextBot(ent) or scripted_ents.Get(ent:GetClass()) ~= nil
end

function RT.IsFreezable(ent)
    if not IsValid(ent) or ent:IsPlayer() or frozen[ent] or ent.RT_RagState then return false end
    if ent:Health() <= 0 then return false end
    if ent:IsNPC() then return true end
    return isNextBot(ent) and RT.Bool("rt_freeze_nextbots")
end

-- Accepts an NPC or its carrier and returns (npc, isFrozen).
function RT.ResolveTarget(ent)
    if not IsValid(ent) then return nil, false end
    if IsValid(ent.RT_NPC) and frozen[ent.RT_NPC] then return ent.RT_NPC, true end
    if frozen[ent] then return ent, true end
    return ent, false
end

local function stubAI(npc, state)
    state.stubs = {}
    local luaTable = npc:GetTable()
    for _, name in ipairs(AI_STUBS) do
        state.stubs[#state.stubs + 1] = { name = name, value = rawget(luaTable, name) }
        luaTable[name] = noop
    end
    if npc.loco then npc.loco:SetVelocity(vector_origin) end
end

local function restoreAI(npc, state)
    if not state.stubs then return end
    local luaTable = npc:GetTable()
    for _, saved in ipairs(state.stubs) do
        luaTable[saved.name] = saved.value
    end
    state.stubs = nil
end

-- Suspends an NPC's AI without the freeze carrier; used while a swapped ragdoll stands in for it.
function RT.SuspendAI(npc)
    local ai = { npcState = npc:IsNPC() and npc:GetNPCState() or nil, enemy = npc:IsNPC() and npc:GetEnemy() or nil }
    if npc:IsNPC() then
        npc:SetCondition(COND.NPC_FREEZE)
        ai.hasCondition = true
        npc:StopMoving()
        npc:SetEnemy(NULL)
        npc:ClearSchedule()
        npc:SetNPCState(NPC_STATE_NONE)
    end
    if isScripted(npc) then stubAI(npc, ai) end
    return ai
end

-- Undoes the engine-level freeze. SuspendAI cleared the schedule and the enemy, and the engine leaves
-- the NPC parked in a stale schedule, so it looked dead until a Physgun touch woke it. Give it a fresh
-- idle schedule, an immediate think and its old enemy back (a combat-state NPC with no enemy just idles).
local function thawEngineAI(npc, npcState, enemy)
    npc:SetCondition(COND.NPC_UNFREEZE)
    npc:SetNPCState(npcState)
    npc:ClearSchedule()
    npc:SetSchedule(SCHED_IDLE_STAND)
    if IsValid(enemy) then
        npc:SetEnemy(enemy)
        npc:UpdateEnemyMemory(enemy, enemy:GetPos())
    end
    npc:NextThink(CurTime())
end

function RT.ResumeAI(npc, ai)
    if not ai or not IsValid(npc) then return end
    restoreAI(npc, ai)
    if ai.hasCondition then thawEngineAI(npc, ai.npcState, ai.enemy) end
end

-- The engine may switch a parented, ground-less NPC to a falling/crouch animation; keep the captured pose.
function RT.HoldPose(state)
    local npc = state.npc
    if not IsValid(npc) then return end
    if npc:GetSequence() ~= state.sequence then npc:SetSequence(state.sequence) end
    npc:SetCycle(state.cycle)
    npc:SetPlaybackRate(0)
    for name, value in pairs(state.pose) do npc:SetPoseParameter(name, value) end
    for layer = 0, 14 do
        if npc:IsValidLayer(layer) then npc:SetLayerPlaybackRate(layer, 0) end
    end
end

-- Runs only while something is frozen (started in RT.Freeze, stops itself when empty).
timer.Create("DashReality.HoldFrozenPose", 0.1, 0, function()
    if next(frozen) == nil then return timer.Stop("DashReality.HoldFrozenPose") end
    for _, state in pairs(frozen) do RT.HoldPose(state) end
end)
if next(frozen) == nil then timer.Stop("DashReality.HoldFrozenPose") else timer.Start("DashReality.HoldFrozenPose") end

-- Finds a standing spot at or below `pos`, so a tilted or mid-air release still ends on the floor.
local function settleOnFloor(npc, pos)
    local trace = util.TraceHull({
        start = pos + Vector(0, 0, 24),
        endpos = pos - Vector(0, 0, 256),
        mins = npc:OBBMins(),
        maxs = npc:OBBMaxs(),
        mask = MASK_NPCSOLID,
        filter = npc,
    })
    if trace.StartSolid then return pos end
    if trace.Hit then return trace.HitPos end
    return pos
end

function RT.Unfreeze(npc, carrierRemoving)
    local state = frozen[npc]
    if not state then return false end
    frozen[npc] = nil

    local carrier = state.carrier
    if IsValid(carrier) then carrier.RT_Released = true end

    if IsValid(npc) then
        local pos, yaw = npc:GetPos(), npc:GetAngles().y
        if RT.Bool("rt_freeze_rewind") then pos, yaw = state.pos, state.ang.y end

        -- Detach first, then stand upright: the carrier may have been tipped over by the Physgun.
        npc:SetParent(NULL)
        npc:SetAngles(Angle(0, yaw, 0))
        npc:SetPos(settleOnFloor(npc, pos))
        npc:SetMoveType(state.moveType)
        npc:SetSolid(state.solid)
        npc:SetCollisionGroup(state.group)
        npc:SetLocalVelocity(vector_origin)
        npc:SetPlaybackRate(state.rate)
        restoreAI(npc, state)
        if not state.hadOnGround then npc:RemoveFlags(FL_ONGROUND) end
        if not state.hadNoThink then npc:RemoveEFlags(EFL_NO_THINK_FUNCTION) end
        if state.hasCondition then thawEngineAI(npc, state.npcState, state.enemy) end
        npc:SetNW2Bool("RT_TimeFrozen", false)
        npc:EmitSound("buttons/combine_button1.wav", 70)
    end

    if IsValid(carrier) and not carrierRemoving then carrier:Remove() end
    return true
end

function RT.Freeze(npc, ply)
    if not RT.IsFreezable(npc) then return false end

    local carrier = ents.Create("rt_time_carrier")
    if not IsValid(carrier) then return false end

    carrier.RT_Mins = npc:OBBMins()
    carrier.RT_Maxs = npc:OBBMaxs()
    carrier:SetPos(npc:GetPos())
    carrier:SetAngles(Angle(0, npc:GetAngles().y, 0))
    carrier:Spawn()
    local phys = carrier:GetPhysicsObject()
    if not IsValid(phys) then
        carrier:Remove()
        return false
    end
    -- Pinned in space until the Physgun grabs it, like any frozen prop.
    phys:EnableMotion(false)

    carrier.RT_NPC = npc
    carrier.RT_Owner = ply
    if IsValid(ply) then
        carrier:SetCreator(ply)
        if carrier.CPPISetOwner then carrier:CPPISetOwner(ply) end
    end

    local state = {
        npc = npc,
        carrier = carrier,
        owner = ply,
        pos = npc:GetPos(),
        ang = npc:GetAngles(),
        moveType = npc:GetMoveType(),
        solid = npc:GetSolid(),
        group = npc:GetCollisionGroup(),
        rate = npc:GetPlaybackRate(),
        npcState = npc:IsNPC() and npc:GetNPCState() or nil,
        enemy = npc:IsNPC() and npc:GetEnemy() or nil,
        hadNoThink = npc:IsEFlagSet(EFL_NO_THINK_FUNCTION),
        hadOnGround = npc:IsFlagSet(FL_ONGROUND),
        sequence = npc:GetSequence(),
        cycle = npc:GetCycle(),
        pose = {},
    }
    for index = 0, npc:GetNumPoseParameters() - 1 do
        local name = npc:GetPoseParameterName(index)
        state.pose[name] = npc:GetPoseParameter(name)
    end
    frozen[npc] = state
    timer.Start("DashReality.HoldFrozenPose")

    -- Engine-level AI freeze first; the think-disable flag below would otherwise block it.
    if npc:IsNPC() then
        npc:SetCondition(COND.NPC_FREEZE)
        state.hasCondition = true
        npc:StopMoving()
        npc:SetEnemy(NULL)
        npc:ClearSchedule()
        npc:SetNPCState(NPC_STATE_NONE)
    end
    if isScripted(npc) then stubAI(npc, state) end

    npc:AddEFlags(EFL_NO_THINK_FUNCTION)
    npc:AddFlags(FL_ONGROUND)
    npc:SetPlaybackRate(0)
    npc:SetLocalVelocity(vector_origin)
    npc:SetMoveType(MOVETYPE_NONE)
    npc:SetSolid(SOLID_NONE)
    npc:SetParent(carrier)
    npc:SetLocalPos(vector_origin)
    npc:SetLocalAngles(angle_zero)
    npc:SetNW2Bool("RT_TimeFrozen", true)
    RT.HoldPose(state)

    -- Removing the carrier would otherwise delete its parented child; release the NPC first.
    carrier:CallOnRemove("RT_TimeFrozen", function()
        if not carrier.RT_Released and IsValid(npc) then RT.Unfreeze(npc, true) end
    end)
    npc:CallOnRemove("RT_TimeFrozen", function()
        if frozen[npc] then
            frozen[npc] = nil
            if IsValid(carrier) then
                carrier.RT_Released = true
                carrier:Remove()
            end
        end
    end)

    npc:EmitSound("buttons/combine_button2.wav", 70)
    return true
end

local function canTool(ply, ent, tool, trace)
    if not IsValid(ply) or not ply:IsPlayer() or not IsValid(ent) then return false end
    if trace and (not istable(trace) or trace.Entity ~= ent or not trace.Hit) then return false end
    trace = trace or { Entity = ent, Hit = true, HitPos = ent:GetPos(), HitNormal = vector_up }
    local ok, allowed = pcall(gamemode.Call, "CanTool", ply, trace, "rt_timefreeze", tool, 1)
    return ok and allowed ~= false
end

local function describe(ent)
    if not IsValid(ent) then return end
    local rag = RT.RagdollState and RT.RagdollState(ent)
    if rag then return "ragdoll", ent, rag, rag.timeFrozen == true end
    local target, isFrozen = RT.ResolveTarget(ent)
    if not IsValid(target) then return end
    if isFrozen or RT.IsFreezable(target) then return "npc", target, frozen[target], isFrozen end
    local physics = RT.FrozenPhysics and RT.FrozenPhysics[target]
    if physics or (RT.IsPhysicsFreezable and RT.IsPhysicsFreezable(target)) then
        return "physics", target, physics, physics ~= nil
    end
end

local function tokenFor(kind, target)
    if kind == "npc" then return frozen[target] end
    if kind == "physics" then return RT.FrozenPhysics and RT.FrozenPhysics[target] end
    local rag = RT.RagdollState and RT.RagdollState(target)
    return rag and rag.timeFrozen and rag.freezeToken
end

local function setFrozen(ply, ent, wanted, tool, trace)
    if type(wanted) ~= "boolean" or not canTool(ply, ent, tool, trace) then return false end
    local kind, target, state, current = describe(ent)
    if not kind or current == wanted then return false end
    -- A carrier and its NPC may have different protection owners. Both must
    -- permit the action, while the original hit trace goes to its real target.
    if target ~= ent and not canTool(ply, target, tool) then return false end
    local changed
    if kind == "npc" then
        if wanted then changed = RT.Freeze(target, ply) else changed = RT.Unfreeze(target) end
    elseif kind == "ragdoll" then
        changed = RT.SetRagdollFrozen(state, wanted, ply)
    else
        changed = RT.SetPhysicsFrozen and RT.SetPhysicsFrozen(target, wanted, ply)
    end
    if not changed then return false end
    return true, {kind=kind, target=target, token=tokenFor(kind, target)}
end

local function restoreFreezeUndo(_, entries)
    for _, entry in ipairs(entries) do
        local target = entry.target
        if IsValid(target) and tokenFor(entry.kind, target) == entry.token then
            if entry.kind == "npc" then RT.Unfreeze(target)
            elseif entry.kind == "ragdoll" then
                local state = RT.RagdollState(target)
                if state then RT.SetRagdollFrozen(state, false) end
            elseif RT.SetPhysicsFrozen then RT.SetPhysicsFrozen(target, false) end
        end
    end
end

local function addFreezeUndo(ply, entries)
    if #entries == 0 or not IsValid(ply) or not undo then return end
    undo.Create(#entries == 1 and "Freeze Entity" or "Freeze Entities")
    undo.SetPlayer(ply)
    undo.AddFunction(restoreFreezeUndo, entries)
    undo.Finish()
end

-- Explicit action for trusted server-side adapters. NPC integrations must
-- independently authenticate the player owner and validate the real trace.
function RT.SetEntityFrozen(ply, ent, wanted, tool, trace)
    local changed, entry = setFrozen(ply, ent, wanted, tool, trace)
    if changed and wanted then addFreezeUndo(ply, {entry}) end
    return changed
end

-- Left click toggles a supported target; repeated explicit freeze actions do
-- not accidentally thaw one another.
function RT.ToolToggle(ply, ent, tool, trace)
    local kind, _, _, current = describe(ent)
    if not kind then return false end
    return RT.SetEntityFrozen(ply, ent, not current, tool, trace)
end

-- Area mode preserves the existing freeze-first / otherwise-thaw behavior and
-- creates one undo entry for the complete freeze operation.
function RT.ToolArea(ply, center, radius, tool)
    local thawed, iced, seen = {}, {}, {}
    for _, ent in ipairs(ents.FindInSphere(center, radius)) do
        local kind, target, _, current = describe(ent)
        if kind and not seen[target] then
            seen[target] = true
            local list = current and iced or thawed
            list[#list + 1] = ent
        end
    end
    local wanted = #thawed > 0
    local changed, entries = false, {}
    for _, ent in ipairs(wanted and thawed or iced) do
        local ok, entry = setFrozen(ply, ent, wanted, tool)
        if ok then changed = true if wanted then entries[#entries + 1] = entry end end
    end
    if wanted then addFreezeUndo(ply, entries) end
    return changed
end

function RT.ReleaseAll(ply)
    local released = false
    for npc, state in pairs(frozen) do
        if not IsValid(ply) or state.owner == ply then released = RT.Unfreeze(npc) or released end
    end
    for ent, state in pairs(RT.FrozenPhysics or {}) do
        if not IsValid(ply) or state.owner == ply then released = RT.SetPhysicsFrozen(ent, false) or released end
    end
    for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
        local state = RT.RagdollState and RT.RagdollState(rag)
        if state and state.timeFrozen and (not IsValid(ply) or state.owner == ply) then
            released = RT.SetRagdollFrozen(state, false) or released
        end
    end
    return released
end

-- Frozen NPCs live outside time: nothing can hurt them.
hook.Add("EntityTakeDamage", "DashReality.FrozenInvulnerable", function(ent)
    if frozen[ent] or (IsValid(ent.RT_NPC) and frozen[ent.RT_NPC]) then return true end
end)

hook.Add("PostCleanupMap", "DashReality.FreezeReset", function()
    for npc in pairs(table.Copy(frozen)) do frozen[npc] = nil end
end)

hook.Add("ShutDown", "DashReality.FreezeShutdown", function()
    RT.ReleaseAll(nil)
end)
