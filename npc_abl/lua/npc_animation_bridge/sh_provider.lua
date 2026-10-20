local Bridge = NPCAnimationBridge
local Provider = {}
Bridge.Provider = Provider

-- Client IsValidModel can reject an existing model until the server precaches
-- it. Local availability is enough for catalog/viewer selection; server
-- Preview.Play retains authoritative model validity and playback checks.
function Provider.IsModelAvailable(model)
    if not isstring(model) or #model > 240
        or not model:match("^models/[%w_%.%-%/]+%.mdl$") then return false end
    if CLIENT then return file.Exists(model, "GAME") end
    return util.IsValidModel(model)
end

function Provider.Sources()
    local result = {}
    local base = wOS and wOS.DynaBase
    if not istable(base) or not isfunction(base.GetAllSources) then return result end
    for _, source in pairs(base:GetAllSources() or {}) do
        if istable(source) then
            for _, kind in ipairs({"Shared", "Female", "Male", "Zombie"}) do
                local path = source[kind]
                if isstring(path) and path:sub(1, 7) == "models/" and path:sub(-4) == ".mdl" then
                    result[#result + 1] = {name = tostring(source.Name or path), kind = kind, model = path}
                end
            end
        end
    end
    table.sort(result, function(a, b) return a.name .. a.kind < b.name .. b.kind end)
    return result
end

function Provider.PlayerModel(model)
    model = string.lower(tostring(model or ""))
    if model:sub(1, 14) == "models/player/" and Provider.IsModelAvailable(model) then return model end
    local suffix = model:match("^models/humans/(group0[123]/[a-z]+_%d+%.mdl)$")
    if suffix then
        local path = "models/player/" .. suffix
        if Provider.IsModelAvailable(path) then return path end
    end
    local named = {
        ["models/police.mdl"] = "models/player/police.mdl",
        ["models/alyx.mdl"] = "models/player/alyx.mdl",
        ["models/barney.mdl"] = "models/player/barney.mdl",
        ["models/gman_high.mdl"] = "models/player/gman_high.mdl",
        ["models/gman.mdl"] = "models/player/gman_high.mdl",
        ["models/mossman.mdl"] = "models/player/mossman.mdl"
    }
    local path = named[model]
    if path and Provider.IsModelAvailable(path) then return path end
    return nil, "no_known_player_counterpart"
end

function Provider.PlaybackModel(actorModel, explicitModel, useCounterpart, carrier)
    local model = string.Trim(tostring(explicitModel or ""))
    if model ~= "" then return model end
    if carrier == "female" then return "models/player/group01/female_02.mdl" end
    if carrier == "male" then return "models/player/group01/male_02.mdl" end
    if useCounterpart then return Provider.PlayerModel(actorModel) or actorModel end
    return actorModel
end

-- Client-only, explicit catalog query; never mounts/reloads DynaBase models.
function Provider.Sequences(model, sourceModel, options)
    if not CLIENT then return nil, "client_catalog_required" end
    options = options or {}
    if not istable(options) then return nil, "invalid_options" end
    if options.includeControllers~=nil and type(options.includeControllers)~="boolean" then return nil,"invalid_options" end
    local rate, cycle = options.rate or 1, options.cycle or 0
    if not Bridge.Catalog.IsFinite(rate) or rate < 0.1 or rate > 4
        or not Bridge.Catalog.IsFinite(cycle) or cycle < 0 or cycle >= 1 then return nil, "invalid_options" end
    if not Provider.IsModelAvailable(model) then return nil, "model_unavailable" end
    if sourceModel and sourceModel ~= "" and not Provider.IsModelAvailable(sourceModel) then return nil, "source_model_unavailable" end
    local target = ClientsideModel(model, RENDERGROUP_OTHER)
    if not IsValid(target) then return nil, "model_unavailable" end
    target:SetNoDraw(true)
    local source
    if sourceModel and sourceModel ~= "" then
        source = ClientsideModel(sourceModel, RENDERGROUP_OTHER)
        if not IsValid(source) then target:Remove() return nil, "source_model_unavailable" end
        source:SetNoDraw(true)
    end
    local result = {}
    local counts = {missing = 0, controller = 0, controllerCandidates=0, candidateNames={}, base=0, additive = 0, world=0, context=0, internal=0, duration = 0, durationLimit = 0, eligible = 0}
    local ok = pcall(function()
    local names = (source or target):GetSequenceList()
    for _, name in ipairs(names) do
        local sequence = target:LookupSequence(name)
        if name ~= "reference" and name ~= "ragdoll"
            and not name:find("_wiltos_enabled_", 1, true)
            then
            local info=sequence>=0 and target:GetSequenceInfo(sequence) or nil
            local reason = sequence >= 0 and Bridge.Catalog.PreviewReason(info) or nil
            if sequence < 0 then counts.missing = counts.missing + 1
            elseif Bridge.Catalog.BaseReason(info) then
                counts.base=counts.base+1
                local baseReason=Bridge.Catalog.BaseReason(info)
                if baseReason=="additive_sequence_requires_base_motion" then counts.additive=counts.additive+1
                elseif baseReason=="world_sequence_requires_base_motion" then counts.world=counts.world+1
                elseif baseReason=="local_sequence_requires_context" then counts.context=counts.context+1
                else counts.internal=counts.internal+1 end
            elseif reason == "pose_driven_sequence_requires_controller" then
                counts.controller = counts.controller + 1
                if options.includeControllers and math.floor((info.flags or 0)/4)%2~=1 then
                    result[#result+1]=name; counts.controllerCandidates=counts.controllerCandidates+1; counts.candidateNames[name]=true
                end
            elseif reason then counts.additive = counts.additive + 1
            else
                local duration = target:SequenceDuration(sequence)
                if not Bridge.Catalog.IsFinite(duration) or duration <= 0 then counts.duration = counts.duration + 1
                elseif duration * (1 - cycle) / rate > 30 then counts.durationLimit = counts.durationLimit + 1
                else result[#result + 1] = name; counts.eligible = counts.eligible + 1 end
            end
        end
    end
    end)
    if IsValid(source) then source:Remove() end
    target:Remove()
    if not ok then return nil, "catalog_query_failed" end
    table.sort(result)
    return result, nil, counts
end
