-- Native Planner rendering of Nav's cached spawn-region hulls. Geometry is
-- supplied by LiveObjectives; this view never chooses a goal or a spawn.
-- Mouse hit testing belongs to the map viewport so regions do not steal
-- dragging, wheel zoom, or objective-pin tooltips.
local ADDON, ns = ...
local Regions = {}
ns.LiveRegions = Regions

local min, max, abs = math.min, math.max, math.abs
local WHITE = "Interface\\Buttons\\WHITE8X8"
local MAX_REGIONS, MAX_LINES, MAX_FILLS = 512, 8192, 4096
local EPSILON = 0.0001

local function numeric(v)
	if ns.Compat and ns.Compat.IsSecret and ns.Compat.IsSecret(v) then return false end
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function same(a, b)
	if not a or #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

local function color(region)
	local name = region.active and "arrow" or "place"
	if ns.Nav and type(ns.Nav.RGB) == "function" then
		local ok, r, g, b = pcall(ns.Nav.RGB, name)
		if ok and numeric(r) and numeric(g) and numeric(b) then return r, g, b end
	end
	if region.active then return 1, 0.79, 0.35 end
	return 1, 0.65, 0.36
end

-- Convex polygon clipping in viewport pixels, x right and y down. A
-- clipped polygon is used only for fill/hit testing: its newly created
-- edges must not appear as artificial region borders along the viewport.
local function clipEdge(points, axis, edge, keepGreater)
	local out = {}
	local previous = points[#points]
	if not previous then return out end
	local before = keepGreater and previous[axis] >= edge or not keepGreater and previous[axis] <= edge
	for _, point in ipairs(points) do
		local inside = keepGreater and point[axis] >= edge or not keepGreater and point[axis] <= edge
		if inside ~= before then
			local t = (edge - previous[axis]) / (point[axis] - previous[axis])
			out[#out + 1] = { previous[1] + t * (point[1] - previous[1]), previous[2] + t * (point[2] - previous[2]) }
		end
		if inside then out[#out + 1] = point end
		previous, before = point, inside
	end
	return out
end

local function clipPolygon(points, box)
	points = clipEdge(points, 1, box[1], true)
	points = clipEdge(points, 1, box[3], false)
	points = clipEdge(points, 2, box[2], true)
	points = clipEdge(points, 2, box[4], false)
	-- Clipping through a corner can repeat a vertex. Remove it before
	-- constructing quads so the common edge has exactly the same endpoints.
	local clean = {}
	for _, p in ipairs(points) do
		local last = clean[#clean]
		if not last or abs(last[1] - p[1]) > EPSILON or abs(last[2] - p[2]) > EPSILON then clean[#clean + 1] = p end
	end
	local a, b = clean[1], clean[#clean]
	if #clean > 1 and abs(a[1] - b[1]) <= EPSILON and abs(a[2] - b[2]) <= EPSILON then clean[#clean] = nil end
	return clean
end

local function clipAxis(start, delta, lo, hi, minimum, maximum)
	if abs(delta) <= EPSILON then
		if start < minimum or start > maximum then return nil end
		return lo, hi
	end
	local a, b = (minimum - start) / delta, (maximum - start) / delta
	if a > b then a, b = b, a end
	lo, hi = max(lo, a), min(hi, b)
	if lo > hi then return nil end
	return lo, hi
end

local function project(map, region)
	local b, v, hull = map.bounds, map.View, region.hull
	if region.c ~= b.c or type(hull) ~= "table" or #hull < 6 or #hull % 2 ~= 0 then return nil end
	local points = {}
	for i = 1, #hull, 2 do
		if not (numeric(hull[i]) and numeric(hull[i + 1])) then return nil end
		points[#points + 1] = {
			v.offsetX + (hull[i + 1] - b.left) * b.kx * v.drawWidth,
			v.offsetY + (hull[i] - b.top) * b.ky * v.drawHeight,
		}
	end
	return points
end

-- Like Nav/Pins.lua, a softly filled polygon is a fan of bent solid
-- texture quads. All pieces share one bounding rectangle, with pixel
-- snapping disabled, so their edges neither overlap nor leave seams.
local function fill(f, points, r, g, b, alpha)
	local left, top, right, bottom, area = math.huge, math.huge, -math.huge, -math.huge, 0
	for i, p in ipairs(points) do
		left, top, right, bottom = min(left, p[1]), min(top, p[2]), max(right, p[1]), max(bottom, p[2])
		local nextPoint = points[i % #points + 1]
		area = area + p[1] * nextPoint[2] - nextPoint[1] * p[2]
	end
	if right - left <= EPSILON or bottom - top <= EPSILON or abs(area) <= EPSILON then return false end
	-- Texture corners run clockwise in screen coordinates.
	if area < 0 then
		local reversed = {}
		for i = #points, 1, -1 do reversed[#reversed + 1] = points[i] end
		points = reversed
	end
	for i = 2, #points - 1, 2 do
		if f.fillCount >= MAX_FILLS then f.truncated = true; break end
		f.fillCount = f.fillCount + 1
		local t = f.FillTextures[f.fillCount]
		if not t then
			t = f:CreateTexture(nil, "BACKGROUND"); t:SetTexture(WHITE)
			if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
			if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
			f.FillTextures[f.fillCount] = t
		end
		local a, c, d, e = points[1], points[i], points[i + 1], points[min(i + 2, #points)]
		t:ClearAllPoints(); t:SetPoint("TOPLEFT", f, "TOPLEFT", left, -top)
		t:SetSize(right - left, bottom - top)
		t:SetVertexOffset(1, a[1] - left, top - a[2])
		t:SetVertexOffset(3, c[1] - right, top - c[2])
		t:SetVertexOffset(4, d[1] - right, bottom - d[2])
		t:SetVertexOffset(2, e[1] - left, bottom - e[2])
		t:SetVertexColor(r, g, b, alpha); t:Show()
	end
	return true
end

local function borders(f, points, box, r, g, b, alpha)
	-- Inset only the stroke clip, keeping its thickness within the viewport.
	local inset = 0.75
	for i, a in ipairs(points) do
		local z = points[i % #points + 1]
		local dx, dy = z[1] - a[1], z[2] - a[2]
		local lo, hi = clipAxis(a[1], dx, 0, 1, box[1] + inset, box[3] - inset)
		if lo then lo, hi = clipAxis(a[2], dy, lo, hi, box[2] + inset, box[4] - inset) end
		if lo and hi - lo > EPSILON then
			if f.lineCount >= MAX_LINES then f.truncated = true; return end
			f.lineCount = f.lineCount + 1
			local line = f.Lines[f.lineCount]
			if not line then line = f:CreateLine(nil, "ARTWORK"); line:SetColorTexture(1, 1, 1, 1); f.Lines[f.lineCount] = line end
			line:SetThickness(1.5); line:SetVertexColor(r, g, b, alpha)
			line:SetStartPoint("TOPLEFT", f, a[1] + lo * dx, -(a[2] + lo * dy))
			line:SetEndPoint("TOPLEFT", f, a[1] + hi * dx, -(a[2] + hi * dy))
			line:Show()
		end
	end
end

local function inside(points, x, y)
	local sign
	for i, p in ipairs(points) do
		local q = points[i % #points + 1]
		local cross = (q[1] - p[1]) * (y - p[2]) - (q[2] - p[2]) * (x - p[1])
		if abs(cross) > EPSILON then
			local positive = cross > 0
			if sign ~= nil and sign ~= positive then return false end
			sign = positive
		end
	end
	return sign ~= nil
end

local function clear(f)
	for _, t in ipairs(f.FillTextures) do t:Hide() end
	for _, line in ipairs(f.Lines) do line:Hide() end
	f.fillCount, f.lineCount, f.Regions, f.signature = 0, 0, {}, nil
end

function Regions.Create(parent)
	local f = CreateFrame("Frame", nil, parent)
	f:SetAllPoints(parent); f:EnableMouse(false)
	f.FillTextures, f.Lines, f.Regions, f.enabled = {}, {}, {}, true
	f.fillCount, f.lineCount = 0, 0
	function f:SetEnabled(enabled)
		self.enabled, self.signature = enabled and true or false, nil
		self:SetShown(self.enabled)
		if not self.enabled then clear(self) end
	end
	function f:GetEnabled() return self.enabled end
	function f:Refresh(map, scene)
		if not self.enabled then return end
		if not (map and map.art and map.View and map.bounds and scene) then clear(self); return end
		local v, b = map.View, map.bounds
		local ar, ag, ab = color({active = true})
		local pr, pg, pb = color({active = false})
		local sig = { scene, v.width, v.height, v.offsetX, v.offsetY, v.drawWidth, v.drawHeight,
			b.c, b.left, b.top, b.kx, b.ky, ar, ag, ab, pr, pg, pb }
		if same(self.signature, sig) then return end
		self.signature = sig
		self.fillCount, self.lineCount, self.Regions, self.truncated = 0, 0, {}, false
		local box = { max(0, v.offsetX), max(0, v.offsetY), min(v.width, v.offsetX + v.drawWidth), min(v.height, v.offsetY + v.drawHeight) }
		self.box = box
		if box[3] > box[1] and box[4] > box[2] then
			for _, region in ipairs(scene.regions or {}) do
				if #self.Regions >= MAX_REGIONS then self.truncated = true; break end
				local original = project(map, region)
				local clipped = original and clipPolygon(original, box)
				if clipped and #clipped >= 3 then
					local r, g, blue = color(region)
					local finished = region.status == "done" or region.status == "skipped"
					local alpha = finished and 0.25 or region.active and (region.alt and 0.6 or 1) or (region.alt and 0.35 or 0.6)
					if fill(self, clipped, r, g, blue, alpha * 0.12) then
						borders(self, original, box, r, g, blue, alpha * 0.8)
						self.Regions[#self.Regions + 1] = { region = region, points = clipped }
					end
				end
			end
		end
		for i = self.fillCount + 1, #self.FillTextures do self.FillTextures[i]:Hide() end
		for i = self.lineCount + 1, #self.Lines do self.Lines[i]:Hide() end
		self.paints = (self.paints or 0) + 1
	end
	-- All overlapping objectives, once per goal. Coordinates are viewport
	-- pixels measured from its top left; callers own tooltip presentation.
	function f:HitTest(x, y)
		local hits, seen, box = {}, {}, self.box
		if not self.enabled or not self:IsShown() or not numeric(x) or not numeric(y) or not box
			or x < box[1] or y < box[2] or x > box[3] or y > box[4] then return hits end
		for _, record in ipairs(self.Regions) do
			local p = record.region
			local key = p.goalIndex or p.label or p
			if not seen[key] and inside(record.points, x, y) then
				seen[key] = true; hits[#hits + 1] = p
			end
		end
		return hits
	end
	return f
end
