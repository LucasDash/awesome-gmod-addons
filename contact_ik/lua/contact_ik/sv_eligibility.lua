-- Read-only native NPC policy; the hint changes no schedules, goals or forces.
local K=ContactIK
local published=setmetatable({}, {__mode="k"})
function K.NPCPresentationBlocked(ent)
    if not IsValid(ent) or not ent:IsNPC() or ent:IsScripted() or ent:Health()<=0 then return true end
    local state=ent:GetNPCState()
    return state==NPC_STATE_SCRIPT or state==NPC_STATE_DEAD or state==NPC_STATE_COMBAT or IsValid(ent:GetActiveWeapon())
end
function K.RefreshNPCEligibility()
    for _,ent in ipairs(ents.FindByClass("npc_*")) do
        if ent:IsNPC() and not ent:IsScripted() then
            local rig=K.Describe(ent)
            if rig.arms[1] or rig.arms[2] then
                ent:SetNW2Bool("ContactIK.NPCBlocked",K.NPCPresentationBlocked(ent))
                published[ent]=true
            end
        end
    end
end
function K.Shutdown()
    timer.Remove("ContactIK.NPCEligibility")
    for ent in pairs(published) do if IsValid(ent) then ent:SetNW2Bool("ContactIK.NPCBlocked",true) end end
    published=setmetatable({}, {__mode="k"})
end
timer.Create("ContactIK.NPCEligibility",.5,0,K.RefreshNPCEligibility)
K.RefreshNPCEligibility()
