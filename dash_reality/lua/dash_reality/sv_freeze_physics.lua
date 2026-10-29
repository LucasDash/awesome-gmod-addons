-- Time freeze for native physics props and ragdolls. The original entity
-- remains targetable by Sandbox tools and properties; only its physics sleeps.
local RT = DashReality
local frozen = RT.FrozenPhysics or {}
RT.FrozenPhysics = frozen

local classes = {
    prop_physics = true,
    prop_physics_multiplayer = true,
    prop_physics_override = true,
    prop_ragdoll = true,
}

function RT.IsPhysicsFreezable(ent)
    if not IsValid(ent) or ent:IsPlayer() or ent:IsNPC() or ent.RT_RagState then return false end
    if not classes[ent:GetClass()] or ent:GetPhysicsObjectCount() < 1 then return false end
    return true
end

local function samePhysics(ent, info)
    return IsValid(ent) and IsValid(info.phys) and ent:GetPhysicsObjectNum(info.index) == info.phys
end

function RT.SetPhysicsFrozen(ent, wanted, owner, force)
    if not RT.IsPhysicsFreezable(ent) or type(wanted) ~= "boolean" then return false end
    local state = frozen[ent]
    if (state ~= nil) == wanted then return false end
    if ent:IsPlayerHolding() and not force then return false end

    if wanted then
        state = {owner = owner, bones = {}}
        for index = 0, ent:GetPhysicsObjectCount() - 1 do
            local phys = ent:GetPhysicsObjectNum(index)
            if IsValid(phys) then
                state.bones[#state.bones + 1] = {index=index, phys=phys, motion=phys:IsMotionEnabled(),
                    velocity=Vector(phys:GetVelocity()), angular=Vector(phys:GetAngleVelocity())}
            end
        end
        if #state.bones == 0 then return false end
        frozen[ent] = state
        for _,info in ipairs(state.bones) do
            local phys = info.phys
            phys:SetVelocity(vector_origin)
            phys:AddAngleVelocity(-phys:GetAngleVelocity())
            phys:EnableMotion(false)
        end
        ent:SetNW2Bool("RT_TimeFrozen", true)
        ent:CallOnRemove("DashReality.FrozenPhysics", function(e) frozen[e] = nil end)
    else
        frozen[ent] = nil
        ent:RemoveCallOnRemove("DashReality.FrozenPhysics")
        for _,info in ipairs(state.bones) do
            if samePhysics(ent, info) then
                local phys = info.phys
                phys:EnableMotion(info.motion)
                if info.motion then
                    phys:SetVelocity(info.velocity)
                    phys:AddAngleVelocity(info.angular - phys:GetAngleVelocity())
                    phys:Wake()
                end
            end
        end
        ent:SetNW2Bool("RT_TimeFrozen", false)
    end
    return true
end

-- Physgun/Gravity Gun manipulation can wake a locked object while held.
-- Repin it after release without touching the pre-freeze snapshot.
local function repin(ent)
    local state = frozen[ent]
    if not state then return end
    timer.Simple(0, function()
        if frozen[ent] ~= state or not IsValid(ent) or ent:IsPlayerHolding() then return end
        for _, info in ipairs(state.bones) do
            if samePhysics(ent, info) then
                info.phys:SetVelocity(vector_origin)
                info.phys:AddAngleVelocity(-info.phys:GetAngleVelocity())
                info.phys:EnableMotion(false)
            end
        end
    end)
end
hook.Add("PhysgunDrop", "DashReality.FrozenPhysics", function(_, ent) repin(ent) end)
hook.Add("GravGunOnDropped", "DashReality.FrozenPhysics", function(_, ent) repin(ent) end)
hook.Add("OnPlayerPhysicsDrop", "DashReality.FrozenPhysics", function(_, ent) repin(ent) end)
hook.Add("EntityTakeDamage", "DashReality.FrozenPhysics", function(ent) if frozen[ent] then return true end end)
hook.Add("PostCleanupMap", "DashReality.FrozenPhysics", function()
    for ent in pairs(frozen) do
        if IsValid(ent) then RT.SetPhysicsFrozen(ent, false, nil, true) else frozen[ent] = nil end
    end
end)
