-- Named server-session settings. Profiles never apply themselves on load.
local D = DashReality
local ROOT = "dash_reality/profiles"
local CHANNEL = "DashReality.ProfileList"
util.AddNetworkString(CHANNEL)

local function authorized(ply)
    return not IsValid(ply) or game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin()
end
local function notify(ply, text)
    if IsValid(ply) then ply:ChatPrint("[Dash Reality] " .. text) else print("[Dash Reality] " .. text) end
end
local function profileName(raw)
    if not isstring(raw) then return end
    local name = string.lower(raw)
    if #name < 1 or #name > 32 or not string.match(name, "^[%w_-]+$") then return end
    return name
end
local function catalog()
    local result = {}
    for _, def in ipairs(D.SettingList or {}) do
        result[def.name] = {min=def.min, max=def.max, boolean=def.type == "bool"}
    end
    for _, def in ipairs(D.GeneralSettings or {}) do
        if def.realm == "server" then result[def.convar] = {min=def.min,max=def.max,boolean=def.type == "bool"} end
    end
    for _, def in ipairs(D.ToolgunSettings or {}) do result[def.convar] = {min=0,max=1,boolean=true} end
    return result
end
local function listProfiles()
    local files = file.Find(ROOT .. "/*.json", "DATA") or {}
    local names = {}
    for _, filename in ipairs(files) do
        local name = profileName(string.sub(filename, 1, -6))
        if name and filename == name .. ".json" then names[#names+1] = name end
    end
    table.sort(names)
    while #names > 128 do names[#names] = nil end
    return names
end
local function save(ply, name, replace)
    local path = ROOT .. "/" .. name .. ".json"
    if file.Exists(path, "DATA") and not replace then return false, "Profile already exists; use Update saved profile." end
    local values = {}
    for key, def in pairs(catalog()) do
        local cv = GetConVar(key)
        if cv then values[key] = def.boolean and (cv:GetBool() and 1 or 0) or cv:GetFloat() end
    end
    local encoded = util.TableToJSON({version=1, settings=values}, true)
    if not encoded or #encoded > 65536 then return false, "Could not encode profile." end
    file.CreateDir(ROOT)
    file.Write(path, encoded)
    if file.Read(path, "DATA") ~= encoded then return false, "Could not write profile." end
    return true, "Saved profile '" .. name .. "'."
end
local function load(ply, name)
    local content = file.Read(ROOT .. "/" .. name .. ".json", "DATA")
    if not content or #content > 65536 then return false, "Profile not found or too large." end
    local record = util.JSONToTable(content)
    if not istable(record) or record.version ~= 1 or not istable(record.settings) then return false, "Invalid profile." end
    local allowed, pending, count = catalog(), {}, 0
    for key, value in pairs(record.settings) do
        local def, cv = allowed[key], GetConVar(key)
        if not def or not cv or not isnumber(value) or value ~= value or math.abs(value) == math.huge
            or value < def.min or value > def.max or def.boolean and value ~= 0 and value ~= 1 then
            return false, "Profile contains an unavailable or invalid setting."
        end
        pending[#pending+1] = {cv=cv, value=value, boolean=def.boolean}
        count = count + 1
    end
    if count == 0 then return false, "Profile contains no settings." end
    for _, item in ipairs(pending) do
        if item.boolean then item.cv:SetInt(item.value) else item.cv:SetFloat(item.value) end
    end
    return true, "Loaded profile '" .. name .. "'."
end
function D.SessionProfile(ply, action, rawName, replace)
    if not authorized(ply) then return false, "Host or superadmin only." end
    if action == "list" then
        local names = listProfiles()
        if IsValid(ply) then
            net.Start(CHANNEL) net.WriteUInt(#names, 8)
            for _, name in ipairs(names) do net.WriteString(name) end
            net.Send(ply)
        else print("[Dash Reality] Profiles: " .. table.concat(names, ", ")) end
        return true
    end
    local name = profileName(rawName)
    if not name then return false, "Use 1–32 letters, numbers, underscores or hyphens." end
    if action == "save" then return save(ply, name, replace == true) end
    if action == "load" then return load(ply, name) end
    return false, "Unknown profile action."
end
concommand.Add("dash_profile", function(ply, _, args)
    local ok, message = D.SessionProfile(ply, args[1], args[2], args[3] == "replace")
    if message then notify(ply, message) end
end, nil, "Save, load or list Dash Reality server session profiles (host or superadmin only).")
