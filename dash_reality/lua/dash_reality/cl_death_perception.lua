-- Death Perception (client): a first-person death with a sensory cutoff.
-- Reimplements the standalone addon's behaviour on one fraction value instead of a state machine.

local RT = DashReality

local cvEnable = CreateClientConVar("rt_dp_enable", "1", true, false, "Enable the death perception effect.", 0, 1)
local cvDelay = CreateClientConVar("rt_dp_delay", "0.25", true, false, "Seconds from death until the senses are fully cut off.", 0, 3)
local cvPov = CreateClientConVar("rt_dp_pov", "1", true, false, "View your death from the ragdoll's eyes.", 0, 1)
local cvColor = CreateClientConVar("rt_dp_colormode", "0", true, false, "0 none, 1 black and white, 2 high contrast, 3 red.", 0, 3)
local cvBlur = CreateClientConVar("rt_dp_blur", "0", true, false, "Blur vision while dying.", 0, 1)
local cvCutoff = CreateClientConVar("rt_dp_cutoff", "1", true, false, "0 keep vision, 1 black out instantly, 2 fade to black.", 0, 2)
local cvHearing = CreateClientConVar("rt_dp_hearing", "1", true, false, "Silence all sound once the senses are cut off.", 0, 1)

local blurMat = Material("pp/blurscreen")
local deathStart
local fraction = 0
local hearingCut = false
local lastAlive = Angle()
local headHidden = {}

local function restoreSenses()
    deathStart, fraction = nil, 0
    if hearingCut then
        hearingCut = false
        RunConsoleCommand("soundfade", "0", "1")
    end
end

hook.Add("Think", "DashReality.DeathPerception", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    if ply:Alive() then
        lastAlive = ply:EyeAngles()
        if deathStart or hearingCut then restoreSenses() end
        return
    end
    if not cvEnable:GetBool() then return end

    deathStart = deathStart or CurTime()
    fraction = math.Clamp((CurTime() - deathStart) / math.max(cvDelay:GetFloat(), 0.01), 0, 1)
    if fraction >= 1 and cvHearing:GetBool() and not hearingCut then
        hearingCut = true
        RunConsoleCommand("soundfade", "100", "99999")
    end
end)

-- Colour and blur are screen-space effects, so they belong before the HUD is drawn.
hook.Add("RenderScreenspaceEffects", "DashReality.DeathPerception", function()
    if fraction <= 0 or not cvEnable:GetBool() then return end
    local mode = cvColor:GetInt()
    if mode == 0 then return end

    local tint = mode == 3
    DrawColorModify({
        ["$pp_colour_addr"] = tint and fraction * 2 or 0,
        ["$pp_colour_addg"] = 0,
        ["$pp_colour_addb"] = 0,
        ["$pp_colour_brightness"] = mode == 2 and -fraction or 0,
        ["$pp_colour_contrast"] = mode == 2 and 1 + fraction * 5 or 1,
        ["$pp_colour_colour"] = tint and 1 or 1 - fraction,
        ["$pp_colour_mulr"] = tint and fraction * 2 or 0,
        ["$pp_colour_mulg"] = 0,
        ["$pp_colour_mulb"] = 0,
    })
end)

hook.Add("DrawOverlay", "DashReality.DeathPerception", function()
    if fraction <= 0 or not cvEnable:GetBool() then return end
    local ply = LocalPlayer()
    if IsValid(ply) and ply:GetViewEntity() ~= ply then return end
    local w, h = ScrW(), ScrH()

    if cvBlur:GetBool() then
        surface.SetDrawColor(255, 255, 255, 255)
        surface.SetMaterial(blurMat)
        for _ = 1, math.ceil(5 * fraction) do
            blurMat:SetFloat("$blur", 5 * fraction)
            blurMat:Recompute()
            render.UpdateScreenEffectTexture()
            surface.DrawTexturedRect(-1, -1, w + 2, h + 2)
        end
    end

    local cutoff = cvCutoff:GetInt()
    if cutoff == 1 and fraction >= 1 then
        surface.SetDrawColor(0, 0, 0, 255)
        surface.DrawRect(0, 0, w, h)
    elseif cutoff == 2 then
        surface.SetDrawColor(0, 0, 0, 255 * fraction ^ 2)
        surface.DrawRect(0, 0, w, h)
    end
end)

RT.AddViewModifier("death_perception", 100, function(ply, view)
    if not cvEnable:GetBool() or not cvPov:GetBool() then return end
    if ply:Alive() or ply:GetViewEntity() ~= ply then return end

    local rag = ply:GetRagdollEntity()
    if not IsValid(rag) then return end
    local eyes = rag:GetAttachment(rag:LookupAttachment("eyes"))
    if not eyes then return end

    -- The head would fill the camera, so shrink it once per ragdoll.
    if not headHidden[rag] then
        local head = rag:LookupBone("ValveBiped.Bip01_Head1")
        if head then rag:ManipulateBoneScale(head, Vector(0.01, 0.01, 0.01)) end
        headHidden[rag] = true
    end

    -- Blend from where the player was looking to where the ragdoll's head points.
    eyes.Ang:Normalize()
    view.origin = eyes.Pos
    view.angles = LerpAngle(math.sqrt(fraction), lastAlive, eyes.Ang)
    view.znear = 1
    return true
end)

timer.Create("DashReality.DeathPerception.Prune", 30, 0, function()
    for rag in pairs(headHidden) do
        if not IsValid(rag) then headHidden[rag] = nil end
    end
end)
