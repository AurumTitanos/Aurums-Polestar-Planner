-- Public adaptation by AurumTitanos, 2026-10-22: reuse installed OpenMap art; no artwork distributed.
-- OpenMap's actual stitched renderer, embedded in each live planner view.
-- Settings/cameras and quest overlays belong to Polestar; the art and its
-- Minimap detail layers are OpenMap's. No WorldMapFrame hooks or addon globals.
local ADDON, ns = ...
local OM = ns.LiveOpenMap or {}
ns.LiveOpenMap = OM

local function number(v)
	local C = ns.Compat
	return not (C and C.IsSecret and C.IsSecret(v)) and type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function safeValue(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

-- Projection dimensions, not a host map's tile-image dimensions. The latter
-- can differ slightly from its rectangle on the stitched world. Every route
-- and pin uses this same normalized rectangle, including at deep zoom.
function OM.Dimensions(mapID)
	if not (C_Map and type(C_Map.GetMapRectOnMap) == "function" and type(C_Map.GetMapArtLayers) == "function") then return end
	local ok, l, r, t, b = pcall(C_Map.GetMapRectOnMap, mapID, 947)
	if mapID == 947 then ok, l, r, t, b = true, 0, 1, 0, 1 end
	if not (ok and number(l) and number(r) and number(t) and number(b) and r > l and b > t) then return end
	local got, layers = pcall(C_Map.GetMapArtLayers, 947)
	local layer = got and layers and layers[1]
	if not (layer and number(layer.layerWidth) and number(layer.layerHeight) and layer.layerWidth > 0 and layer.layerHeight > 0) then return end
	return (r - l) * layer.layerWidth, (b - t) * layer.layerHeight
end

local function context()
	local mod = { defaults = {}, db = {
		minimap = true, minimapFrom = 1, minimapMix = 0.45, minimapDeep = 0.85,
		-- A persistent HUD must not render multiple blurred copies of the
		-- detailed zone textures underneath the same native detail layer.
		soften = false, underground = true, gapMinimap = false,
		colorMatch = 1, desaturate = 0.1, unexplored = "show",
	} }
	local ctx = {
		Media = { path = "Interface\\AddOns\\OpenMap\\Media\\" },
		L = setmetatable({}, { __index = function(_, k) return k end }),
		Safe = {
			IsSecret = function(v) return issecretvalue and issecretvalue(v) or false end,
			Value = safeValue,
			XY = function(v)
				if type(v) ~= "table" then return end
				local x, y
				if v.GetXY then x, y = v:GetXY() else x, y = v.x, v.y end
				if not (number(x) and number(y)) then return end
				return x, y
			end,
			Call = function(fn, ...)
				if type(fn) ~= "function" then return end
				local ok, value = pcall(fn, ...)
				if ok then return safeValue(value) end
			end,
		},
		Header = function(name, order) return { type = "header", name = name, order = order } end,
		GetModule = function() return mod end,
	}
	for k, v in pairs(OM.Data or {}) do ctx[k] = v end
	-- The surrounding Polestar layers already own travel/quest/player pins.
	ctx.MapPlaces = {}
	OM._stitch(ctx)
	OM._close(ctx)
	-- Upstream caches continent corners permanently and then does plain
	-- arithmetic on them. Validate them before its first read, so loading or
	-- protected values never enter that cache. The original projection stays
	-- in charge once the immutable continent corners are readable.
	local S = ctx.MapStitch
	-- The continent artwork has no Teldrassil, so its land alpha would erase
	-- the island's native terrain. Use the generated union of the original
	-- continent and zone coast masks only for Close.lua's native/LOD layers.
	-- Original painted artwork, city banners and lettering stay untouched.
	local originalLandMask, nativeMasks = S.LandMask, {}
	S.LandMask = function(layer, mapID)
		if mapID ~= 1414 then return originalLandMask(layer, mapID) end
		local entry = nativeMasks[layer]
		if not entry then
			entry = { mask = layer:CreateMaskTexture() }
			nativeMasks[layer] = entry
		end
		if not entry.ready then
			if entry.mask:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\OpenMap\\Textures\\NativeDetailLand\\1414", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") == false then
				error("OpenMap detailed-island mask is unavailable; generate it locally and restart WoW")
			end
			local l, r, t, b = S.Rect(mapID)
			if not l then error("OpenMap detailed-island projection is unavailable") end
			S.PlaceWorld(entry.mask, l, t, r, b)
			entry.ready = true
		end
		return entry.mask
	end
	local originalFromYards, readable = S.FromYards, {}
	local function readableCorners(continent)
		if not readable[continent] then
			local mapID = continent == 0 and 1415 or continent == 1 and 1414
			if not (mapID and C_Map and type(C_Map.GetWorldPosFromMapPos) == "function") then return end
			for corner = 0, 1 do
				local ok, _, vector = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(corner, corner))
				local a, b
				if ok then a, b = ctx.Safe.XY(vector) end
				if not (number(a) and number(b)) then return end
			end
			readable[continent] = true
		end
		return true
	end
	S.FromYards = function(continent, x, y)
		if not (number(continent) and number(x) and number(y)) then return end
		-- The upstream axis-order check also reads Stormwind's continent,
		-- even when the requested coordinates are on Kalimdor.
		if not readableCorners(0) or not readableCorners(continent) then return end
		return originalFromYards(continent, x, y)
	end
	return ctx, mod
end

function OM.Create(parent)
	local self = { parent = parent, backend = "OpenMap Minimap detail", available = false }

	function self:Hide()
		self.available = false
		if self.S then
			self.S.SetShown(false)
			if self.S.SetPaused then self.S.SetPaused(true) end
		end
		if self.canvas then self.canvas:Hide() end
	end

	function self:Diagnostics()
		return { backend = self.backend, available = self.available, error = self.error,
			map = self.mapID, tiles = self.S and self.S.closeView and self.S.closeView.tiles,
			failures = self.S and self.S.closeFailed }
	end

	local function paint(mapID, v, b)
		-- Check the stitched-map API first. Older clients/fixtures can still
		-- render the existing native terrain without querying illustrated art.
		if not (C_Map and type(C_Map.GetMapRectOnMap) == "function" and type(C_Map.GetMapArtLayers) == "function"
			and type(C_Map.GetMapArtLayerTextures) == "function" and type(C_Map.GetMapChildrenInfo) == "function"
			and type(C_Map.GetMapInfoAtPosition) == "function" and C_MapExplorationInfo
			and type(C_MapExplorationInfo.GetExploredMapTextures) == "function" and OM._stitch and OM._close) then
			return false, "OpenMap map-art API is unavailable"
		end
		if not (number(mapID) and v and b and number(v.width) and number(v.height)
			and number(v.drawWidth) and number(v.drawHeight) and number(v.offsetX) and number(v.offsetY)
			and v.width > 0 and v.height > 0 and v.drawWidth > 0 and v.drawHeight > 0) then
			return false, "OpenMap camera is unavailable"
		end
		-- During a loading screen the map APIs can temporarily return nil.
		-- Do not let upstream's permanent rectangle cache remember that miss.
		local projectionWidth, projectionHeight = OM.Dimensions(mapID)
		if not (number(projectionWidth) and number(projectionHeight)) then
			return false, "OpenMap is waiting for this map's projection"
		end
		if not self.S then
			self.ctx = context()
			self.S = self.ctx.MapStitch
			self.canvas = CreateFrame("Frame", nil, parent)
			self.canvas:SetFrameLevel(parent:GetFrameLevel())
			self.canvas:Hide()
			self.probe = self.canvas:CreateTexture(nil, "BACKGROUND")
			self.probe:Hide()
		end
		-- A running client can fail to discover newly added texture files
		-- until restart. Preserve the working native terrain in that case.
		if self.probe:SetTexture(self.ctx.Media.path .. "Textures\\MapPaper") == false then
			return false, "Install OpenMap for stitched artwork; restart WoW after installing assets"
		end
		if number(b.c) and b.c == 1 and self.probe:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\OpenMap\\Textures\\NativeDetailLand\\1414") == false then
			return false, "OpenMap detailed-island mask is unavailable; generate it locally and restart WoW"
		end
		local S = self.S
		local aw, ah = S.ArtSize(mapID)
		if not (number(aw) and number(ah) and aw > 0 and ah > 0 and S.Rect(mapID)) then
			return false, "OpenMap has no stitched art for this map"
		end
		local l, r, t, bottom = S.Rect(mapID)
		local worldWidth, worldHeight = S.ArtSize(947)
		if not (number(l) and number(r) and number(t) and number(bottom) and r > l and bottom > t
			and number(worldWidth) and number(worldHeight) and worldWidth > 0 and worldHeight > 0) then
			return false, "OpenMap projection is unavailable"
		end
		local hostK = aw / ((r - l) * worldWidth)
		local hostHeight = (bottom - t) * worldHeight * hostK
		local scale = v.drawWidth / aw
		-- The same host map art/coordinate rectangle must project onto the
		-- same pixels as Polestar's quest/route overlays on both axes.
		if math.abs(hostHeight * scale - v.drawHeight) > math.max(0.75, v.drawHeight * 0.000001) then
			return false, "OpenMap art and navigation map proportions differ"
		end
		self.canvas:SetSize(aw, hostHeight)
		self.canvas:SetScale(scale)
		self.canvas:ClearAllPoints()
		self.canvas:SetPoint("TOPLEFT", parent, "TOPLEFT", v.offsetX / scale, -v.offsetY / scale)
		if not S.IsBuilt() then
			local level = parent:GetFrameLevel()
			if not S.Build(self.canvas, level + 1, 32, level + 34) then return false, "OpenMap art did not build" end
			S.ApplyGrade(1, 0.1, "show")
		end
		-- Layout invalidates upstream's scale cache, even for the same map.
		-- Panning must not force every label/zone texture through SetZoom again.
		if self.layoutMap ~= mapID then
			if not S.Layout(mapID) then return false, "OpenMap cannot place this map" end
			self.layoutMap, self.lastDetailZoom, self.lastCanvasScale = mapID, nil, nil
		end
		local W, H = S.Size()
		if not (number(l) and number(r) and number(t) and number(bottom) and r > l and bottom > t
			and number(W) and number(H) and W > 0 and H > 0) then return false, "OpenMap projection is unavailable" end
		local u = l + ((v.width / 2 - v.offsetX) / v.drawWidth) * (r - l)
		local vv = t + ((v.height / 2 - v.offsetY) / v.drawHeight) * (bottom - t)
		local hu = v.width / (2 * v.drawWidth) * (r - l)
		local hv = v.height / (2 * v.drawHeight) * (bottom - t)
		local k = aw / ((r - l) * W)
		local fit = math.min(v.width / W, v.height / H)
		local zoom = scale * k / fit
		local detailK = fit / math.sqrt(v.width * v.height / (W * H))
		self.canvas:Show()
		S.SetShown(true)
		if S.SetPaused then S.SetPaused(false) end
		local detailZoom = zoom * detailK
		local effectiveScale = self.canvas:GetEffectiveScale()
		if self.lastDetailZoom ~= detailZoom or self.lastCanvasScale ~= scale or self.lastEffectiveScale ~= effectiveScale then
			S.SetZoom(detailZoom, scale)
			self.lastDetailZoom, self.lastCanvasScale, self.lastEffectiveScale = detailZoom, scale, effectiveScale
		end
		-- Close.lua remembers errors for its status panel. Judge this paint
		-- on its own result: a recovered client API must not leave this view
		-- permanently on fallback because an earlier paint failed.
		for part in pairs(S.closeFailed or {}) do S.closeFailed[part] = nil end
		S.SetView(u, vv, hu, hv, zoom * detailK, zoom)
		S.SetPlayer(nil)
		if next(S.closeFailed or {}) then
			local part, message = next(S.closeFailed)
			return false, "OpenMap " .. tostring(part) .. ": " .. tostring(message)
		end
		self.mapID, self.available, self.error = mapID, true, nil
		return true
	end

	function self:Paint(mapID, view, bounds)
		local ok, shown, reason = pcall(paint, mapID, view, bounds)
		if ok and shown then return true end
		self.error = ok and reason or tostring(shown)
		self:Hide()
		return false
	end

	return self
end
