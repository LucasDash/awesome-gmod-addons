-- Physgun ragdoll: a picked-up NPC is swapped for a limp ragdoll and stands back up once it settles.

local RT = DashReality

-- Retain existing swaps on refresh. Older builds kept this table private, so
-- recover their live records from the ragdolls before replacing the poller.
local active = RT.ActiveRagdolls or {}
if not RT.ActiveRagdolls then
    for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
        local state = rag.RT_RagState
        if state and state.rag == rag then active[rag] = state end
    end
end
RT.ActiveRagdolls = active
-- Seconds between settle checks; also the step added to a ragdoll's "at rest" counter.
local POLL_INTERVAL = 0.2
-- Below this bone speed (units/s) a ragdoll counts as settled.
local REST_SPEED = 25

-- Classes that have no ragdoll (or break when hidden): never swapped.
local EXCLUDED = {
    npc_turret_floor = true, npc_turret_ceiling = true, npc_combine_camera = true,
    combine_mine = true, npc_rollermine = true, npc_helicopter = true,
    combine_dropship = true, npc_combinedropship = true, npc_manhack = true,
    npc_cscanner = true, npc_clawscanner = true, npc_strider = true,
    npc_barnacle = true, npc_bullseye = true, npc_missiledefense = true,
    npc_combinegunship = true, npc_fisherman = true,
}

local function canConvert(npc)
    if not RT.Bool("rt_ragdoll_enable") then return false end
    if not IsValid(npc) or not npc:IsNPC() or npc:Health() <= 0 then return false end
    if EXCLUDED[npc:GetClass()] or npc.RT_NoRagdoll or npc.RT_RagState then return false end
    return not RT.IsTimeFrozen(npc)
end

-- Copies the NPC's current animation pose and velocity onto the ragdoll's physics bones.
-- GetBonePosition is used because SetupBones does not exist on the server.
local function copyPose(npc, rag)
    local velocity = npc:GetVelocity()
    for index = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(index)
        local pos, ang = npc:GetBonePosition(rag:TranslatePhysBoneToBone(index))
        if IsValid(phys) and pos and ang then
            phys:SetPos(pos)
            phys:SetAngles(ang)
        end
        if IsValid(phys) then
            phys:SetVelocity(velocity)
            phys:Wake()
        end
    end
end

-- The NPC stays alive (health, relations, weapon) but is invisible, inert and untouchable
-- while its ragdoll stands in for it.
local function hideNPC(npc, rag, state)
    state.ai = RT.SuspendAI(npc)
    local weapon = npc:GetActiveWeapon()
    state.weapon = IsValid(weapon) and weapon or nil
    state.weaponNoDraw = state.weapon and state.weapon:GetNoDraw()
    if state.weapon then state.weapon:SetNoDraw(true) end

    -- Bonemerged clothing follows the visible body.
    state.children = {}
    for _, child in ipairs(npc:GetChildren()) do
        if IsValid(child) and child ~= state.weapon and child:IsEffectActive(EF_BONEMERGE) then
            state.children[#state.children + 1] = child
            child:SetParent(rag)
        end
    end

    npc:AddEFlags(EFL_NO_THINK_FUNCTION)
    npc:AddFlags(FL_NOTARGET)
    npc:SetNoDraw(true)
    npc:SetSolid(SOLID_NONE)
    npc:SetMoveType(MOVETYPE_NONE)
    -- SOLID_NONE leaves the NPC's physics shadow active; teleported onto the ragdoll every poll, it shoves it along.
    npc:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
    local shadow = npc:GetPhysicsObject()
    if IsValid(shadow) then shadow:EnableCollisions(false) end
end

-- Puts the NPC's own flags back. Clothing stays on the ragdoll unless the NPC is standing up again.
local function restoreFlags(npc, state)
    if not IsValid(npc) then return end
    if not state.hadNoThink then npc:RemoveEFlags(EFL_NO_THINK_FUNCTION) end
    RT.ResumeAI(npc, state.ai)
    state.ai = nil
    if not state.hadNoTarget then npc:RemoveFlags(FL_NOTARGET) end
    npc:SetNoDraw(state.noDraw)
    npc:SetSolid(state.solid)
    npc:SetMoveType(state.moveType)
    npc:SetCollisionGroup(state.group)
    local shadow = npc:GetPhysicsObject()
    if IsValid(shadow) then shadow:EnableCollisions(state.shadowCollides) end
    if IsValid(state.weapon) then state.weapon:SetNoDraw(state.weaponNoDraw) end
    npc.RT_RagState = nil
end

local function detach(rag, state)
    hook.Run("DashReality.RagdollLeft", state.npc, rag)
    active[rag] = nil
    if IsValid(rag) then rag.RT_RagState = nil end
    state.npc.RT_RagState = nil
end

local function standUp(rag, state)
    local npc = state.npc
    local root = rag:GetPhysicsObjectNum(0)
    local pos = IsValid(root) and root:GetPos() or rag:GetPos()
    local yaw = IsValid(root) and root:GetAngles().y or rag:GetAngles().y

    local trace = util.TraceHull({
        start = pos + Vector(0, 0, 32),
        endpos = pos - Vector(0, 0, 128),
        mins = npc:OBBMins(),
        maxs = npc:OBBMaxs(),
        mask = MASK_NPCSOLID,
        filter = { npc, rag },
    })
    if trace.Hit and not trace.StartSolid then pos = trace.HitPos end

    for _, child in ipairs(state.children) do
        if IsValid(child) then child:SetParent(npc) end
    end

    detach(rag, state)
    restoreFlags(npc, state)
    npc:SetPos(pos)
    npc:SetAngles(Angle(0, yaw, 0))
    npc:SetLocalVelocity(vector_origin)
    npc:SetSchedule(SCHED_ALERT_STAND)
    rag:Remove()
end

local function convertUnsafe(npc, ply)
    local rag = ents.Create("prop_ragdoll")
    if not IsValid(rag) then return end
    npc.RT_PendingRag = rag

    rag:SetModel(npc:GetModel())
    rag:SetPos(npc:GetPos())
    rag:SetAngles(npc:GetAngles())
    rag:SetSkin(npc:GetSkin())
    rag:SetColor(npc:GetColor())
    rag:SetMaterial(npc:GetMaterial())
    for index = 0, npc:GetNumBodyGroups() - 1 do
        rag:SetBodygroup(index, npc:GetBodygroup(index))
    end
    rag:Spawn()
    rag:Activate()

    if rag:GetPhysicsObjectCount() < 2 then
        rag:Remove()
        npc.RT_NoRagdoll = true
        return
    end

    rag:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)
    if IsValid(ply) then
        rag:SetCreator(ply)
        if rag.CPPISetOwner then rag:CPPISetOwner(ply) end
    end
    copyPose(npc, rag)

    local state = {
        npc = npc,
        rag = rag,
        held = {},
        still = 0,
        moveType = npc:GetMoveType(),
        group = npc:GetCollisionGroup(),
        shadowCollides = not IsValid(npc:GetPhysicsObject()) or npc:GetPhysicsObject():IsCollisionEnabled(),
        solid = npc:GetSolid(),
        noDraw = npc:GetNoDraw(),
        hadNoTarget = npc:IsFlagSet(FL_NOTARGET),
        hadNoThink = npc:IsEFlagSet(EFL_NO_THINK_FUNCTION),
    }
    npc.RT_RagState = state
    rag.RT_RagState = state
    hideNPC(npc, rag, state)
    active[rag] = state
    hook.Run("DashReality.RagdollEntered", npc, rag)
    timer.Start("DashReality.RagdollPoll")
    npc.RT_PendingRag = nil
end

-- All-or-nothing: any failure removes the half-built ragdoll and leaves the NPC untouched.
local function convert(npc, ply)
    if not IsValid(npc) or npc:Health() <= 0 or npc.RT_RagState then return end

    local ok, err = pcall(convertUnsafe, npc, ply)
    if ok then return end

    ErrorNoHalt("[reality_tools] ragdoll swap failed: ", tostring(err), "\n")
    local rag = npc.RT_PendingRag
    npc.RT_PendingRag = nil
    if IsValid(rag) then
        local state = rag.RT_RagState
        if state then
            active[rag] = nil
            restoreFlags(npc, state)
        end
        rag:Remove()
    end
    npc.RT_RagState = nil
    npc.RT_NoRagdoll = true
end

hook.Add("PhysgunPickup", "DashReality.RagdollPickup", function(ply, ent)
    local state = ent.RT_RagState
    if state then
        -- The hidden NPC is only a data holder while its ragdoll stands in; grabbing it
        -- (the Physgun can still hit its physics shadow) would drag the body away from the ragdoll.
        if state.rag ~= ent then return false end
        state.held[ply] = true
        state.still = 0
        return
    end

    if not canConvert(ent) then return end
    if not util.IsValidRagdoll(ent:GetModel() or "") then
        ent.RT_NoRagdoll = true
        return
    end

    -- The held click re-grabs the new ragdoll on the next physgun tick.
    timer.Simple(0, function() convert(ent, ply) end)
    return false
end)

hook.Add("PhysgunDrop", "DashReality.RagdollDrop", function(ply, ent)
    local state = ent.RT_RagState
    if state and state.rag == ent then
        state.held[ply] = nil
        state.still = 0
    end
end)

local function pollState(rag, state)
    local npc = state.npc
    if not IsValid(npc) then
        -- The NPC was removed: leave the ragdoll behind as a plain prop.
        detach(rag, state)
        return
    end
    if not IsValid(rag) then
        detach(rag, state)
        restoreFlags(npc, state)
        if state.lastPos then npc:SetPos(state.lastPos) end
        npc:SetLocalVelocity(vector_origin)
        return
    end

    -- Teleporting the hidden NPC onto the ragdoll every poll shoves the ragdoll along, so only remember where it is.
    state.lastPos = rag:GetPos()

    for ply in pairs(state.held) do
        if not IsValid(ply) then state.held[ply] = nil end
    end

    local moving, fast, pinned = 0, 0, false
    for index = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(index)
        if IsValid(phys) then
            if phys:IsMotionEnabled() then
                moving = moving + 1
                if phys:GetVelocity():Length() > REST_SPEED then fast = fast + 1 end
            else
                -- A bone the player locked with the Physgun: they are posing the body, so keep it a ragdoll.
                pinned = true
            end
        end
    end

    -- A single bone can vibrate forever against a constraint (seen on a hand bone while the body lay
    -- still), so the body counts as settled when under a quarter of its bones are moving.
    -- Held, time-frozen, frozen in space by the physgun, or still moving: do not stand up yet.
    if state.timeFrozen or next(state.held) ~= nil or pinned or moving == 0 or fast > moving * 0.25 then
        state.still = 0
        return
    end

    state.still = state.still + POLL_INTERVAL
    if state.still >= RT.Float("rt_ragdoll_delay") then standUp(rag, state) end
end

-- The timer only runs while at least one swapped ragdoll exists (started in convertUnsafe).
timer.Create("DashReality.RagdollPoll", POLL_INTERVAL, 0, function()
    for rag, state in pairs(active) do pollState(rag, state) end
    if next(active) == nil then timer.Stop("DashReality.RagdollPoll") end
end)
if next(active) == nil then timer.Stop("DashReality.RagdollPoll") else timer.Start("DashReality.RagdollPoll") end

-- Damage taken by the ragdoll is applied to the hidden NPC; a lethal hit leaves the ragdoll as the corpse.
hook.Add("EntityTakeDamage", "DashReality.RagdollDamage", function(ent, dmg)
    local state = ent.RT_RagState
    if state and state.rag == ent and state.timeFrozen then return true end
    if not state or state.rag ~= ent or not RT.Bool("rt_ragdoll_damage_pass") then return end

    local npc = state.npc
    if not IsValid(npc) then return end

    local damageType = dmg:GetDamageType()
    if bit.band(damageType, DMG_CRUSH) ~= 0 and dmg:GetDamage() < 8 then return true end

    local world = game.GetWorld()
    local forwarded = DamageInfo()
    forwarded:SetAttacker(IsValid(dmg:GetAttacker()) and dmg:GetAttacker() or world)
    forwarded:SetInflictor(IsValid(dmg:GetInflictor()) and dmg:GetInflictor() or world)
    forwarded:SetDamage(dmg:GetDamage())
    forwarded:SetDamagePosition(dmg:GetDamagePosition())
    forwarded:SetDamageForce(dmg:GetDamageForce())

    if dmg:GetDamage() >= npc:Health() then
        forwarded:SetDamageType(bit.bor(damageType, DMG_REMOVENORAGDOLL))
        npc:SetPos(ent:GetPos())
        detach(ent, state)
        restoreFlags(npc, state)
    else
        forwarded:SetDamageType(damageType)
    end

    npc:TakeDamageInfo(forwarded)
    return true
end)

function RT.RagdollState(ent)
    local state = IsValid(ent) and ent.RT_RagState
    if state and state.rag == ent then return state end
end

-- Time-freezes a swapped ragdoll in its exact pose; it stands up as the NPC only after being thawed.
function RT.SetRagdollFrozen(state, frozen, ply)
    local rag = state.rag
    if not IsValid(rag) or not IsValid(state.npc) then return false end
    if (state.timeFrozen == true) == frozen then return false end
    if rag:IsPlayerHolding() then return false end
    if frozen then
        state.freezeBones = {}
        for index = 0, rag:GetPhysicsObjectCount() - 1 do
            local phys = rag:GetPhysicsObjectNum(index)
            if IsValid(phys) then
                state.freezeBones[index] = {phys = phys, motion = phys:IsMotionEnabled(),
                    velocity = Vector(phys:GetVelocity()), angular = Vector(phys:GetAngleVelocity())}
            end
        end
        if next(state.freezeBones) == nil then state.freezeBones = nil return false end
    end
    state.timeFrozen = frozen or nil
    state.freezeToken = frozen and {} or nil
    state.owner = frozen and ply or nil
    state.still = 0

    for index = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(index)
        if IsValid(phys) then
            if frozen then
                phys:SetVelocity(vector_origin)
                phys:AddAngleVelocity(-phys:GetAngleVelocity())
            end
            if frozen then
                phys:EnableMotion(false)
            else
                local saved = state.freezeBones and state.freezeBones[index]
                -- Compatibility: a ragdoll frozen by an older build has no
                -- snapshot; keep its former thaw behavior for that case.
                local motion = not saved or saved.phys ~= phys or saved.motion
                phys:EnableMotion(motion)
                if motion then
                    if saved and saved.phys == phys then
                        phys:SetVelocity(saved.velocity)
                        phys:AddAngleVelocity(saved.angular - phys:GetAngleVelocity())
                    end
                    phys:Wake()
                end
            end
        end
    end
    if not frozen then state.freezeBones = nil end
    rag:SetNW2Bool("RT_TimeFrozen", frozen)
    rag:EmitSound(frozen and "buttons/combine_button2.wav" or "buttons/combine_button1.wav", 70)
    return true
end

hook.Add("PostCleanupMap", "DashReality.RagdollReset", function()
    for rag in pairs(active) do active[rag] = nil end
end)
