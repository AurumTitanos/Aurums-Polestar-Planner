-- The live dashboard's own map. OpenMap's minimap-detail renderer supplies
-- its background and lettering; the native terrain remains available while
-- new artwork cannot be loaded. Both views read
-- Polestar's current navigation geometry; it never changes the world map,
-- minimap, selected guide step, navigation target, or player input.
-- Only visible frames sample live position (5 Hz). No external bridge.
local ADDON, ns = ...
local LM = {}
ns.LiveMap = LM
ns.RegisterDefaults("liveMap", { objectives = true, areaStyle = "regions", questie = true, routeColor = "cyan", routePulse = false })

local min, max, abs = math.min, math.max, math.abs
local TICK, LIMIT, MANUAL_ZOOM_PAUSE = 0.2, 1600, 5
-- One continent at a time. The supported client has 988 Kalimdor tiles and
-- 736 Eastern Kingdoms tiles; this covers either whole continent without
-- silently cutting off at the old 256 illustrated-art tile limit.
local TILE_LIMIT = 1024
local DOT = "Interface\\AddOns\\Polestar\\Media\\Nav\\pin-fill"
local COLORS = {
	walk = { 0.90, 0.73, 0.40 }, direct = { 1, 0.7, 0.25 },
	flight = { 0.4, 0.9, 0.55 }, boat = { 0.6, 0.7, 1 },
	zeppelin = { 0.6, 0.7, 1 }, tram = { 0.8, 0.65, 1 }, lift = { 0.8, 0.65, 1 },
}
local ROUTE_COLORS = {
	cyan = { 0.08, 0.90, 1 }, white = { 1, 1, 1 }, pink = { 1, 0.35, 0.85 },
}

local function numeric(v)
	local C = ns.Compat
	if C and C.IsSecret and C.IsSecret(v) then return false end
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end

-- Frame only the walk ahead on this map. Walks can be split at ramps or
-- choke points; keep those adjoining legs, but stop at a transport, a gap,
-- another continent, or the zone boundary. Completed vertices are omitted.
function LM.RemainingWalkBounds(geometry, fromIndex, b, x, y)
	if not (geometry and type(geometry.legs) == "table" and b and numeric(x) and numeric(y)) then return nil end
	local start
	for i, leg in ipairs(geometry.legs) do if leg.current then start = i; break end end
	if not start then return nil end
	local out = { x0 = x, x1 = x, y0 = y, y1 = y }
	local lastX, lastY, count = x, y, 0
	for i = start, #geometry.legs do
		local leg = geometry.legs[i]
		local pts = leg.pts
		if leg.kind ~= "walk" or type(pts) ~= "table" or #pts < 2 then break end
		for j = i == start and max(2, fromIndex or 2) or 1, #pts do
			local p = pts[j]
			if not (type(p) == "table" and p[1] == b.c and numeric(p[2]) and numeric(p[3])) then return count > 0 and out or nil end
			local nx, ny = (p[3] - b.left) * b.kx * 100, (p[2] - b.top) * b.ky * 100
			-- A later walk must actually join the preceding walk. Never fit a
			-- faraway disconnected path merely because both legs say 'walk'.
			if i > start and j == 1 and ((nx - lastX) / b.kx / 100)^2 + ((ny - lastY) / b.ky / 100)^2 > 60^2 then
				return count > 0 and out or nil
			end
			local t = 1
			if nx < 0 then t = min(t, -lastX / (nx - lastX)) elseif nx > 100 then t = min(t, (100 - lastX) / (nx - lastX)) end
			if ny < 0 then t = min(t, -lastY / (ny - lastY)) elseif ny > 100 then t = min(t, (100 - lastY) / (ny - lastY)) end
			nx, ny = lastX + (nx - lastX) * t, lastY + (ny - lastY) * t
			out.x0, out.x1, out.y0, out.y1 = min(out.x0, nx), max(out.x1, nx), min(out.y0, ny), max(out.y1, ny)
			lastX, lastY, count = nx, ny, count + 1
			if t < 1 then return out end
		end
	end
	return count > 0 and out or nil
end

function LM.AutoZoomLevel(w, h, lw, lh, x, y, bounds)
	if not (bounds and numeric(w) and numeric(h) and numeric(lw) and numeric(lh)) or min(w, h, lw, lh) <= 0 then return nil end
	-- Keep the player centered, leave room for pins, and retain 240 yards of
	-- nearby context at arrival. This limit affects automatic framing only.
	local rx = max(120, max(abs(bounds.x0 - x), abs(bounds.x1 - x)) * lw / 100 + 20)
	local ry = max(120, max(abs(bounds.y0 - y), abs(bounds.y1 - y)) * lh / 100 + 20)
	local scale = min(max(1, w - 48) / (2 * rx), max(1, h - 48) / (2 * ry))
	return max(1, scale / min(w / lw, h / lh))
end

function LM.EaseAutoZoom(current, target, elapsed)
	if not (numeric(current) and numeric(target) and numeric(elapsed)) then return current end
	-- Finish the transition rather than repainting every terrain texture for
	-- an indefinitely shrinking, visually imperceptible scale difference.
	if abs(target - current) <= max(1, abs(target)) * 0.0005 then return target end
	-- Zoom out promptly for a new destination; ease in more slowly while
	-- approaching it. Elapsed time, not refresh count, controls the motion.
	local amount = 1 - math.exp(-clamp(elapsed, 0, 1) / (target < current and 0.35 or 1.1))
	return current + (target - current) * amount
end

-- Pure helpers shared with tests. Coordinates in the view are pixels down
-- and right from its top left. A zoom of one fits the entire map.
function LM.ComputeView(w, h, lw, lh, zoom, fx, fy)
	if not (numeric(w) and numeric(h) and numeric(lw) and numeric(lh)) or min(w, h, lw, lh) <= 0 then return nil end
	zoom, fx, fy = numeric(zoom) and zoom or 1, numeric(fx) and fx or 50, numeric(fy) and fy or 50
	local s = min(w / lw, h / lh) * max(1, zoom)
	local dw, dh = lw * s, lh * s
	if not (numeric(s) and numeric(dw) and numeric(dh)) then return nil end
	local ox = w / 2 - clamp(fx or 50, 0, 100) / 100 * dw
	local oy = h / 2 - clamp(fy or 50, 0, 100) / 100 * dh
	ox = dw <= w and (w - dw) / 2 or clamp(ox, w - dw, 0)
	oy = dh <= h and (h - dh) / 2 or clamp(oy, h - dh, 0)
	return { width = w, height = h, drawWidth = dw, drawHeight = dh, offsetX = ox, offsetY = oy, scale = s }
end

function LM.Project(v, x, y)
	if not (v and numeric(x) and numeric(y)) then return nil end
	return v.offsetX + x / 100 * v.drawWidth, v.offsetY + y / 100 * v.drawHeight
end

local unavailableInstances = {}
local function instanceMap(id)
	local entry = numeric(id) and id < 0 and ((ns.LiveInstanceMaps and ns.LiveInstanceMaps[-id]) or unavailableInstances[-id])
	if entry and entry.requires then
		local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
		if call(loaded, entry.requires) ~= true then return unavailableInstances[-id] end
	end
	return entry
end

local function mapInfo(id)
	local entry = instanceMap(id)
	if entry then return { mapID = id, name = entry.name, mapType = 4, parentMapID = 0 } end
	return id and C_Map and call(C_Map.GetMapInfo, id) or nil
end

local function unitOnMap(id, unit)
	local entry = instanceMap(id)
	if entry then
		-- Reference atlas floors are not calibrated to live world positions.
		if entry.floors or entry.unavailable or type(UnitPosition) ~= "function" then return end
		local ok, wx, wy, _, instance = pcall(UnitPosition, unit)
		if not ok or not (numeric(wx) and numeric(wy) and numeric(instance)) or instance ~= -id then return end
		return (wy - entry.left) / (entry.right - entry.left), (wx - entry.top) / (entry.bottom - entry.top)
	end
	local pos = C_Map and call(C_Map.GetPlayerMapPosition, id, unit)
	if not pos or ns.Compat and ns.Compat.IsSecret and ns.Compat.IsSecret(pos) then return end
	if type(pos.GetXY) == "function" then return call(pos.GetXY, pos) end
	return pos.x, pos.y
end

local function readPlayer()
	if call(IsInInstance) == true then
		local id = call(function() return select(8, GetInstanceInfo()) end)
		if numeric(id) and id > 0 and not instanceMap(-id) then
			local best = C_Map and call(C_Map.GetBestMapForUnit, "player")
			local info = mapInfo(best)
			if not (info and (info.mapType == 4 or info.mapType == 5)) then
				unavailableInstances[id] = { unavailable = true, name = call(GetInstanceInfo) or "Instance" }
			end
		end
		if numeric(id) and instanceMap(-id) then
			local x, y = unitOnMap(-id, "player")
			if numeric(x) and numeric(y) then return -id, x * 100, y * 100 end
			return -id
		end
	end
	local C = ns.Compat
	local m, x, y = call(C and C.GetPlayerMapPosition)
	if numeric(m) and numeric(x) and numeric(y) and x >= 0 and x <= 100 and y >= 0 and y <= 100 then return m, x, y end
	-- Dungeon maps can be available while the client withholds live positions.
	m = C_Map and call(C_Map.GetBestMapForUnit, "player")
	local info = mapInfo(m)
	if info and (info.mapType == 4 or info.mapType == 5) then return m end
end

local function positionOn(mapID, pm, px, py)
	if not (pm and numeric(px) and numeric(py)) then return nil end
	if pm == mapID then return px, py end
	local source, dest = mapInfo(pm), mapInfo(mapID)
	if source and source.mapType == 4 or dest and dest.mapType == 4 then return nil end
	local C = ns.Compat
	local c, wx, wy = call(C and C.MapToWorld, pm, px, py)
	if not (numeric(c) and numeric(wx) and numeric(wy)) then return nil end
	local x, y = call(C and C.WorldToMap, c, wx, wy, mapID)
	if numeric(x) and numeric(y) then return x, y end
end

local function worldBounds(mapID)
	local entry = instanceMap(mapID)
	if entry then
		if entry.floors or entry.unavailable then return nil end
		return { c = -mapID, left = entry.left, right = entry.right, top = entry.top, bottom = entry.bottom,
			kx = 1 / (entry.right - entry.left), ky = 1 / (entry.bottom - entry.top) }
	end
	local C = ns.Compat
	local c, top, left = call(C and C.MapToWorld, mapID, 0, 0)
	local c2, bottom, right = call(C and C.MapToWorld, mapID, 100, 100)
	if not (numeric(c) and numeric(c2) and numeric(top) and numeric(left) and numeric(bottom) and numeric(right)) then return nil end
	if c ~= c2 or top <= bottom or left <= right then return nil end
	return { c = c, left = left, right = right, top = top, bottom = bottom, kx = 1 / (right - left), ky = 1 / (bottom - top) }
end

-- Flights can leave the player's zone. Choose the smallest supported parent
-- map containing both ends, then frame their midpoint instead of cropping
-- the landing point to the current zone boundary.
function LM.FlightFrame(mapID, px, py, destination)
	if not (numeric(mapID) and numeric(px) and numeric(py) and type(destination) == "table"
		and numeric(destination.c) and numeric(destination.wx) and numeric(destination.wy)) then return nil end
	local pc, wx, wy = call(ns.Compat and ns.Compat.MapToWorld, mapID, px, py)
	if pc ~= destination.c or not (numeric(wx) and numeric(wy)) then return nil end
	local id = mapID
	for _ = 1, 8 do
		local b = worldBounds(id)
		local terrain = ns.LiveTerrain
		if not (b and b.c == pc and terrain and terrain.continents[b.c]) then return nil end
		local x, y = (wy - b.left) * b.kx * 100, (wx - b.top) * b.ky * 100
		local dx, dy = (destination.wy - b.left) * b.kx * 100, (destination.wx - b.top) * b.ky * 100
		if min(x, y, dx, dy) >= 0 and max(x, y, dx, dy) <= 100 then
			return { map = id, x = x, y = y, dx = dx, dy = dy,
				bounds = { x0 = min(x, dx), x1 = max(x, dx), y0 = min(y, dy), y1 = max(y, dy) } }
		end
		local info = mapInfo(id)
		local parent = info and info.parentMapID
		if not numeric(parent) or parent <= 0 or parent == id or info.mapType == 2 then return nil end
		id = parent
	end
end

local function loadArt(f)
	f.artDirty, f.art = false, nil
	for _, tile in ipairs(f.Tiles) do
		if tile.terrainMissing then tile.terrainFile = nil end
	end
	f.bounds = worldBounds(f.mapID)
	local b, terrain = f.bounds, ns.LiveTerrain
	-- The two continents have independent world coordinate systems. Stop
	-- at the continent rather than opening an empty illustrated world map.
	f.parentMap = false
	local info = mapInfo(f.mapID)
	local instance = instanceMap(f.mapID)
	f.instanceFloors = instance and instance.floors or nil
	if instance then
		if instance.unavailable then f.bounds = nil; return end
		if instance.floors then
			f.instanceFloor = clamp(f.instanceFloor or 1, 1, #instance.floors)
			local a = instance.floors[f.instanceFloor]
			f.art = { native = true, reference = true, layerWidth = a.layerWidth, layerHeight = a.layerHeight,
				tileWidth = a.tileWidth, tileHeight = a.tileHeight, tiles = a.tiles }
		else
			f.art = { instance = true, layerWidth = instance.left - instance.right, layerHeight = instance.top - instance.bottom,
				adt = 1600 / 3, tiles = instance.tiles }
		end
		if f.Sea then f.Sea:SetColorTexture(0.03, 0.03, 0.03, 1) end
		return
	end
	if info and (info.mapType == 4 or info.mapType == 5) then
		-- Native dungeon/floor artwork uses normalized map coordinates, not
		-- the stitched outdoor continent plane. Keep outdoor overlays off it.
		f.bounds = nil
		local layers = C_Map and call(C_Map.GetMapArtLayers, f.mapID)
		local a = type(layers) == "table" and layers[1]
		local textures = a and call(C_Map.GetMapArtLayerTextures, f.mapID, 1)
		if a and type(textures) == "table" and #textures > 0
			and numeric(a.layerWidth) and numeric(a.layerHeight) and numeric(a.tileWidth) and numeric(a.tileHeight)
			and min(a.layerWidth, a.layerHeight, a.tileWidth, a.tileHeight) > 0 then
			f.art = { native = true, layerWidth = a.layerWidth, layerHeight = a.layerHeight,
				tileWidth = a.tileWidth, tileHeight = a.tileHeight, tiles = textures }
		end
		if f.Sea then f.Sea:SetColorTexture(0.03, 0.03, 0.03, 1) end
		return
	end
	local parent = info and info.parentMapID
	local pb = numeric(parent) and parent > 0 and parent ~= f.mapID and worldBounds(parent)
	if pb and terrain and terrain.continents[pb.c] then f.parentMap = parent end
	local continent = b and terrain and terrain.continents[b.c]
	if not (continent and type(continent.tiles) == "table" and #continent.tiles > 0 and numeric(terrain.adt) and terrain.adt > 0) then return end
	f.art = { layerWidth = b.left - b.right, layerHeight = b.top - b.bottom,
		adt = terrain.adt, tiles = continent.tiles }
	local sea = continent.sea or { 8, 16, 16 }
	if f.Sea then f.Sea:SetColorTexture(sea[1] / 255, sea[2] / 255, sea[3] / 255, 1) end
end

local function placeTile(f, file, x, y, w, h, right, bottom)
	local v = f.View
	local sx, sy = v.drawWidth / f.art.layerWidth, v.drawHeight / f.art.layerHeight
	local ax, ay = v.offsetX + x * sx, v.offsetY + y * sy
	local bw, bh = w * sx, h * sy
	-- Crop explicitly instead of relying on a canvas clip for the final
	-- partial tile: it can contain padding beyond the map's own dimensions.
	local x0, y0 = max(0, v.offsetX, ax), max(0, v.offsetY, ay)
	local x1, y1 = min(v.width, v.offsetX + v.drawWidth, ax + bw), min(v.height, v.offsetY + v.drawHeight, ay + bh)
	if x1 <= x0 or y1 <= y0 then return end
	if f.tileCount >= TILE_LIMIT then f.clippedTiles = f.clippedTiles + 1; return end
	f.tileCount = f.tileCount + 1
	local t = f.Tiles[f.tileCount]
	if not t then t = f.Canvas:CreateTexture(nil, "BACKGROUND"); f.Tiles[f.tileCount] = t end
	-- Panning should not reload unchanged texture assets on every paint.
	if t.terrainFile ~= file then
		t.terrainFile = file
		t.terrainMissing = t:SetTexture(file, "CLAMP", "CLAMP", "TRILINEAR") == false
	end
	if t.terrainMissing then f.missingTiles = f.missingTiles + 1; t:Hide(); return end
	t:SetTexCoord((x0 - ax) / bw * right, (x1 - ax) / bw * right, (y0 - ay) / bh * bottom, (y1 - ay) / bh * bottom)
	t:ClearAllPoints()
	t:SetPoint("TOPLEFT", f.Canvas, "TOPLEFT", x0, -y0)
	t:SetSize(x1 - x0, y1 - y0)
	t:Show()
end

local function paintArt(f)
	f.tileCount, f.missingTiles, f.clippedTiles = 0, 0, 0
	local a, v = f.art, f.View
	f.usingOpenMap = false
	if a and not a.native and not a.instance and v and f.OpenMap then
		f.usingOpenMap = call(f.OpenMap.Paint, f.OpenMap, f.mapID, v, f.bounds) == true
		if f.usingOpenMap then
			for _, tile in ipairs(f.Tiles) do tile:Hide() end
			f.Empty:Hide()
			return
		end
		f.OpenMap:Hide()
	elseif f.OpenMap then f.OpenMap:Hide() end
	if a and v and a.native then
		local columns = math.ceil(a.layerWidth / a.tileWidth)
		for i, file in ipairs(a.tiles) do
			local x, y = (i - 1) % columns * a.tileWidth, math.floor((i - 1) / columns) * a.tileHeight
			local w, h = min(a.tileWidth, a.layerWidth - x), min(a.tileHeight, a.layerHeight - y)
			if w > 0 and h > 0 then placeTile(f, file, x, y, w, h, w / a.tileWidth, h / a.tileHeight) end
		end
	elseif a and v then
		-- Planner plane coordinates are (-worldY, -worldX), in yards. A
		-- level-zero ADT starts at ((col-32)*ADT, (row-32)*ADT). Both the
		-- terrain and the route overlay use these exact world coordinates.
		for _, tile in ipairs(a.tiles) do
			placeTile(f, tile[3], (tile[1] - 32) * a.adt + f.bounds.left,
				(tile[2] - 32) * a.adt + f.bounds.top, a.adt, a.adt, 1, 1)
		end
	end
	for i = f.tileCount + 1, #f.Tiles do f.Tiles[i]:Hide() end
	f.Empty:SetShown(not a or (f.missingTiles > 0 and f.missingTiles == f.tileCount))
	f.Empty:SetText(instanceMap(f.mapID) and "Dungeon map unavailable for this instance" or f.mapID and "Planner terrain unavailable for this area" or "Waiting for your map location")
end

local function rebuildPaths(f, geometry)
	f.geometry, f.paths, f.liveIndex = geometry, {}, nil
	local S = ns.RouteStrokes
	if not (S and geometry and type(geometry.legs) == "table") then return end
	local seenCurrent = false
	for _, leg in ipairs(geometry.legs) do
		local pts = type(leg.pts) == "table" and leg.pts
		if pts and #pts >= 2 and COLORS[leg.kind] then
			local later = seenCurrent and not leg.current
			local path = S.Path(leg.kind, pts, later)
			-- The geometry API does not certify every straight segment as a
			-- traversable terrain path. Mark two-point walks conservatively.
			if leg.kind == "walk" and #pts == 2 then path.kind, path.direct = "direct", true end
			f.paths[#f.paths + 1] = path
		end
		if leg.current then seenCurrent = true end
	end
end

local function paintStrokes(f)
	local b = f.strokes
	local routeColor = ROUTE_COLORS[f:GetRouteColor()]
	-- Reuse the existing visible-map tick; no extra animation driver or scans.
	local pulse = f:GetRoutePulse() and (0.86 + 0.14 * math.sin(GetTime() * 4)) or 1
	for i = 1, b.n do
		local line, rim = f.Lines[i], f.Rims[i]
		if not line then
			rim = f.RouteLayer:CreateLine(nil, "ARTWORK", nil, -1)
			line = f.RouteLayer:CreateLine(nil, "ARTWORK")
			f.Lines[i], f.Rims[i] = line, rim
		end
		if b.dot[i] then line:SetTexture(DOT); rim:SetTexture(DOT) else line:SetColorTexture(1, 1, 1, 1); rim:SetColorTexture(1, 1, 1, 1) end
		line:SetTexCoord(0, 1, 0, 1); rim:SetTexCoord(0, 1, 0, 1)
		rim:SetVertexColor(0.005, 0.01, 0.02, b.alpha[i])
		local width = b.width[i] + (b.dot[i] and 1.5 or 1)
		rim:SetThickness(width + 3)
		rim:SetStartPoint("TOPLEFT", f.RouteLayer, b.x1[i] - b.ux[i], b.y1[i] - b.uy[i])
		rim:SetEndPoint("TOPLEFT", f.RouteLayer, b.x2[i] + b.ux[i], b.y2[i] + b.uy[i])
		local c = b.color[i]
		if c == COLORS.walk or c == COLORS.direct then c = routeColor end
		line:SetVertexColor(c[1], c[2], c[3], b.alpha[i] * pulse)
		line:SetThickness(width)
		line:SetStartPoint("TOPLEFT", f.RouteLayer, b.x1[i], b.y1[i])
		line:SetEndPoint("TOPLEFT", f.RouteLayer, b.x2[i], b.y2[i])
		line:Show(); rim:Show()
	end
	for i = b.n + 1, #f.Lines do f.Lines[i]:Hide(); f.Rims[i]:Hide() end
end

local function sampleRoute(f, pm, px, py)
	local S, N, C = ns.RouteStrokes, ns.Nav, ns.Compat
	local geometry = call(N and N.GetRouteGeometry)
	if geometry ~= f.geometry then rebuildPaths(f, geometry) end
	f.liveStart = false
	local first = f.paths[1]
	if S and pm and first and (first.kind == "walk" or first.kind == "direct") and not first.later then
		local pc, wx, wy = call(C and C.MapToWorld, pm, px, py)
		if numeric(pc) and numeric(wx) and numeric(wy) then
			local idx = S.Live(first, pc, wx, wy, f.liveIndex, 60)
			if idx then f.liveIndex, f.liveStart, f.liveC, f.liveX, f.liveY = idx, true, pc, wx, wy end
		end
	end
end

local function paintRoutes(f)
	local S = ns.RouteStrokes
	if not (S and f.strokes) then return end
	f.strokes.n = 0
	local b, v = f.bounds, f.View
	if b and v and f.art then
		local rv = f.routeView
		rv.c = b.c
		rv.left, rv.top = b.left - v.offsetX / v.drawWidth / b.kx, b.top - v.offsetY / v.drawHeight / b.ky
		rv.kx, rv.ky = b.kx * v.drawWidth / v.width, b.ky * v.drawHeight / v.height
		rv.width, rv.height, rv.scale = v.width, v.height, f:GetEffectiveScale() or 1
		rv.from, rv.fromIndex = nil, nil
		if f.liveStart then
			rv.from, rv.fromIndex, rv.fromC, rv.fromX, rv.fromY = true, f.liveIndex, f.liveC, f.liveX, f.liveY
		end
		S.Map(f.strokes, f.paths, rv)
	end
	paintStrokes(f)
end

local function placeMarker(f, marker, x, y)
	local sx, sy = LM.Project(f.View, x, y)
	local visible = f.art and sx and x >= 0 and x <= 100 and y >= 0 and y <= 100
		and sx >= 0 and sy >= 0 and sx <= f.View.width and sy <= f.View.height
	marker:SetShown(visible and true or false)
	if visible then marker:ClearAllPoints(); marker:SetPoint("CENTER", f.MarkerLayer, "TOPLEFT", sx, -sy) end
	return visible
end

local function paintParty(f, cached)
	if cached then
		for _, marker in ipairs(f.PartyMarkers) do
			if marker.active then placeMarker(f, marker, marker.mapX, marker.mapY) end
		end
		return
	end
	for _, marker in ipairs(f.PartyMarkers) do marker.active = false end
	local count = 0
	local raid = call(IsInRaid) == true
	local total = call(raid and GetNumGroupMembers or GetNumSubgroupMembers) or 0
	if not numeric(total) then total = 0 end
	for i = 1, min(raid and 40 or 4, total) do
		local unit = (raid and "raid" or "party") .. i
		if call(UnitExists, unit) and call(UnitIsUnit, unit, "player") ~= true and call(UnitIsConnected, unit) ~= false then
			local x, y = unitOnMap(f.mapID, unit)
			if numeric(x) and numeric(y) and x >= 0 and y >= 0 and x <= 1 and y <= 1 and (x ~= 0 or y ~= 0) then
				count = count + 1
				local marker = f.PartyMarkers[count]
				if not marker then
					marker = CreateFrame("Button", nil, f.MarkerLayer); marker:SetSize(14, 14)
					marker:SetFrameLevel(f.MarkerLayer:GetFrameLevel() + 2)
					marker.Icon = marker:CreateTexture(nil, "OVERLAY"); marker.Icon:SetAllPoints(marker); marker.Icon:SetTexture(DOT)
					marker:SetScript("OnEnter", function(self) ns.Widgets.Tooltip(self, "ANCHOR_RIGHT", self.unitName or "Party member", {}) end)
					marker:SetScript("OnLeave", ns.Widgets.HideTip); marker:SetScript("OnHide", ns.Widgets.HideTip)
					f.PartyMarkers[count] = marker
				end
				local _, class = call(UnitClass, unit)
				local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
				marker.Icon:SetVertexColor(color and color.r or 0.3, color and color.g or 0.7, color and color.b or 1)
				marker.unitName = call(UnitName, unit)
				marker.active, marker.mapX, marker.mapY = true, x * 100, y * 100
				placeMarker(f, marker, marker.mapX, marker.mapY)
			end
		end
	end
	for i = count + 1, #f.PartyMarkers do f.PartyMarkers[i]:Hide() end
end

local function setMap(f, id)
	if not numeric(id) or id == 0 or id < 0 and not instanceMap(id) or f.mapID == id then return false end
	f.mapID, f.focusX, f.focusY, f.zoom = id, 50, 50, 1
	f.instanceFloor = 1
	f.autoZoomTarget, f.autoZoomTime, f.autoZoomReset = nil, nil, true
	loadArt(f)
	f.dirty = true
	return true
end

local function regionHover(f)
	if not f.regionHover or f.dragging or not f.Regions or not f.Regions:GetEnabled() then
		if f.regionTip then ns.Widgets.HideTooltip(f.Viewport); f.regionTip = nil end
		return
	end
	local focus = call(GetMouseFoci)
	local ownsFocus = not (type(focus) == "table" and #focus > 0)
	if type(focus) == "table" then for _, object in ipairs(focus) do if object == f.Viewport then ownsFocus = true end end end
	local owner = GameTooltip and call(GameTooltip.GetOwner, GameTooltip)
	if not ownsFocus or (owner and owner ~= f.Viewport and GameTooltip:IsShown()) then
		if f.regionTip then ns.Widgets.HideTooltip(f.Viewport); f.regionTip = nil end
		return
	end
	local cx, cy = call(GetCursorPosition)
	local scale = f:GetEffectiveScale() or 1
	local left, top = f.Viewport:GetLeft(), f.Viewport:GetTop()
	if not (numeric(cx) and numeric(cy) and numeric(left) and numeric(top)) then return end
	local hits = f.Regions:HitTest(cx / scale - left, top - cy / scale)
	local lines = {}
	for _, p in ipairs(hits or {}) do
		local progress = p.progress
		local count = progress and numeric(progress.cur) and numeric(progress.max) and string.format(" (%d/%d)", progress.cur, progress.max) or ""
		lines[#lines + 1] = (p.label or "Objective") .. count
	end
	local key = table.concat(lines, "\n")
	if key == "" then
		if f.regionTip then ns.Widgets.HideTooltip(f.Viewport); f.regionTip = nil end
	elseif f.regionTip ~= key then
		f.regionTip = key
		ns.Widgets.Tooltip(f.Viewport, "ANCHOR_CURSOR", "Polestar objective region", lines)
	end
end

local function questTarget(target)
	if not target or (target.kind ~= "accept" and target.kind ~= "turnin") then return nil end
	local E = ns.Engine
	local guide = call(E and E.GetGuide)
	local step = guide and guide.steps and guide.steps[target.stepIndex]
	local goal = step and step.goals and step.goals[target.goalIndex]
	if goal and goal.t == target.kind and numeric(goal.quest) then return goal end
end

local function sameDestination(a, b, oldGoal, newGoal)
	if oldGoal or newGoal then return oldGoal == newGoal end
	if a == b then return true end
	return a and b and a.kind == b.kind and a.map == b.map and a.x == b.x and a.y == b.y and a.label == b.label
end

local function refresh(f, force, cached)
	if not f:IsVisible() then f.dirty = true; return end
	local pm, px, py
	if cached then pm, px, py = f.playerMap, f.playerX, f.playerY
	else
		pm, px, py = readPlayer()
		f.playerMap, f.playerX, f.playerY = pm, px, py
		f.facing = call(ns.Compat and ns.Compat.GetPlayerFacing)
		if pm then
			-- A temporary pan must not strand the HUD in the old zone after
			-- a teleport. Keep the last valid map through loading-screen gaps;
			-- an explicitly disabled Follow preference remains disabled.
			if f.compact and f.follow and f.lastPlayerMap and pm ~= f.lastPlayerMap then
				f.followPaused, f.dragging, f.autoZoomPauseUntil = nil, false, nil
				f.autoZoomReset = true
			end
			f.lastPlayerMap = pm
		end
	end
	local following = f:GetFollow()
	sampleRoute(f, pm, px, py)
	local now = call(GetTime)
	local zoomPaused = numeric(now) and numeric(f.autoZoomPauseUntil) and now < f.autoZoomPauseUntil
	local automatic = f:GetAutoZoom() and following and not f.dragging and not zoomPaused
	local destination = f.compact and call(ns.Adapter and ns.Adapter.FlightDestination, f.geometry)
	local flight = automatic and LM.FlightFrame(pm, px, py, destination)
	local cameraMap = flight and flight.map or zoomPaused and f.flightFraming and destination and f.mapID or pm
	if automatic then f.flightFraming = flight ~= nil
	elseif not destination or not following or not f:GetAutoZoom() then f.flightFraming = nil end
	if following and pm then setMap(f, cameraMap) end
	if (f.artDirty or (force and (f.missingTiles or 0) > 0)) and f.mapID then loadArt(f) end
	local x, y = positionOn(f.mapID, pm, px, py)
	if following and x and not (zoomPaused and f.flightFraming and destination) then
		f.focusX, f.focusY = flight and (flight.x + flight.dx) / 2 or x, flight and (flight.y + flight.dy) / 2 or y
	end
	local w, h = f.Viewport:GetWidth(), f.Viewport:GetHeight()
	if not (w and h and w > 1 and h > 1) then return end
	local a = f.art
	local layoutWidth, layoutHeight = a and a.layerWidth or 1002, a and a.layerHeight or 668
	local ow, oh
	if not (a and (a.native or a.instance)) then ow, oh = call(ns.LiveOpenMap and ns.LiveOpenMap.Dimensions, f.mapID) end
	if numeric(ow) and numeric(oh) and ow > 0 and oh > 0 then
		-- Use the same stitched-map proportions for camera fitting and pins.
		layoutHeight = layoutWidth * oh / ow
	end
	if automatic and a and x then
		local airborne = f.compact and call(ns.Compat and ns.Compat.IsOnTaxi) == true
		local bounds = flight and flight.bounds or not airborne and LM.RemainingWalkBounds(f.geometry, f.liveIndex, f.bounds, x, y)
		local desired = LM.AutoZoomLevel(w, h, layoutWidth, layoutHeight, f.focusX, f.focusY, bounds)
		if desired then
			-- A small dead band prevents terrain breathing as position samples
			-- wobble or the route is recomputed a few yards to either side.
			if not f.autoZoomTarget or abs(desired / f.autoZoomTarget - 1) > 0.06 then f.autoZoomTarget = desired end
			if flight and desired < f.zoom then f.zoom = desired end
			if f.autoZoomReset then f.zoom, f.autoZoomReset = f.autoZoomTarget, false
			elseif numeric(now) and numeric(f.autoZoomTime) then f.zoom = LM.EaseAutoZoom(f.zoom, f.autoZoomTarget, now - f.autoZoomTime) end
		else f.autoZoomTarget = nil end
	end
	f.autoZoomTime = now
	local v = LM.ComputeView(w, h, layoutWidth, layoutHeight, f.zoom, f.focusX, f.focusY)
	if not v then
		-- Reject a corrupted/overflowing saved camera without imposing a
		-- practical close-in zoom cap on either map window.
		f.zoom = 1
		v = LM.ComputeView(w, h, layoutWidth, layoutHeight, 1, f.focusX, f.focusY)
	end
	if not v then return end
	local old = f.View
	local moved = not old or old.width ~= v.width or old.height ~= v.height or old.drawWidth ~= v.drawWidth
		or abs(old.offsetX - v.offsetX) > 0.05 or abs(old.offsetY - v.offsetY) > 0.05
	f.View = v
	-- A loading screen can temporarily hide map art APIs. Retry the detailed
	-- background at most once a second even when the camera/player stays still.
	local retryOpenMap = f.OpenMap and not (a and (a.native or a.instance)) and not f.usingOpenMap and numeric(now)
		and (not numeric(f.openMapRetryAt) or now >= f.openMapRetryAt)
	if force or f.dirty or moved or retryOpenMap then
		f.openMapRetryAt = numeric(now) and now + 1 or nil
		if retryOpenMap and not f.art and f.mapID then loadArt(f) end
		paintArt(f)
	end
	local info = mapInfo(f.mapID)
	f.Zone:SetText((info and info.name or "Live map") .. (f.compact and "" or a and (a.native or a.instance) and " - Dungeon map" or f.usingOpenMap and " - OpenMap detail" or " - Planner terrain"))
	if f.shownFollow ~= following then
		ns.Widgets.SetButtonText(f.FollowButton, following and (f.compact and "Follow on" or "Following") or "Follow")
		f.shownFollow = following
	end
	f.ParentButton:SetEnabled(numeric(f.parentMap))
	f.ZoomInButton:SetEnabled(numeric(f.zoom * 1.4))
	f.ZoomOutButton:SetEnabled(f.zoom > 1 or numeric(f.parentMap))
	placeMarker(f, f.PlayerMarker, x, y)
	paintParty(f, cached)
	local facing = f.facing
	if numeric(facing) and f.PlayerMarker.Arrow.SetRotation then
		f.PlayerMarker.Arrow:SetRotation(facing)
	end
	local dx, dy
	if destination and f.bounds and destination.c == f.bounds.c then
		dx, dy = (destination.wy - f.bounds.left) * f.bounds.kx * 100, (destination.wx - f.bounds.top) * f.bounds.ky * 100
	end
	f.FlightMarker.label = destination and destination.label or "Flight destination"
	placeMarker(f, f.FlightMarker, dx, dy)
	local N = ns.Nav
	local target = call(N and N.GetTarget)
	local tm, tx, ty = call(N and N.LiveCoords, target)
	local gx, gy
	if numeric(tm) and numeric(tx) and numeric(ty) then gx, gy = positionOn(f.mapID, tm, tx, ty) end
	placeMarker(f, f.GoalMarker, gx, gy)
	local newGoal = questTarget(target)
	if not sameDestination(f.GoalMarker.navTarget, target, f.GoalMarker.guideGoal, newGoal) then
		ns.Widgets.HideTip(f.GoalMarker)
	end
	f.GoalMarker.navTarget = target
	f.GoalMarker.targetLabel = target and target.label or "Navigation target"
	f.GoalMarker.guideGoal = newGoal
	local Q = ns.LiveQuestie
	if not (Q and Q.PaintGuideMarker and Q.PaintGuideMarker(f.GoalMarker, f.GoalMarker.guideGoal)) then
		f.GoalMarker:SetSize(20, 20)
		f.GoalMarker.Icon:SetSize(20, 20)
		f.GoalMarker.Icon:SetTexture(DOT)
		f.GoalMarker.Icon:SetTexCoord(0, 1, 0, 1)
		f.GoalMarker.Icon:SetVertexColor(1, 0.78, 0.2)
	end
	if call(GameTooltip and GameTooltip.GetOwner, GameTooltip) == f.GoalMarker and call(GameTooltip.IsShown, GameTooltip) then
		if f.GoalMarker.guideGoal and Q and Q.ShowGuideTooltip then
			Q.ShowGuideTooltip(f.GoalMarker, f.GoalMarker.guideGoal, f.GoalMarker.targetLabel)
		else ns.Widgets.Tooltip(f.GoalMarker, "ANCHOR_RIGHT", "Arrow destination", { f.GoalMarker.targetLabel }) end
	end
	local E = ns.Engine
	local objectiveStep = f.inspectionIndex or call(E and E.GetStepIndex)
	f:SyncLayers()
	if f.Objectives then
		f.Objectives:Refresh(f, objectiveStep)
		for _, marker in ipairs(f.Objectives.Markers) do
			if marker:IsVisible() and marker.objective and marker.objective.active then f.GoalMarker:Hide(); break end
		end
	end
	if f.Regions then f.Regions:Refresh(f, f.Objectives and f.Objectives.scene) end
	if f.Services then f.Services:Refresh(f) end
	if f.Questie then f.Questie:Refresh(f) end
	regionHover(f)
	-- The objective layer handles both the live step and read-only browsing.
	-- Keep the older grouped inspection data for camera framing only.
	paintRoutes(f)
	local status
	if not pm then status = "Player location unavailable here"
	elseif not x and info and info.mapType == 4 then status = "Instance overview - live position unavailable"
	elseif not x or x < 0 or x > 100 or y < 0 or y > 100 then status = "Player is on another map - click Player"
	else status = string.format("You: %.1f, %.1f", x, y) end
	if target then
		local first = f.paths[1]
		local kind = first and first.kind
		local label = first and first.direct and "Direct segment (unverified)" or kind == "walk" and "Routed walk (" .. f:GetRouteColor() .. ")"
			or kind == "flight" and "Flight (green)" or kind == "boat" and "Boat route" or kind == "zeppelin" and "Zeppelin route"
			or kind == "tram" and "Tram route" or kind == "lift" and "Lift route" or "No route geometry"
		status = status .. "  |  " .. label
	else status = status .. "  |  No navigation target" end
	if (f.missingTiles or 0) > 0 then status = status .. string.format("  |  Terrain textures unavailable (%d)", f.missingTiles) end
	if (f.clippedTiles or 0) > 0 then status = status .. "  |  Terrain limit reached - zoom in" end
	f.Status:SetText(status)
	local hint = f:GetAreaStyle() == "regions" and "Gold: current objective; amber: other objectives - hover regions or pins" or "Drag to pan - wheel to zoom - hover pins for details"
	if f:GetQuestie() and f.Questie and f.Questie.GetStatus then
		local qstatus, available, truncated = f.Questie:GetStatus()
		if not available then hint = qstatus or "Questie unavailable"
		elseif truncated then hint = "Questie spawn display limit reached - zoom in" end
	end
	if f.Objectives and f.Objectives.scene.truncated then hint = "Objective display limit reached for this step" end
	if a and a.reference then hint = "Blizzard layout reference from Dungeon Scout; Forever layouts may differ. Floors: Layers."
	elseif a and a.instance then hint = "Dungeon terrain overview - live markers appear when the client provides positions." end
	f.Hint:SetText(hint)
	f.dirty = false
end

function LM.Create(parent, options)
	local W = ns.Widgets
	local f = CreateFrame("Frame", nil, parent)
	f.compact = options and options.compact == true
	f:SetSize(520, 500)
	f.View = false
	f.follow, f.zoom, f.focusX, f.focusY = true, 1, 50, 50
	f.autoZoom = f.compact and options and options.autoZoom == true
	f.autoZoomReset = true
	f.Tiles, f.Lines, f.Rims, f.paths, f.InspectionMarkers = {}, {}, {}, {}, {}
	f.PartyMarkers = {}
	f.strokes = ns.RouteStrokes and ns.RouteStrokes.New(LIMIT)
	f.routeView = { colors = COLORS, marks = {}, markCount = 0 }
	local bg = f:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(f); bg:SetColorTexture(0.035, 0.055, 0.075, 1)
	f.Zone = W.Text(f, "label", "text")
	f.Zone:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
	f.Zone:SetPoint("TOPRIGHT", f, "TOPRIGHT", f.compact and -76 or -116, -8)
	f.Zone:SetJustifyH("LEFT")
	f.Zone:SetWordWrap(false)
	f.FollowButton = W.Button(f, "Following", function() f:SetFollow(not f:GetFollow()) end, { width = f.compact and 66 or 88, height = 24 })
	f.FollowButton:SetPoint("TOPLEFT", f, "TOPLEFT", 8, f.compact and -27 or -31)
	f.PlayerButton = W.Button(f, "Player", function() f:ShowPlayer() end, { width = f.compact and 52 or 66, height = 24 })
	f.PlayerButton:SetPoint("LEFT", f.FollowButton, "RIGHT", 4, 0)
	f.ParentButton = W.Button(f, "Up", function() f:ZoomOutZone() end, { width = f.compact and 32 or 40, height = 24 })
	f.ParentButton:SetPoint("LEFT", f.PlayerButton, "RIGHT", 4, 0)
	f.ZoomOutButton = W.Button(f, "-", function() f:ZoomOut() end, { width = f.compact and 24 or 30, height = 24 })
	f.ZoomOutButton:SetPoint("LEFT", f.ParentButton, "RIGHT", 4, 0)
	f.ZoomInButton = W.Button(f, "+", function() f:ZoomIn() end, { width = f.compact and 24 or 30, height = 24 })
	f.ZoomInButton:SetPoint("LEFT", f.ZoomOutButton, "RIGHT", 4, 0)
	f.LayersButton = W.Button(f, "Layers", function() f:ShowLayers() end, { width = f.compact and 64 or 104, height = 24 })
	f.LayersButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -3)
	f.Viewport = CreateFrame("Button", nil, f)
	f.Viewport:SetPoint("TOPLEFT", f, "TOPLEFT", 0, f.compact and -56 or -61)
	f.Viewport:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, f.compact and 0 or 42)
	if f.Viewport.SetClipsChildren then f.Viewport:SetClipsChildren(true) end
	f.Canvas = CreateFrame("Frame", nil, f.Viewport); f.Canvas:SetAllPoints(f.Viewport)
	f.Sea = f.Canvas:CreateTexture(nil, "BACKGROUND", nil, -1)
	f.Sea:SetAllPoints(f.Canvas); f.Sea:SetColorTexture(8 / 255, 16 / 255, 16 / 255, 1)
	if ns.LiveOpenMap then f.OpenMap = ns.LiveOpenMap.Create(f.Canvas) end
	f.RouteLayer = CreateFrame("Frame", nil, f.Viewport); f.RouteLayer:SetAllPoints(f.Viewport)
	-- OpenMap's internal art stack uses 32 levels. Regions and navigation sit
	-- above it, so the route and interactive quest pins remain readable.
	f.RouteLayer:SetFrameLevel(f.Canvas:GetFrameLevel() + 50)
	f.MarkerLayer = CreateFrame("Frame", nil, f.Viewport); f.MarkerLayer:SetAllPoints(f.Viewport)
	f.MarkerLayer:SetFrameLevel(f.RouteLayer:GetFrameLevel() + 1)
	f.PlayerMarker = CreateFrame("Frame", nil, f.MarkerLayer); f.PlayerMarker:SetSize(26, 26)
	f.PlayerMarker:SetFrameLevel(f.MarkerLayer:GetFrameLevel() + 3)
	f.PlayerMarker.Arrow = f.PlayerMarker:CreateTexture(nil, "OVERLAY")
	f.PlayerMarker.Arrow:SetAllPoints(f.PlayerMarker)
	f.PlayerMarker.Arrow:SetTexture("Interface\\AddOns\\Polestar\\Media\\Nav\\arrow")
	f.PlayerMarker.Arrow:SetVertexColor(1, 0.94, 0.55)
	f.GoalMarker = CreateFrame("Button", nil, f.MarkerLayer); f.GoalMarker:SetSize(20, 20)
	f.GoalMarker:SetScript("OnEnter", function(self)
		local Q = ns.LiveQuestie
		if self.guideGoal and Q and Q.ShowGuideTooltip then Q.ShowGuideTooltip(self, self.guideGoal, self.targetLabel)
		else W.Tooltip(self, "ANCHOR_RIGHT", "Arrow destination", { self.targetLabel }) end
	end)
	f.GoalMarker:SetScript("OnLeave", W.HideTip)
	f.GoalMarker:SetScript("OnHide", W.HideTip)
	local goal = f.GoalMarker:CreateTexture(nil, "OVERLAY")
	f.GoalMarker.Icon = goal
	goal:SetAllPoints(f.GoalMarker); goal:SetTexture(DOT); goal:SetVertexColor(1, 0.78, 0.2)
	f.FlightMarker = CreateFrame("Button", nil, f.MarkerLayer); f.FlightMarker:SetSize(24, 24)
	f.FlightMarker.Icon = W.Tex(f.FlightMarker, "OVERLAY", "icon-fly", "accent")
	f.FlightMarker.Icon:SetAllPoints(f.FlightMarker)
	f.FlightMarker:SetScript("OnEnter", function(self) W.Tooltip(self, "ANCHOR_RIGHT", "Flight destination", { self.label }) end)
	f.FlightMarker:SetScript("OnLeave", W.HideTip)
	f.FlightMarker:SetScript("OnHide", W.HideTip)
	if ns.LiveObjectives then
		f.Objectives = ns.LiveObjectives.Create(f.Viewport)
		f.Objectives:SetFrameLevel(f.Canvas:GetFrameLevel() + 40)
		f.Objectives:SetEnabled(ns.Get("liveMap.objectives") ~= false)
	end
	if ns.LiveRegions then
		f.Regions = ns.LiveRegions.Create(f.Viewport)
		f.Regions:SetFrameLevel(f.Canvas:GetFrameLevel() + 40)
	end
	if ns.LiveQuestie then
		f.Questie = ns.LiveQuestie.Create(f.Viewport)
		-- Background spawns stay under service pins; authored objectives and
		-- the active destination/player remain above both shared overlays.
		-- Child pins inherit another level. Leave enough space that even their
		-- actual textures stay below the route, not tied with it by creation order.
		f.Questie:SetFrameLevel(f.Canvas:GetFrameLevel() + 41)
	end
	if ns.LiveServices then
		f.Services = ns.LiveServices.Create(f.Viewport)
		f.Services:SetFrameLevel(f.Canvas:GetFrameLevel() + 44)
	end
	f.Empty = W.Text(f.MarkerLayer, "label", "textDim")
	f.Empty:SetPoint("CENTER", f.Viewport, "CENTER", 0, 0)
	f.Status = W.Text(f, "small", "textDim")
	f.Status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 23)
	f.Status:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 23)
	f.Status:SetJustifyH("LEFT")
	f.Status:SetWordWrap(false)
	f.Hint = W.Text(f, "small", "textMuted")
	f.Hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 7)
	f.Hint:SetText("Drag to pan - wheel to zoom - right-click for parent map")
	f.Hint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 7)
	f.Hint:SetJustifyH("LEFT")
	f.Hint:SetWordWrap(false)
	if f.compact then
		f.Status:Hide(); f.Hint:Hide()
		-- Keep routing/fallback details available without a second HUD footer.
		local info = CreateFrame("Frame", nil, f)
		f.Info = info -- Compact hosts can relocate the controls and supply their own tooltip.
		info:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -3)
		info:SetPoint("TOPRIGHT", f, "TOPRIGHT", -76, -3)
		info:SetHeight(22); info:EnableMouse(true)
		info:SetScript("OnEnter", function(self) W.Tooltip(self, "ANCHOR_RIGHT", f.Zone:GetText(), { f.Status:GetText(), f.Hint:GetText() }) end)
		info:SetScript("OnLeave", W.HideTip)
	end

	function f:Refresh(force) refresh(self, force) end
	function f:GetObjectives() return ns.Get("liveMap.objectives") ~= false end
	function f:GetAreaStyle()
		local value = ns.Get("liveMap.areaStyle")
		return (value == "circles" or value == "off") and value or "regions"
	end
	function f:GetQuestie() return ns.Get("liveMap.questie") ~= false end
	function f:GetRouteColor()
		local color = ns.Get("liveMap.routeColor")
		return ROUTE_COLORS[color] and color or "cyan"
	end
	function f:GetRoutePulse() return ns.Get("liveMap.routePulse") == true end
	function f:SetRouteColor(color)
		if not ROUTE_COLORS[color] then return end
		ns.Set("liveMap.routeColor", color); self:Refresh(true)
	end
	function f:SetRoutePulse(enabled)
		ns.Set("liveMap.routePulse", enabled and true or false); self:Refresh(true)
	end
	function f:SetObjectives(enabled) ns.Set("liveMap.objectives", enabled and true or false); self:Refresh(true) end
	function f:SetAreaStyle(style)
		if style ~= "regions" and style ~= "circles" and style ~= "off" then return end
		ns.Set("liveMap.areaStyle", style); self:Refresh(true)
	end
	function f:SetQuestie(enabled) ns.Set("liveMap.questie", enabled and true or false); self:Refresh(true) end
	function f:SyncLayers()
		local markers, style, questie = self:GetObjectives(), self:GetAreaStyle(), self:GetQuestie()
		if self.Objectives then
			local needed = markers or style ~= "off"
			if self.Objectives:GetEnabled() ~= needed then self.Objectives:SetEnabled(needed) end
			self.Objectives:SetLayers(markers, style == "circles")
		end
		if self.Regions and self.Regions:GetEnabled() ~= (style == "regions") then self.Regions:SetEnabled(style == "regions") end
		if self.Questie and self.Questie:GetEnabled() ~= questie then self.Questie:SetEnabled(questie) end
	end
	function f:ShowLayers()
		if self.instanceFloors and #self.instanceFloors > 1 then
			local items = {}
			for i, floor in ipairs(self.instanceFloors) do
				local index = i
				items[#items + 1] = { text = floor.label, checked = self.instanceFloor == index, onClick = function()
					self.instanceFloor = index; self.artDirty = true; self:Refresh(true)
				end }
			end
			W.ShowMenu(self.LayersButton, items, { minWidth = 180 })
			return
		end
		if W.MenuShown(self.LayersButton) then W.HideMenu(); return end
		local style = self:GetAreaStyle()
		W.ShowMenu(self.LayersButton, {
			{ text="Polestar regions", checked=style=="regions", tip="The same grouped objective borders as Polestar's world map and minimap.", onClick=function() self:SetAreaStyle(style=="regions" and "off" or "regions") end },
			{ text="Purple circles", checked=style=="circles", tip="Show separate spawn clusters instead of grouped borders.", onClick=function() self:SetAreaStyle(style=="circles" and "off" or "circles") end },
			{ separator=true },
			{ text="Guide objective markers", checked=self:GetObjectives(), onClick=function() self:SetObjectives(not self:GetObjectives()) end },
			{ text="Questie spawn icons", checked=self:GetQuestie(), tip="Mirror Questie's active objective spawn pins. Questie must be enabled.", onClick=function() self:SetQuestie(not self:GetQuestie()) end },
			{ separator=true },
			{ text="Route: cyan", checked=self:GetRouteColor()=="cyan", onClick=function() self:SetRouteColor("cyan") end },
			{ text="Route: white", checked=self:GetRouteColor()=="white", onClick=function() self:SetRouteColor("white") end },
			{ text="Route: pink", checked=self:GetRouteColor()=="pink", onClick=function() self:SetRouteColor("pink") end },
			{ text="Pulse route", checked=self:GetRoutePulse(), tip="Gently pulse the route using the existing map refresh. Off by default.", onClick=function() self:SetRoutePulse(not self:GetRoutePulse()) end },
		}, {minWidth=220})
	end
	function f:GetFollow() return self.follow and not self.followPaused end
	function f:GetAutoZoom() return self.autoZoom == true end
	function f:SetAutoZoom(on)
		if not self.compact then return end
		self.autoZoom = on and true or false
		self.autoZoomTarget, self.autoZoomTime = nil, nil
		self.autoZoomPauseUntil = nil
		-- Enabling is deliberate: immediately frame the current travel.
		self.autoZoomReset = self.autoZoom
		if options and options.onAutoZoomChanged then options.onAutoZoomChanged(self.autoZoom) end
		self:Refresh(true)
	end
	function f:GetMapID() return self.mapID end
	function f:SetFollow(on)
		self.follow = on and true or false
		self.followPaused = nil
		if self.follow then
			self.inspection, self.inspectionIndex, self.autoZoomPauseUntil = nil, nil, nil
			self.autoZoomReset = true
		end
		self:Refresh(true)
	end
	function f:ShowPlayer()
		self.follow, self.followPaused, self.inspection, self.inspectionIndex = true, nil, nil, nil
		self.autoZoomPauseUntil, self.autoZoomReset = nil, true
		local m = readPlayer(); if m then setMap(self, m) end; self:Refresh(true)
	end
	function f:ClearInspection() self.inspection, self.inspectionIndex = nil, nil; self:Refresh(true) end
	-- Inspect authored goal locations without moving the guide engine or its
	-- live navigation target. No speculative straight-line future routes.
	function f:ShowStep(view, index)
		local points, seen = {}, {}
		for _, goal in ipairs(view and view.goals or {}) do
			if not goal.folded and goal.status ~= "na" and #points < 64 then
				local m, x, y = call(ns.Nav and ns.Nav.LiveCoords, goal)
				if numeric(m) and numeric(x) and numeric(y) and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
					local key = m .. ":" .. math.floor(x * 10) .. ":" .. math.floor(y * 10)
					local text = ns.UI and ns.UI.PlainGoalText and ns.UI.PlainGoalText(goal) or goal.text or goal.subject or "Objective"
					if seen[key] then seen[key].label = seen[key].label .. "\n" .. text
					else
						local p = { map = m, x = x, y = y, label = text }
						points[#points + 1], seen[key] = p, p
					end
				end
			end
		end
		self.inspection, self.inspectionIndex = points, index
		if points[1] then
			self.follow = false
			setMap(self, points[1].map)
			local x0, x1, y0, y1 = points[1].x, points[1].x, points[1].y, points[1].y
			for _, p in ipairs(points) do
				local x, y = positionOn(self.mapID, p.map, p.x, p.y)
				if x and x >= 0 and x <= 100 and y >= 0 and y <= 100 then x0, x1, y0, y1 = min(x0, x), max(x1, x), min(y0, y), max(y1, y) end
			end
			self.focusX, self.focusY = (x0 + x1) / 2, (y0 + y1) / 2
			self.zoom = min(4, 75 / max(1, x1 - x0, y1 - y0))
		end
		self:Refresh(true)
	end
	function f:PauseFollow()
		if self.compact then self.followPaused = self.follow
		else self.follow = false end
	end
	function f:SetMapID(id)
		if numeric(id) and id > 0 then self:PauseFollow(); setMap(self, id); self:Refresh(true) end
	end
	function f:PauseAutoZoom()
		if not self:GetAutoZoom() then return end
		local now = call(GetTime)
		self.autoZoomPauseUntil = numeric(now) and now + MANUAL_ZOOM_PAUSE or nil
		self.autoZoomReset = false
	end
	function f:ZoomIn()
		self:PauseAutoZoom()
		local nextZoom = self.zoom * 1.4
		if numeric(nextZoom) then self.zoom = nextZoom end
		self:Refresh(true)
	end
	function f:ZoomOut()
		self:PauseAutoZoom()
		if self.zoom <= 1 then self:ZoomOutZone()
		else self.zoom = max(1, self.zoom / 1.4); self:Refresh(true) end
	end
	function f:ZoomOutZone()
		if numeric(self.parentMap) then self:SetMapID(self.parentMap) end
	end
	-- Persist the chosen Follow setting, not a temporary compact-map pan.
	function f:GetViewState() return { zoom = self.zoom, follow = self.follow, mapID = self.mapID, focusX = self.focusX, focusY = self.focusY } end
	function f:ApplyViewState(s)
		if type(s) ~= "table" then return end
		if numeric(s.mapID) and (s.mapID > 0 or instanceMap(s.mapID)) then setMap(self, s.mapID) end
		self.follow = s.follow ~= false
		self.followPaused = nil
		if numeric(s.zoom) then self.zoom = max(1, s.zoom) end
		if numeric(s.focusX) then self.focusX = clamp(s.focusX, 0, 100) end
		if numeric(s.focusY) then self.focusY = clamp(s.focusY, 0, 100) end
		self:Refresh(true)
	end
	local function cursor()
		local x, y = GetCursorPosition()
		local s = f:GetEffectiveScale() or 1
		return x / s, y / s
	end
	f.Viewport:EnableMouse(true); f.Viewport:EnableMouseWheel(true)
	f.Viewport:RegisterForDrag("LeftButton")
	f.Viewport:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	f.Viewport:SetScript("OnEnter", function() f.regionHover = true; regionHover(f) end)
	f.Viewport:SetScript("OnLeave", function() f.regionHover = false; if f.regionTip then W.HideTooltip(f.Viewport); f.regionTip = nil end end)
	f.Viewport:SetScript("OnMouseWheel", function(_, d) if d > 0 then f:ZoomIn() else f:ZoomOut() end end)
	f.Viewport:SetScript("OnClick", function(_, button) if button == "RightButton" then f:ZoomOutZone() end end)
	f.Viewport:SetScript("OnDoubleClick", function(_, button)
		if button ~= "LeftButton" or not f.View or not C_Map or not C_Map.GetMapInfoAtPosition then return end
		local x, y = cursor()
		local left, top = f.Viewport:GetLeft(), f.Viewport:GetTop()
		if not (left and top) then return end
		local nx, ny = (x - left - f.View.offsetX) / f.View.drawWidth, (top - y - f.View.offsetY) / f.View.drawHeight
		if nx < 0 or nx > 1 or ny < 0 or ny > 1 then return end
		local info = call(C_Map.GetMapInfoAtPosition, f.mapID, nx, ny)
		if info and info.mapID and info.mapID ~= f.mapID then f:SetMapID(info.mapID) end
	end)
	f.Viewport:SetScript("OnDragStart", function()
		if not f.View then return end
		f:PauseFollow(); f.dragging = true
		f.dragX, f.dragY = cursor()
	end)
	f.Viewport:SetScript("OnDragStop", function() f.dragging = false end)
	local function update(self, elapsed)
		self.elapsed = (self.elapsed or 0) + elapsed
		local dragged = false
		if self.dragging and self.View then
			local x, y = cursor()
			if x ~= self.dragX or y ~= self.dragY then
				self.focusX = clamp(self.focusX - (x - self.dragX) / self.View.drawWidth * 100, 0, 100)
				self.focusY = clamp(self.focusY + (y - self.dragY) / self.View.drawHeight * 100, 0, 100)
				self.dragX, self.dragY, dragged = x, y, true
			end
		end
		if self.elapsed >= TICK then
			self.elapsed = 0
			self:Refresh(false)
		elseif dragged then
			-- Smooth mouse movement does not increase the live-player polling
			-- frequency: repaint from the last sample between the 5 Hz ticks.
			refresh(self, false, true)
		end
	end
	f:SetScript("OnShow", function(self) self.elapsed = 0; self:SetScript("OnUpdate", update); self:Refresh(true) end)
	f:SetScript("OnHide", function(self)
		self.dragging, self.regionHover = false, false
		if self.OpenMap then self.OpenMap:Hide() end
		if self.Services then self.Services:Clear() end
		if self.regionTip then W.HideTooltip(self.Viewport); self.regionTip = nil end
		if W.MenuShown(self.LayersButton) then W.HideMenu() end
		self:SetScript("OnUpdate", nil)
	end)
	f:SetScript("OnSizeChanged", function(self) self.dirty = true end)
	-- Events only mark this viewer dirty while hidden; no polling or route
	-- work survives its OnHide. Art may reveal new areas while it is open.
	-- Client generations expose different map events; an unavailable event
	-- must never abort creation of the dashboard. Position still polls while
	-- visible if none of these optional refresh hints exists.
	for _, event in ipairs({ "MAP_EXPLORATION_UPDATED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "PLAYER_ENTERING_WORLD" }) do
		pcall(f.RegisterEvent, f, event)
	end
	f:SetScript("OnEvent", function(self) self.artDirty, self.dirty = true, true end)
	f:SetScript("OnUpdate", update)
	f:Refresh(true)
	return f
end
