-- Noclip Ghost: reduce observer interaction while noclipping. Custom AI may still perceive the player.
-- Convars noclip_ghost_* are declared in RT.SettingList (autorun) so they appear in the settings panel.

local GHOST_NW = "NoclipGhost"

if SERVER then
    local D = DashReality
    local cvEnabled = GetConVar("noclip_ghost_enabled")
    local cvAdmin = GetConVar("noclip_ghost_adminonly")
    local cvTransmit = GetConVar("noclip_ghost_prevent_transmit")
    local cvSilent = GetConVar("noclip_ghost_silent")
    local cvDamage = GetConVar("noclip_ghost_block_damage")

    local ghosts = D.GhostStates or {}
    D.GhostStates = ghosts
    local SWEEP_TIMER = "NoclipGhost.Sweep"
    local sweep
    local npcs, pending, cacheReady = {}, {}, false
    -- A retained timer would still call the previous source's sweep closure.
    timer.Remove(SWEEP_TIMER)

    local function clearCache()
        npcs, pending, cacheReady = {}, {}, false
    end
    local function seedNPCs()
        if cacheReady then return end
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and ent:IsNPC() then npcs[ent] = true end
        end
        cacheReady = true
    end
    local function ensureSweep()
        if next(ghosts) == nil then return end
        seedNPCs()
        if not timer.Exists(SWEEP_TIMER) then
            timer.Create(SWEEP_TIMER, 0.2, 0, function() sweep() end)
        end
    end

    local function isGhost(ply)
        return IsValid(ply) and ghosts[ply] ~= nil
    end

    local function wantsGhost(ply)
        if not cvEnabled:GetBool() then return false end
        if ply.NoclipGhostOptOut then return false end
        if not ply:Alive() or ply:GetMoveType() ~= MOVETYPE_NOCLIP then return false end
        if ply:InVehicle() then return false end
        if cvAdmin:GetBool() and not (ply:IsAdmin() or game.SinglePlayer()) then return false end
        return true
    end

    local function setTransmit(ply, state, hide)
        local others = {}
        for _, other in ipairs(player.GetAll()) do
            if other ~= ply then others[#others + 1] = other end
        end
        if #others == 0 then return end
        ply:SetPreventTransmit(others, hide)
        for wep in pairs(state.weapons) do
            if IsValid(wep) then wep:SetPreventTransmit(others, hide) end
        end
    end

    local function hideWeapons(ply, state)
        for _, wep in ipairs(ply:GetWeapons()) do
            if state.weapons[wep] == nil then
                state.weapons[wep] = wep:GetNoDraw()
                wep:SetNoDraw(true)
                wep:DrawShadow(false)
            end
        end
        local hide = cvTransmit:GetBool()
        if hide or state.transmitHidden then
            setTransmit(ply, state, hide)
            state.transmitHidden = hide
        end
    end

    local function addGhost(ply)
        local state = {
            weapons = {},
            hadNoTarget = ply:IsFlagSet(FL_NOTARGET),
            hadDontTouch = ply:IsFlagSet(FL_DONTTOUCH),
            wasNoDraw = ply:GetNoDraw(),
        }
        ghosts[ply] = state

        ply:AddFlags(FL_NOTARGET + FL_DONTTOUCH)
        ply:SetNoDraw(true)
        ply:DrawShadow(false)
        ply:SetNW2Bool(GHOST_NW, true)
        hideWeapons(ply, state)

        ensureSweep()
    end

    local function removeGhost(ply)
        local state = ghosts[ply]
        if not state then return end
        ghosts[ply] = nil

        if IsValid(ply) then
            setTransmit(ply, state, false)
            if not state.hadNoTarget then ply:RemoveFlags(FL_NOTARGET) end
            if not state.hadDontTouch then ply:RemoveFlags(FL_DONTTOUCH) end
            if not state.wasNoDraw then ply:SetNoDraw(false) end
            ply:DrawShadow(true)
            ply:SetNW2Bool(GHOST_NW, false)
        end
        for wep, wasNoDraw in pairs(state.weapons) do
            if IsValid(wep) then
                wep:SetNoDraw(wasNoDraw)
                wep:DrawShadow(true)
                if IsValid(ply) then wep:SetPreventTransmit(player.GetAll(), false) end
            end
        end
        if next(ghosts) == nil then
            timer.Remove(SWEEP_TIMER)
            clearCache()
        end
    end

    local function reevaluate(ply)
        if not IsValid(ply) then return end
        local want = wantsGhost(ply)
        if want and not ghosts[ply] then
            addGhost(ply)
        elseif not want and ghosts[ply] then
            removeGhost(ply)
        end
    end

    sweep = function()
        for ply, state in pairs(ghosts) do
            if IsValid(ply) then hideWeapons(ply, state) else ghosts[ply] = nil end
        end
        if next(ghosts) == nil then
            timer.Remove(SWEEP_TIMER)
            clearCache()
            return
        end
        -- Classify arrivals after their creation frame without scheduling one
        -- timer per entity. Existing non-NPC props are never revisited.
        for ent in pairs(pending) do
            if IsValid(ent) and ent:IsNPC() then npcs[ent] = true end
            pending[ent] = nil
        end
        -- Frameworks that keep their own target lists still honor Source's enemy memory.
        for npc in pairs(npcs) do
            if IsValid(npc) then
                local enemy = npc:GetEnemy()
                for ply in pairs(ghosts) do
                    if IsValid(ply) then
                        if enemy == ply then
                            npc:SetEnemy(NULL)
                            enemy = nil
                        end
                        npc:ClearEnemyMemory(ply)
                    end
                end
            else
                npcs[npc] = nil
            end
        end
    end

    hook.Add("OnEntityCreated", "NoclipGhost.NPCCache", function(ent)
        if next(ghosts) ~= nil then pending[ent] = true end
    end)
    hook.Add("EntityRemoved", "NoclipGhost.NPCCache", function(ent)
        npcs[ent], pending[ent] = nil, nil
    end)
    hook.Add("PostCleanupMap", "NoclipGhost.NPCCache", function()
        clearCache()
        if next(ghosts) ~= nil then seedNPCs() end
    end)

    hook.Add("PlayerNoClip", "NoclipGhost.Toggle", function(ply)
        timer.Simple(0, function() reevaluate(ply) end)
    end)

    -- Catches noclip set by other addons and convar/opt-out changes that fire no PlayerNoClip event.
    timer.Create("NoclipGhost.Poll", 0.25, 0, function()
        if not cvEnabled:GetBool() then
            -- Retire any active ghost states, then avoid enumerating every
            -- player on each poll while the feature is disabled.
            for ply in pairs(ghosts) do reevaluate(ply) end
            return
        end
        for _, ply in ipairs(player.GetAll()) do reevaluate(ply) end
    end)

    for _, name in ipairs({ "PlayerDeath", "PlayerSilentDeath", "PlayerSpawn", "PlayerDisconnected" }) do
        hook.Add(name, "NoclipGhost.Clear." .. name, function(ply) removeGhost(ply) end)
    end

    hook.Add("PlayerInitialSpawn", "NoclipGhost.NewObserver", function()
        timer.Simple(1, function()
            for ply, state in pairs(ghosts) do
                if IsValid(ply) then hideWeapons(ply, state) end
            end
        end)
    end)

    local function shielded(ent)
        return cvDamage:GetBool() and ent:IsPlayer() and isGhost(ent)
    end

    hook.Add("EntityTakeDamage", "NoclipGhost.NoDamage", function(ent, dmg)
        if shielded(ent) then
            dmg:ScaleDamage(0)
            return true
        end
    end)

    hook.Add("PlayerShouldTakeDamage", "NoclipGhost.NoPlayerDamage", function(ply)
        if shielded(ply) then return false end
    end)

    hook.Add("PlayerFootstep", "NoclipGhost.NoFootsteps", function(ply)
        if isGhost(ply) then return true end
    end)

    hook.Add("EntityEmitSound", "NoclipGhost.Silence", function(data)
        if not cvSilent:GetBool() then return end
        local ent = data.Entity
        if not IsValid(ent) then return end
        if isGhost(ent) then return false end
        local owner = ent:GetOwner()
        if IsValid(owner) and isGhost(owner) then return false end
    end)

    -- Report actual state, not just the player's preference. Noclip and server
    -- policy can prevent an opted-in player from becoming a ghost. Status never
    -- changes flags, permissions, movement or the player's saved preference.
    local function reportGhostStatus(ply)
        local actual, wanted = isGhost(ply), wantsGhost(ply)
        local state
        if actual ~= wanted then
            state = "transition pending"
        elseif actual and (not ply:IsFlagSet(FL_NOTARGET) or not ply:IsFlagSet(FL_DONTTOUCH) or not ply:GetNoDraw()) then
            state = "active, but observer flags or visibility were changed externally"
        elseif actual then
            state = "active (native no-target; damage protection "
                .. (cvDamage:GetBool() and "on" or "off") .. "; sound suppression "
                .. (cvSilent:GetBool() and "on" or "off") .. ")"
        elseif not cvEnabled:GetBool() then state = "inactive (disabled by server)"
        elseif ply.NoclipGhostOptOut then state = "inactive (opted out)"
        elseif not ply:Alive() then state = "inactive (player is not alive)"
        elseif ply:GetMoveType() ~= MOVETYPE_NOCLIP then state = "inactive (enter noclip to activate)"
        elseif ply:InVehicle() then state = "inactive (in vehicle)"
        else state = "inactive (admin access required)" end
        ply:ChatPrint("Noclip Ghost: " .. state .. ". Custom AI may still detect you.")
    end

    concommand.Add("noclip_ghost_status", function(ply)
        if IsValid(ply) then reportGhostStatus(ply) end
    end, nil, "Report your actual noclip ghost state without changing it.")

    concommand.Add("noclip_ghost", function(ply, _, args)
        if not IsValid(ply) then return end
        if args[1] == nil then
            ply.NoclipGhostOptOut = not ply.NoclipGhostOptOut
        else
            ply.NoclipGhostOptOut = not tobool(args[1])
        end
        reevaluate(ply)
        reportGhostStatus(ply)
    end, nil, "Toggle your own noclip ghost mode (optional argument 0/1).")

    hook.Add("ShutDown", "NoclipGhost.Shutdown", function()
        for ply in pairs(table.Copy(ghosts)) do removeGhost(ply) end
    end)

    for _, ply in ipairs(player.GetAll()) do reevaluate(ply) end
    ensureSweep()
else
    -- Another player's physgun beam would reveal the ghost's position; keep only our own.
    hook.Add("DrawPhysgunBeam", "NoclipGhost.HideBeam", function(ply)
        if IsValid(ply) and ply:GetNW2Bool(GHOST_NW) and ply ~= LocalPlayer() then return false end
    end)

    hook.Add("PrePlayerDraw", "NoclipGhost.HideModel", function(ply)
        if ply:GetNW2Bool(GHOST_NW) and ply ~= LocalPlayer() then return true end
    end)
end
