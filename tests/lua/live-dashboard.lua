-- Live dashboard test client. Sample values only; no planner simulation or
-- SavedVariables checkpoint is involved. Install after uistub.install().
livestub = {
	player = { map = 1429, x = 44, y = 39, facing = 0 },
	level = 6, xp = 450, xpMax = 2800, rested = 140,
	health = 139, healthMax = 180, power = 220, powerMax = 250,
	rate = 7200, sessionXP = 600, sessionSeconds = 300, timeToLevel = 1175,
	reads = { position = 0, geometry = 0, xp = 0, illustratedArt = 0 },
	maps = {
		[1429] = { name = "Elwynn Forest", mapID = 1429, mapType = 3, parentMapID = 1415 },
		[1436] = { name = "Westfall", mapID = 1436, mapType = 3, parentMapID = 1415 },
		[1415] = { name = "Eastern Kingdoms", mapID = 1415, mapType = 2, parentMapID = 947 },
		[947] = { name = "Azeroth", mapID = 947, mapType = 1, parentMapID = 0 },
	},
	geometry = { legs = { { kind = "walk", current = true, pts = {
		{ 0, 805, 560 }, { 0, 805, 550 }, { 0, 824.5, 524 },
	} } } },
}
local S = livestub

local function readable(value)
	if value == S.secret then return nil end
	return value
end
S.secret = {}
issecretvalue = function(value) return value == S.secret end

C_Map = C_Map or {}
C_Map.GetMapInfo = function(id) return S.maps[id] end
C_Map.GetBestMapForUnit = function() return S.player and S.player.map end
C_Map.GetPlayerMapPosition = function(map)
	local p = S.player
	if not p or p.map ~= map or p.x == nil or p.y == nil then return nil end
	return { x = p.x / 100, y = p.y / 100 }
end
local function illustratedArt()
	S.reads.illustratedArt = S.reads.illustratedArt + 1
	error("The live terrain view must not request illustrated world-map art")
end
C_Map.GetMapArtLayers = illustratedArt
C_Map.GetMapArtLayerTextures = illustratedArt
C_Map.GetMapArtID = function(id) return id end
C_MapExplorationInfo = { GetExploredMapTextures = function() return {} end }
GetPlayerFacing = function() return S.player and S.player.facing end
UnitLevel = function() return S.level end
UnitXP = function() return S.xp end
UnitXPMax = function() return S.xpMax end
GetXPExhaustion = function() return S.rested end
UnitName = function() return "Testdruid" end
UnitClass = function() return "Druid", "DRUID", 11 end
UnitHealth = function() return S.health end
UnitHealthMax = function() return S.healthMax end
UnitPower = function() return S.power end
UnitPowerMax = function() return S.powerMax end
UnitPowerType = function() return 0, "MANA" end
UnitStat = function(_, i) return 10 + i, 20 + i, 0, 0 end
GetZoneText = function() return S.maps[S.player and S.player.map] and S.maps[S.player.map].name or "Unknown" end
GetSubZoneText = function() return "Northshire Valley" end
GetNumQuestLogEntries = function() return 3, 2 end
GetMoney = function() return 12345 end

function S.install()
	-- Four native minimap blocks cover the 1000-by-500-yard test zone.
	-- Their partial overlap at the northern/western edge exercises UV crop
	-- direction without substituting the illustrated map API.
	PolestarPlanner.LiveTerrain = {
		build = "test", product = "wow_classic_beta", adt = 1600 / 3,
		continents = { [0] = {
			name = "Eastern Kingdoms", wdt = 20000001,
			bounds = { minCol = 30, maxCol = 31, minRow = 30, maxRow = 31 },
			sea = { 8, 16, 16 },
			tiles = { { 30, 30, 20003030 }, { 31, 30, 20003031 },
				{ 30, 31, 20003130 }, { 31, 31, 20003131 } },
		} },
	}
	local setTexture = stub.Methods.SetTexture
	stub.Methods.SetTexture = function(self, file, ...)
		if S.failTerrain and type(file) == "number" and file >= 20000000 then
			self.texture = nil
			return false
		end
		return setTexture(self, file, ...)
	end
	local C = Polestar.Compat
	C.Readable = readable
	C.IsSecret = function(value) return value == S.secret end
	C.GetPlayerFacing = function() return GetPlayerFacing() end
	C.GetPlayerInfo = function()
		return { name = "Testdruid", realm = "Test Realm", level = S.level, race = "NightElf", class = "DRUID", faction = "Alliance" }
	end
	C.GetPlayerMapPosition = function()
		S.reads.position = S.reads.position + 1
		local p = S.player
		if not p then return nil end
		return p.map, p.x, p.y
	end
	C.GetMapName = function(id) return S.maps[id] and S.maps[id].name end
	C.GetZoneText = function() return GetZoneText(), GetSubZoneText() end
	C.MapToWorld = function(map, x, y)
		if not S.maps[map] or type(x) ~= "number" or type(y) ~= "number" then return nil end
		return 0, 1000 - y * 5, 1000 - x * 10
	end
	C.WorldToMap = function(c, wx, wy, map)
		if c ~= 0 or not S.maps[map] or type(wx) ~= "number" or type(wy) ~= "number" then return nil end
		return (1000 - wy) / 10, (1000 - wx) / 5
	end
	C.GetPlayerWorldPosition = function()
		local p = S.player
		if not p then return nil end
		return C.MapToWorld(p.map, p.x, p.y)
	end
	Polestar.Nav.GetRouteGeometry = function()
		S.reads.geometry = S.reads.geometry + 1
		return S.geometry
	end
	Polestar.Nav.LiveCoords = function(point)
		if not point then return nil end
		return point.map, point.x, point.y
	end
	Polestar.QoL = Polestar.QoL or {}
	Polestar.QoL.GetXPStats = function()
		S.reads.xp = S.reads.xp + 1
		if S.xpDisabled then return nil end
		return { level = S.level, xp = S.xp, xpMax = S.xpMax, remaining = S.xpMax - S.xp,
			percent = S.xp / S.xpMax * 100, rested = S.rested, rate = S.rate,
			sessionRate = S.rate, rollingRate = S.rate, sessionXP = S.sessionXP,
			sessionSeconds = S.sessionSeconds, timeToLevel = S.timeToLevel,
			sessionKills = 12, sessionQuests = 3, splits = {} }
	end
end

function S.clearReads()
	S.reads.position, S.reads.geometry, S.reads.xp = 0, 0, 0
	S.reads.illustratedArt = 0
end

function S.shown(list)
	local count = 0
	for _, object in ipairs(list or {}) do if object:IsShown() then count = count + 1 end end
	return count
end

function S.texts(frame)
	local out = {}
	local function walk(object)
		if not object:IsVisible() then return end
		if object.kind == "FontString" then out[#out + 1] = object:GetText() or "" end
		for _, region in ipairs(object.regions or {}) do walk(region) end
		for _, child in ipairs(object.children or {}) do walk(child) end
	end
	walk(frame)
	return table.concat(out, "\n")
end
