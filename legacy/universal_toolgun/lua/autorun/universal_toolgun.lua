-- Developed by Lucas Dash : dashgang.net

local TOOLGUN_CLASS = "gmod_tool"
local PATCH_VERSION = 3
local PATCH_TIMER = "Universal.Toolgun.ApplyNativePatch"
local patchNativeWorldModel

local function canBePickedUpByNPCs()
    return true
end

local TOOL_SHOOT_SOUND = "Toolgun.Single"
local TOOL_MUZZLE_ATTACHMENT = 1
local TOOL_TRACE_RANGE = 8192
local ENEMY_ASSIST_TRACE_PADDING = 96
local ENEMY_ASSIST_ALIGNMENT_MIN = 0.55
local ENEMY_ASSIST_HULL_HALF_EXTENTS = Vector(6, 6, 6)
local ENEMY_ASSIST_HULL_MINS = -ENEMY_ASSIST_HULL_HALF_EXTENTS
local TOOL_TRACE_MASK = bit.bor(
    CONTENTS_SOLID,
    CONTENTS_MOVEABLE,
    CONTENTS_MONSTER,
    CONTENTS_WINDOW,
    CONTENTS_DEBRIS,
    CONTENTS_GRATE,
    CONTENTS_AUX
)

local conVarCache = {}
local function isConVarEnabled(name)
    local conVar = conVarCache[name]
    if not conVar then
        conVar = GetConVar(name)
        if not conVar then return false end
        conVarCache[name] = conVar
    end
    return conVar:GetBool()
end

-- Mirrors the player's SWEP:DoShootEffect, which cannot run for NPCs (Player:SetAnimation).
local function emitToolgunShot(weapon, startPos, hitPos)
    if not IsValid(weapon) or not isvector(hitPos) then return end
    weapon:EmitSound(weapon.ShootSound or TOOL_SHOOT_SOUND)

    local effect = EffectData()
    effect:SetOrigin(hitPos)
    effect:SetStart(startPos)
    effect:SetAttachment(TOOL_MUZZLE_ATTACHMENT)
    effect:SetEntity(weapon)
    util.Effect("ToolTracer", effect)
end

local function resolveShotStartAndDir(actor, shootPos, shootDir)
    local startPos = isvector(shootPos) and shootPos or actor:GetShootPos()
    local dir = isvector(shootDir) and shootDir:LengthSqr() > 0.001 and shootDir or actor:GetAimVector()
    if dir:LengthSqr() > 0.001 then
        dir = dir:GetNormalized()
    else
        dir = actor:GetAimVector():GetNormalized()
    end
    return startPos, dir
end

-- Stock Remover already refuses players; this also covers collateral damage to a player.
local function isProtectedFromRemoval(ent)
    if ent:IsPlayer() then return true end
    if ent:IsVehicle() and IsValid(ent:GetDriver()) then return true end

    local owner = ent:GetOwner()
    if IsValid(owner) and owner:IsPlayer() then return true end

    local parent = ent:GetParent()
    return IsValid(parent) and parent:IsPlayer()
end

local VANISH_REMOVE_DELAY = 0.1
local CORPSE_WINDOW = 1
local CORPSE_RADIUS_SQR = 150 * 150
local KILL_DAMAGE_TYPE = bit.bor(DMG_REMOVENORAGDOLL, DMG_ENERGYBEAM)

local function isLivingTarget(ent)
    return ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
end

-- Same dissolve the Remover plays, then hide the body and let it be removed.
local function vanish(ent)
    local effect = EffectData()
    effect:SetOrigin(ent:GetPos())
    effect:SetEntity(ent)
    util.Effect("entity_remove", effect, true, true)

    constraint.RemoveAll(ent)
    ent:SetNotSolid(true)
    ent:SetMoveType(MOVETYPE_NONE)
    ent:SetNoDraw(true)
    timer.Simple(VANISH_REMOVE_DELAY, function()
        if IsValid(ent) and not ent:IsPlayer() then ent:Remove() end
    end)
end

local corpseMarks = {}

-- Corpses spawned by gamemode or other addons arrive after the kill; catch them as they appear.
local function markCorpseWindow(victim)
    corpseMarks[#corpseMarks + 1] = {
        model = victim:GetModel(),
        pos = victim:GetPos(),
        expires = CurTime() + CORPSE_WINDOW
    }
end

if SERVER then
    hook.Add("OnEntityCreated", "Universal.ToolgunVanishCorpse", function(ent)
        if #corpseMarks == 0 then return end
        local now = CurTime()
        for index = #corpseMarks, 1, -1 do
            if corpseMarks[index].expires < now then table.remove(corpseMarks, index) end
        end
        if #corpseMarks == 0 or not ent:IsValid() then return end

        -- Model and position are only set after creation, so inspect next tick.
        timer.Simple(0, function()
            if not IsValid(ent) or ent:IsPlayer() or ent:IsNPC() then return end
            local class = ent:GetClass()
            if class ~= "prop_ragdoll" and class ~= "prop_physics" then return end
            for _, mark in ipairs(corpseMarks) do
                if ent:GetModel() == mark.model and ent:GetPos():DistToSqr(mark.pos) <= CORPSE_RADIUS_SQR then
                    vanish(ent)
                    return
                end
            end
        end)
    end)
end

local function killLiving(weapon, actor, target, hitPos)
    local damage = DamageInfo()
    damage:SetAttacker(actor)
    damage:SetInflictor(weapon)
    damage:SetDamage(math.max(target:Health(), target:GetMaxHealth(), 1) * 10)
    damage:SetDamageType(KILL_DAMAGE_TYPE)
    damage:SetDamageForce(vector_origin)
    damage:SetDamagePosition(hitPos)

    -- The effect needs the entity while it still has its model, so play it first.
    vanish(target)
    pcall(target.TakeDamageInfo, target, damage)
    return true
end

local function killPlayer(weapon, actor, victim, hitPos)
    if not isConVarEnabled("universal_toolgun_kill_players") then return false end
    if not victim:Alive() or victim:HasGodMode() then return false end
    if hook.Run("UniversalToolgunCanKill", actor, victim, weapon) == false then return false end

    local damage = DamageInfo()
    damage:SetAttacker(actor)
    damage:SetInflictor(weapon)
    damage:SetDamage(math.max(victim:Health(), 1) * 10)
    damage:SetDamageType(DMG_ENERGYBEAM)
    damage:SetDamageForce(vector_origin)
    damage:SetDamagePosition(hitPos)
    -- Third-party damage hooks can throw; the kill must still finish.
    pcall(victim.TakeDamageInfo, victim, damage)
    if victim:Alive() then victim:Kill() end

    local ragdoll = victim:GetRagdollEntity()
    if IsValid(ragdoll) then vanish(ragdoll) end
    markCorpseWindow(victim)
    return true
end

local function canUseEnemyAssist(actor)
    if not IsValid(actor) or not actor:IsNPC() then return false end
    return isConVarEnabled("universal_toolgun_enemy_assist")
end

local function tryEnemyAssistTrace(actor, shootPos, fallbackDir, mask, filter)
    if not canUseEnemyAssist(actor) then return nil end

    local enemy = actor:GetEnemy()
    if not IsValid(enemy) or enemy == actor then return nil end

    local toEnemy = enemy:WorldSpaceCenter() - shootPos
    local toEnemyLenSqr = toEnemy:LengthSqr()
    if toEnemyLenSqr <= 1 then return nil end

    local enemyDir = toEnemy:GetNormalized()
    if fallbackDir:Dot(enemyDir) < ENEMY_ASSIST_ALIGNMENT_MIN then return nil end

    local assistRange = math.min(math.sqrt(toEnemyLenSqr) + ENEMY_ASSIST_TRACE_PADDING, TOOL_TRACE_RANGE)
    local assistTrace = util.TraceHull({
        start = shootPos,
        endpos = shootPos + enemyDir * assistRange,
        mask = mask,
        filter = filter,
        mins = ENEMY_ASSIST_HULL_MINS,
        maxs = ENEMY_ASSIST_HULL_HALF_EXTENTS
    })
    if assistTrace.Hit and assistTrace.Entity == enemy then return assistTrace end

    return nil
end

local function traceShot(actor, weapon, shootPos, shootDir, mask)
    local startPos, dir = resolveShotStartAndDir(actor, shootPos, shootDir)
    local filter = {actor, weapon}
    local trace = util.TraceLine({
        start = startPos,
        endpos = startPos + dir * TOOL_TRACE_RANGE,
        mask = mask,
        filter = filter
    })

    if not trace.Hit or not IsValid(trace.Entity) then
        trace = tryEnemyAssistTrace(actor, startPos, dir, mask, filter) or trace
    end
    return trace, startPos
end

local function npcShootPrimary(self, shootPos, shootDir)
    if CLIENT then return end
    local actor = self:GetOwner()
    if not IsValid(actor) then return end

    -- Optional NPC addons can claim a typed primary action through this
    -- generic extension point without making the Toolgun depend on them.
    local handled, accepted, result = hook.Run(
        "UniversalToolgunNPCPrimaryAction", actor, self, shootPos, shootDir
    )
    if handled == true then
        local agentTrace, agentStart = traceShot(actor, self, shootPos, shootDir, nil)
        emitToolgunShot(self, agentStart, agentTrace.HitPos)
        return accepted, result
    end

    if not isConVarEnabled("universal_toolgun_npc_remover") or not actor:IsNPC() then return end

    local creator = actor:GetCreator()
    local permissionOwner = IsValid(creator) and creator:IsPlayer() and creator or actor

    -- Treat each native AI shot as a normal left-click of Sandbox's Remover.
    self.Mode = "remover"
    local tool = self:GetToolObject("remover")
    if not istable(tool) then return end

    local trace, startPos = traceShot(actor, self, shootPos, shootDir, TOOL_TRACE_MASK)

    -- The beam and sound belong to the trigger pull, not to a successful hit or removal.
    emitToolgunShot(self, startPos, trace.HitPos)

    if not trace.Hit or not IsValid(trace.Entity) then return end

    local target = trace.Entity
    local living = isLivingTarget(target)
    if living then
        if target == actor then return end
        if target:IsPlayer() then
            return killPlayer(self, actor, target, trace.HitPos) or nil
        end
    elseif isProtectedFromRemoval(target) then
        return
    end

    local checkOK = pcall(tool.CheckObjects, tool)
    if not checkOK then return end
    local allowedOK, modeAllowed = pcall(tool.Allowed, tool)
    if not allowedOK or not modeAllowed then return end

    -- Preserve Sandbox prop-protection/tool policies using the NPC's spawner.
    local permissionOK, permitted = pcall(
        gamemode.Call, "CanTool", permissionOwner, trace, "remover", tool, 1
    )
    if not permissionOK or not permitted then return end

    if living and isConVarEnabled("universal_toolgun_instakill") then
        return killLiving(self, actor, target, trace.HitPos)
    end

    -- Stock remover awards an achievement with Player:SendLua. Use the NPC's
    -- creator context, or a harmless stand-in for map-created NPCs.
    local callbackOwner = permissionOwner
    if callbackOwner == actor then
        callbackOwner = {SendLua = function() end}
    end
    local previousOwner = rawget(tool, "GetOwner")
    tool.GetOwner = function() return callbackOwner end
    local callbackOK, accepted = pcall(tool.LeftClick, tool, trace)
    tool.GetOwner = previousOwner
    if not callbackOK or accepted ~= true then return end

    return true
end

local function npcShootSecondary()
    -- NPC secondary-fire schedules never enter player Sandbox tool modes.
end

local function applyNativePatch()
    local native = weapons.GetStored(TOOLGUN_CLASS)
    if not istable(native) then return false end

    if native.CALUniversalToolgunPatchVersion ~= PATCH_VERSION then
        native.NPCUsable = true
        native.CanBePickedUpByNPCs = canBePickedUpByNPCs
        native.NPCShoot_Primary = npcShootPrimary
        native.NPCShoot_Secondary = npcShootSecondary
        native.CALUniversalToolgun = true
        native.CALUniversalToolgunPatchVersion = PATCH_VERSION
        weapons.Register(native, TOOLGUN_CLASS)
    end

    if SERVER then
        list.Set("NPCUsableWeapons", TOOLGUN_CLASS, {
            class = TOOLGUN_CLASS,
            title = "Tool Gun"
        })
    end

    if CLIENT and isfunction(patchNativeWorldModel) then
        patchNativeWorldModel(native)
    end

    return true
end

if CLIENT then
    local SCREEN_SIZE = 256
    local SCREEN_BACKGROUND = surface.GetTextureID("models/weapons/v_toolgun/screen_bg")
    local NPC_SCREEN_RT = GetRenderTarget("CALNPCRemoverScreen", SCREEN_SIZE, SCREEN_SIZE)
    local NPC_SCREEN_MATERIAL = "cal_npc_remover_screen"
    local NPC_SCREEN_MATERIAL_PATH = "!" .. NPC_SCREEN_MATERIAL
    local SCROLL_SPEED = 250
    local TEXT_CENTER_Y = 104
    local TEXT_PADDING = 64
    -- The RT keeps refreshing for a couple of frames after the last world-model draw.
    local RENDER_GRACE_FRAMES = 2
    local lastDrawFrame = -math.huge
    local screenIndexByModel = {}
    local cachedPhrase, cachedTextWidth, cachedTextHeight

    CreateMaterial(NPC_SCREEN_MATERIAL, "UnlitGeneric", {
        ["$basetexture"] = NPC_SCREEN_RT:GetName(),
        ["$model"] = "1"
    })

    surface.CreateFont("CALNPCRemoverScreen", {
        font = "Helvetica",
        size = 60,
        weight = 900
    })

    local function drawScrollingText(text, y, width)
        surface.SetFont("CALNPCRemoverScreen")
        if text ~= cachedPhrase then
            cachedPhrase = text
            cachedTextWidth, cachedTextHeight = surface.GetTextSize(text)
            cachedTextWidth = cachedTextWidth + TEXT_PADDING
        end
        local textWidth = cachedTextWidth
        y = y - cachedTextHeight / 2

        local x = RealTime() * SCROLL_SPEED % textWidth * -1
        while x < width do
            surface.SetTextColor(0, 0, 0, 255)
            surface.SetTextPos(x + 3, y + 3)
            surface.DrawText(text)
            surface.SetTextColor(255, 255, 255, 255)
            surface.SetTextPos(x, y)
            surface.DrawText(text)
            x = x + textWidth
        end
    end

    -- Resolved once per model; an empty list means the model is not ready, so retry later.
    local function findScreenMaterialIndex(weapon)
        local model = weapon:GetModel()
        local cached = screenIndexByModel[model]
        if cached ~= nil then return cached end

        local materials = weapon:GetMaterials()
        if not materials or #materials == 0 then return false end

        local found = false
        for index, material in ipairs(materials) do
            if string.find(string.lower(material), "screen", 1, true) then
                found = index - 1
                break
            end
        end
        screenIndexByModel[model] = found
        return found
    end

    -- Only a player-held Tool Gun shows its real mode; pickups and NPC-held guns show Remover.
    local function isHeldByPlayer(weapon)
        local owner = weapon:GetOwner()
        return IsValid(owner) and owner:IsPlayer()
    end

    -- SetSubMaterial runs only when the displayed state changes, not every frame.
    local function syncRemoverDisplay(weapon, wanted)
        local applied = weapon.CALNPCDisplayMaterialIndex or nil
        local index = wanted and findScreenMaterialIndex(weapon) or nil
        if applied == index then return index ~= nil end

        if applied then weapon:SetSubMaterial(applied, nil) end
        if index then weapon:SetSubMaterial(index, NPC_SCREEN_MATERIAL_PATH) end
        weapon.CALNPCDisplayMaterialIndex = index
        return index ~= nil
    end

    -- Drawn before the frame renders, so no render-target switch happens mid-scene.
    hook.Add("PreRender", "Universal.ToolgunRemoverScreen", function()
        if FrameNumber() - lastDrawFrame > RENDER_GRACE_FRAMES then return end

        render.PushRenderTarget(NPC_SCREEN_RT)
        cam.Start2D()
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetTexture(SCREEN_BACKGROUND)
            surface.DrawTexturedRect(0, 0, SCREEN_SIZE, SCREEN_SIZE)
            drawScrollingText(language.GetPhrase("tool.remover.name"), TEXT_CENTER_Y, SCREEN_SIZE)
        cam.End2D()
        render.PopRenderTarget()
    end)

    patchNativeWorldModel = function(native)
        if native.CALWorldModelPatchVersion == PATCH_VERSION then return end

        -- Keep the first stock function so repeated patching never wraps our own wrapper.
        if not native.CALWorldModelPatched then
            native.CALStockDrawWorldModel = native.DrawWorldModel
            native.CALWorldModelPatched = true
        end
        local stockDrawWorldModel = native.CALStockDrawWorldModel

        native.DrawWorldModel = function(self, flags)
            if syncRemoverDisplay(self, not isHeldByPlayer(self)) then
                lastDrawFrame = FrameNumber()
                return self:DrawModel(flags)
            end
            if isfunction(stockDrawWorldModel) then
                return stockDrawWorldModel(self, flags)
            end
            return self:DrawModel(flags)
        end
        native.CALWorldModelPatchVersion = PATCH_VERSION
    end
end

if SERVER then
    if not GetConVar("universal_toolgun_npc_remover") then
        CreateConVar("universal_toolgun_npc_remover", "1", FCVAR_ARCHIVE,
            "Let native AI NPCs use the Universal Toolgun as the Sandbox Remover.")
    end

    if not GetConVar("universal_toolgun_instakill") then
        CreateConVar("universal_toolgun_instakill", "1", FCVAR_ARCHIVE,
            "NPC Tool Gun hits on living NPCs kill them instantly and make the body vanish.")
    end

    if not GetConVar("universal_toolgun_kill_players") then
        CreateConVar("universal_toolgun_kill_players", "1", FCVAR_ARCHIVE,
            "Allow NPC Tool Gun hits to kill players (godmode and the UniversalToolgunCanKill hook can veto).")
    end

    if not GetConVar("universal_toolgun_enemy_assist") then
        CreateConVar("universal_toolgun_enemy_assist", "1", FCVAR_ARCHIVE,
            "Bias NPC Tool Gun traces toward their live enemy to tighten short firing windows.")
    end
end

-- Autorun may precede gamemode weapon registration; retry until gmod_tool is
-- available so both a clean startup and an in-game hot reload apply the patch.
if applyNativePatch() then
    timer.Remove(PATCH_TIMER)
else
    timer.Create(PATCH_TIMER, 0.25, 80, function()
        if applyNativePatch() then timer.Remove(PATCH_TIMER) end
    end)
end

hook.Add("OnReloaded", "Universal.ToolgunReapplyNativePatch", function()
    timer.Create(PATCH_TIMER, 0.25, 80, function()
        if applyNativePatch() then timer.Remove(PATCH_TIMER) end
    end)
end)
