-- Polestar 0.2.5 and 0.2.6 read contracts. All private core access lives here.
-- Borrowed snapshots are read-only. No guide advancement or navigation writes
-- are exposed; the library button explicitly opens Polestar's own picker.
local _, ns = ...
local Adapter = { testedVersion = "0.2.6", testedCommit = "39f0b8b2be9b9330b2a3617ab54b7c034169aedd" }
ns.Adapter = Adapter
local unpack = unpack or table.unpack

local function core() return type(_G.Polestar) == "table" and _G.Polestar or nil end
local function resolve(section, method)
	local owner = core()
	owner = owner and owner[section]
	local fn = type(owner) == "table" and owner[method]
	return type(fn) == "function" and fn or nil
end
local function packed(...) return { n = select("#", ...), ... } end
local function read(fn, ...)
	if type(fn) ~= "function" then return nil end
	local values = packed(pcall(fn, ...))
	if values[1] then return unpack(values, 2, values.n) end
	Adapter.lastError = tostring(values[2])
	return nil
end
local function proxy(section, names, fallback)
	local allowed, wrappers = {}, {}
	for _, method in ipairs(names) do allowed[method] = true end
	return setmetatable({}, { __index = function(_, method)
		if not allowed[method] then return nil end
		if not resolve(section, method) and not (fallback and fallback[method]) then return nil end
		if not wrappers[method] then
			wrappers[method] = function(...)
				local fn = resolve(section, method)
				if fn then return read(fn, ...) end
				if fallback and fallback[method] then return fallback[method](...) end
			end
		end
		return wrappers[method]
	end })
end

ns.Engine = proxy("Engine", { "GetGuide", "GetStepCount", "GetStepIndex", "GetLiveStep", "GetStepView", "WantsQuest" }, {
	GetStepView = function() return nil end,
	GetStepCount = function() return 0 end,
})
ns.Nav = proxy("Nav", { "GetRouteGeometry", "GetTarget", "LiveCoords", "RGB", "GetTravelData" })
ns.Transit = proxy("Transit", { "Now", "Riding" })
ns.Compat = proxy("Compat", {
	"MapToWorld", "WorldToMap", "GetPlayerMapPosition", "GetPlayerFacing", "GetPlayerInfo",
	"GetNpcID", "IsOnTaxi",
	"Readable", "IsSecret", "ItemIcon", "IsQuestReadyForTurnIn", "ItemName", "SpellName", "SpellIcon",
	"ItemLink", "SpellLink", "RequestItem", "RequestSpell",
	"IsOnQuest", "GetQuestTitle",
}, {
	IsSecret = function(value) return issecretvalue and issecretvalue(value) or false end,
	Readable = function(value) if not (issecretvalue and issecretvalue(value)) then return value end end,
})
ns.QoL = proxy("QoL", { "GetXPStats", "GetHearth" })
ns.RoutePlan = proxy("RoutePlan", { "GetTurnIn", "Describe" })
-- Codex.Load only asks stock Polestar to load its optional lookup data. The
-- service layer requests it once, outside combat; it changes no guide state.
ns.Codex = proxy("Codex", { "IsLoaded", "Load", "Npc", "WithRole" })
ns.UI = proxy("UI", {
	"PlainGoalText", "StepSummary", "GoalText", "ReadingGoal", "GoalLine",
	"GoalProgress", "GoalSubline", "GoalDetail", "ShowPicker",
})
ns.NavRegions = {}
function ns.NavRegions.ForGoal(goal)
	local p = core()
	local layers = p and p.Nav and p.Nav.layers
	if layers and type(layers.Regions) == "function" then return read(layers.Regions, goal) end
	return ns.FallbackRegions and ns.FallbackRegions.ForGoal(goal) or nil
end
function Adapter.CoreSetting(path)
	-- Read display preferences only; never change stock settings.
	if path ~= "qol.xpTracker" and path ~= "maps.flightTimer" and path ~= "nav.alerts"
		and path ~= "nav.alertBanner" then return nil end
	local p = core()
	return read(p and p.Get, path)
end
function Adapter.TravelUIShown(kind)
	local name = kind == "flight" and "PolestarFlightTimer" or "PolestarTransitAlert"
	local frame = _G[name]
	return frame and type(frame.IsShown) == "function" and read(frame.IsShown, frame) == true or false
end
-- The guide's fly target can still be the departure flight master in the air.
-- Prefer the taxi actually selected, then a current flight leg. Borrowed core
-- records and geometry are never changed; callers receive a small fresh value.
function Adapter.FlightDestination(geometry)
	local airborne = read(resolve("Compat", "IsOnTaxi"))
	local function safe(value)
		return not (ns.Compat.IsSecret and ns.Compat.IsSecret(value))
	end
	local function finite(value)
		return safe(value) and type(value) == "number" and value == value
			and value > -math.huge and value < math.huge
	end
	local function destination(c, wx, wy, label)
		if finite(c) and c >= 0 and finite(wx) and finite(wy) then
			return { c = c, wx = wx, wy = wy, label = label }
		end
	end
	if not safe(airborne) or airborne ~= true then return nil end
	local p = core()
	local maps = p and p.Maps
	local name = type(maps) == "table" and read(maps.GetFlight) or nil
	if not safe(name) or type(name) ~= "string" or name == "" then name = nil end
	if name then
		local id = read(maps.TaxiNodeByName, name, read(maps.Faction))
		local data = read(resolve("Nav", "GetTravelData"))
		local node = finite(id) and type(data) == "table" and type(data.taxiById) == "table" and data.taxiById[id]
		if type(node) == "table" then
			local found = destination(node.c, node.wx, node.wy, name)
			if found then return found end
		end
		-- An observed but unresolved taxi may differ from the planned flight.
		-- Never attach its name to coordinates from a different route.
		return nil
	end
	if geometry == nil then geometry = read(resolve("Nav", "GetRouteGeometry")) end
	if type(geometry) ~= "table" or type(geometry.legs) ~= "table" then return nil end
	for _, leg in ipairs(geometry.legs) do
		if type(leg) == "table" and leg.current then
			if leg.kind ~= "flight" or type(leg.pts) ~= "table" then return nil end
			local point = leg.pts[#leg.pts]
			if type(point) == "table" then return destination(point[1], point[2], point[3], name or "Flight destination") end
			return nil
		end
	end
end
-- Read the stock step-key choice and visible target slot; never alter them.
function Adapter.NpcAction()
 local p=core()
 local q=p and p.QoL
 local b=q and q.Buttons
 local anchor=b and b.target
 if not (b and type(b.StepAction)=='function' and type(b.MacroSafeName)=='function'
  and type(q.On)=='function' and read(q.On,'targetButton') and anchor
  and type(anchor.IsShown)=='function' and not read(anchor.IsShown,anchor)) then return nil end
 -- Stock 0.2.6 can publish the step before its coalesced target frame is
 -- shown. Read the intended mob targets as well as the frame visibility,
 -- so our secure NPC button never occupies a slot stock is about to use.
 if type(b.TargetNames)=='function' then
  local targets=read(b.TargetNames)
  if type(targets)=='table' and next(targets)~=nil then return nil end
 end
 local kind,name=read(b.StepAction)
 if kind~='npc' then
  name=nil
  -- Curing the Sick (6124.1) credits Sickly Deer (12298), but its use
  -- goal keeps the salve as the step-key action. Supply a separate target
  -- in the unused slot; the item button and cure tracking stay with stock.
  local view,raw=read(q.CurrentStep)
  for i,gv in ipairs(view and view.goals or {}) do
   local rg=raw and raw[i] or gv
   if gv.t=='use' and rg.quest==6124 and rg.oi==1 and rg.item==15826
    and read(q.Open,gv) and read(resolve('Compat','IsOnQuest'),6124)==true then
    name=read(p.Names and p.Names.Npc,12298) or 'Sickly Deer'
    break
   end
  end
 end
 if not read(b.MacroSafeName,name) then return nil end
 return {name=name,anchor=anchor,scale=read(anchor.GetScale,anchor) or 1}
end
function Adapter.Status()
	local p = core()
	return {
		version = p and p.version,
		guide = resolve("Engine", "GetGuide") ~= nil and resolve("Engine", "GetStepView") ~= nil,
		routes = resolve("Nav", "GetRouteGeometry") ~= nil,
		coordinates = resolve("Compat", "MapToWorld") ~= nil and resolve("Compat", "WorldToMap") ~= nil,
	}
end

local bridges, bridgedCore = {}, nil
function Adapter.Connect()
	local p = core()
	if p == bridgedCore then return end
	if bridgedCore and type(bridgedCore.Off) == "function" then
		for _, handle in ipairs(bridges) do read(bridgedCore.Off, handle) end
	end
	bridges, bridgedCore = {}, p
	if not p or type(p.On) ~= "function" then return end
	for _, name in ipairs({
		"GUIDE_CHANGED", "STEP_CHANGED", "STEP_UPDATED", "GUIDES_REGISTERED", "PACKS_CHANGED",
		"GUIDE_COMPLETED", "WAYPOINT_CHANGED", "TABS_CHANGED", "QOL_XP_UPDATED",
		"NAV_TRANSIT", "SETTING_CHANGED",
	}) do
		local event = name == "SETTING_CHANGED" and "CORE_SETTING_CHANGED" or name
		local handle = read(p.On, name, function(...) ns.Fire(event, ...) end)
		if handle then bridges[#bridges + 1] = handle end
	end
end
Adapter.Connect()
ns.OnInit(Adapter.Connect)
ns.OnLogin(Adapter.Connect)


