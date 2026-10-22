-- Polestar Planner companion. GPL-3.0-only; see LICENSE and NOTICE.txt.
-- Own lifecycle, preferences and frames. Polestar keeps its guide/progress state.
local ADDON, ns = ...
_G.PolestarPlanner = ns
ns.name = ADDON
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"
ns.stage = "Community preview"
ns.L = setmetatable({}, { __index = function(_, key) return key end })

local function copy(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}; seen[value] = out
	for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
	return out
end
ns.Copy = copy

function ns.Print(message)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff4fd1c5Polestar Planner|r: " .. tostring(message)) end
end
function ns.SafeCall(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and geterrorhandler then geterrorhandler()(err) end
	return ok
end

local listeners = {}
function ns.On(event, fn)
	local list = listeners[event] or {}; listeners[event] = list
	local handle = { event = event, fn = fn, live = true }
	list[#list + 1] = handle
	return handle
end
function ns.Off(handle) if handle then handle.live = false end end
function ns.Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for i = 1, #list do if list[i].live then ns.SafeCall(list[i].fn, ...) end end
end

local events, eventFrame = {}, CreateFrame("Frame")
function ns.RegisterEvent(event, fn)
	local list = events[event]
	if not list then
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then return false end
		list = {}; events[event] = list
	end
	for _, entry in ipairs(list) do if entry.live and entry.fn == fn then return true end end
	list[#list + 1] = { live = true, fn = fn }
	return true
end
function ns.UnregisterEvent(event, fn)
	for _, entry in ipairs(events[event] or {}) do if entry.fn == fn then entry.live = false end end
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, entry in ipairs(events[event] or {}) do if entry.live then ns.SafeCall(entry.fn, event, ...) end end
end)

local defaults, paths = {}, {}
local function keys(path)
	if not paths[path] then
		local result = {}; for key in path:gmatch("[^.]+") do result[#result + 1] = key end
		paths[path] = result
	end
	return paths[path]
end
local function lookup(root, path)
	for _, key in ipairs(keys(path)) do
		if type(root) ~= "table" then return nil end
		root = root[key]
	end
	return root
end
function ns.DB()
	if type(PolestarPlannerDB) ~= "table" then PolestarPlannerDB = { schema = 1 } end
	if type(PolestarPlannerDB.settings) ~= "table" then PolestarPlannerDB.settings = {} end
	return PolestarPlannerDB
end
function ns.RegisterDefaults(section, values)
	defaults[section] = defaults[section] or {}
	for key, value in pairs(values) do defaults[section][key] = copy(value) end
end
function ns.GetDefault(path) return lookup(defaults, path) end
function ns.Get(path)
	local value = lookup(ns.DB().settings, path)
	if value == nil then return ns.GetDefault(path) end
	return value
end
function ns.Set(path, value)
	local pathKeys, current = keys(path), ns.DB().settings
	for i = 1, #pathKeys - 1 do
		local key = pathKeys[i]
		if type(current[key]) ~= "table" then current[key] = {} end
		current = current[key]
	end
	if value == ns.GetDefault(path) then value = nil end
	current[pathKeys[#pathKeys]] = copy(value)
	ns.Fire("SETTING_CHANGED", path, ns.Get(path))
end

-- Only the three viewer preferences move. Deep copy, never alias or remove
-- legacy settings; the old installation remains a valid rollback source.
function ns.MigrateSettings()
	local db = ns.DB()
	if db.migrations and db.migrations.legacyViewer == 1 then return false end
	local old = type(PolestarDB) == "table" and PolestarDB.settings
	for _, section in ipairs({ "liveDashboard", "liveMiniMap", "liveMap" }) do
		if db.settings[section] == nil and type(old) == "table" and type(old[section]) == "table" then
			db.settings[section] = copy(old[section])
		end
	end
	db.migrations = db.migrations or {}
	db.migrations.legacyViewer = 1
	return true
end

-- The companion owns its visual settings. No core UI preference is written.
ns.RegisterDefaults("ui", {
	font = "game", scheme = "dusk", bgOpacity = 0.94, brightness = 0,
	reduceMotion = false, matchAccent = true, matchFont = false,
	classAccent = false, accent = false, bgColor = false,
	border = true, borderColor = false, borderAccent = false, borderSize = 1,
	band = true, shadow = true, menuScale = 1,
})

local initialized, loggedIn = false, false
local initQueue, loginQueue = {}, {}
function ns.OnInit(fn) if initialized then ns.SafeCall(fn) else initQueue[#initQueue + 1] = fn end end
function ns.OnLogin(fn) if loggedIn then ns.SafeCall(fn) else loginQueue[#loginQueue + 1] = fn end end
function ns.IsLoggedIn() return loggedIn end
local function initialize(_, name)
	if name ~= ADDON or initialized then return end
	ns.MigrateSettings()
	initialized = true
	for _, fn in ipairs(initQueue) do ns.SafeCall(fn) end
	initQueue = {}
end
local function login()
	if loggedIn then return end
	if not initialized then initialize(nil, ADDON) end
	loggedIn = true
	for _, fn in ipairs(loginQueue) do ns.SafeCall(fn) end
	loginQueue = {}
end
ns.RegisterEvent("ADDON_LOADED", initialize)
ns.RegisterEvent("PLAYER_LOGIN", login)

ns.Commands = {}
function ns.RegisterCommand(name, fn, help)
	ns.Commands[name:lower()] = { run = fn, help = help }
end
