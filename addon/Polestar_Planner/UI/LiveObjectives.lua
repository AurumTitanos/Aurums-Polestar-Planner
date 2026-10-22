-- Read-only objective scene for the native Planner. The compiled guide's
-- spawn discs are the same centres/radii used by the browser Planner; the
-- Engine view supplies current progress and its chosen objective location.
-- No goal selection, spot cycling, or navigation writes happen here.
local ADDON, ns = ...
local Objectives = {}
ns.LiveObjectives = Objectives

local min, max = math.min, math.max
local AREA_LIMIT, MARKER_LIMIT = 512, 64
local MEDIA = "Interface\\AddOns\\Polestar\\Media\\Nav\\"
local PURPLE, GOLD = { 0.77, 0.63, 0.96 }, { 1, 0.79, 0.35 }
local geometryCache = setmetatable({}, { __mode = "k" })

local function numeric(v)
	local C = ns.Compat
	if C and C.IsSecret and C.IsSecret(v) then return false end
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function text(v)
	local C = ns.Compat
	if C and C.IsSecret and C.IsSecret(v) then return nil end
	return type(v) == "string" and v or nil
end

local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end

local function world(mapID, x, y, floor)
	if not (numeric(mapID) and numeric(x) and numeric(y)) or x < 0 or x > 100 or y < 0 or y > 100 then return nil end
	local c, wx, wy = call(ns.Compat and ns.Compat.MapToWorld, mapID, x, y, floor)
	if numeric(c) and numeric(wx) and numeric(wy) then return c, wx, wy end
end

local function same(a, b)
	if not a or #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

local function labelOf(v)
	local text = call(ns.UI and ns.UI.PlainGoalText, v)
	return type(text) == "string" and text or v.text or v.subject or "Objective"
end

local function shown(v, current)
	if v.folded or v.status == "na" then return false end
	return not current or v.status == "active" or v.status == "pending"
end

-- Compiled spots do not move. Cache their world conversion, but retry if a
-- map frame was unavailable. The view's chosen spot can change independently.
local function areasOf(g)
	local cached = geometryCache[g]
	local convert = ns.Compat and ns.Compat.MapToWorld
	if cached and cached.convert == convert and cached.spots == g.spots and cached.map == g.map then return cached.areas end
	local areas, failed = {}, false
	local function add(s)
		if #areas >= AREA_LIMIT or type(s) ~= "table" or not numeric(s.r) or s.r <= 0 then return end
		local c, wx, wy = world(s.map or g.map, s.x, s.y, s.f or g.f)
		if c then areas[#areas + 1] = { c = c, wx = wx, wy = wy, r = s.r, alt = s.alt and true or false }
		else failed = true end
	end
	if type(g.spots) == "table" and #g.spots > 0 then
		for _, spot in ipairs(g.spots) do add(spot) end
	elseif numeric(g.area) then
		add({ x = g.x, y = g.y, r = g.area })
	end
	if not failed then geometryCache[g] = { convert = convert, spots = g.spots, map = g.map, areas = areas } end
	return areas, failed
end

local function sceneFor(f, index, override)
	local E = ns.Engine
	local guide = call(E and E.GetGuide)
	local step = guide and guide.steps and guide.steps[index]
	local view = call(E and E.GetStepView, index) or override
	local currentIndex = call(E and E.GetStepIndex)
	local current = index == currentIndex
	local target = call(ns.Nav and ns.Nav.GetTarget)
	local targetGoal = target and target.stepIndex == index and target.goalIndex or false
	local sig = { guide or false, index or false, current, targetGoal }
	local selected, collecting = {}, {}
	for ordinal, v in ipairs(view and view.goals or {}) do
		if shown(v, current) then
			local gi = numeric(v.index) and v.index or ordinal
			local g = step and step.goals and step.goals[gi] or v
			local p = v.progress
			local ready = v.t == "turnin" and call(ns.LiveQuestie and ns.LiveQuestie.QuestReady, g)
			selected[#selected + 1] = { raw = g, view = v, index = gi, ready = ready }
			for _, value in ipairs({ g, v.status or false, v.map or false, v.x or false, v.y or false,
				v.f or false, v.item or false, labelOf(v), p and p.cur or false, p and p.max or false, ready == nil and "unknown" or ready,
				text(g.title) or false, text(g.from) or false, text(g.npcName) or false, text(g.objName) or false }) do
				sig[#sig + 1] = value
			end
			if v.t == "collect" and numeric(v.quest or g.quest) and v.status ~= "done" and v.status ~= "skipped" then
				collecting[v.quest or g.quest] = true
			end
		end
	end
	if same(f.signature, sig) and not f.retryGeometry then return false end
	f.signature, f.retryGeometry = sig, false
	local scene = { areas = {}, regions = {}, markers = {}, stepIndex = index, current = current, truncated = false }
	for _, item in ipairs(selected) do
		local g, v, gi = item.raw, item.view, item.index
		local areas, failed = areasOf(g)
		local regions = call(ns.NavRegions and ns.NavRegions.ForGoal, g)
		if not regions and type(g.spots) == "table" and #g.spots > 0 then f.retryGeometry = true end
		for _, rg in ipairs(regions or {}) do
			if #scene.regions < AREA_LIMIT then
				scene.regions[#scene.regions + 1] = { c=rg.c, wx=rg.wx, wy=rg.wy, hull=rg.hull,
					goalIndex=gi, label=labelOf(v), detail=v.detail, note=v.note, status=v.status,
					progress=v.progress, active=current and targetGoal==gi, alt=rg.alt, n=rg.n }
			else scene.truncated = true end
		end
		if failed then f.retryGeometry = true end
		for _, a in ipairs(areas) do
			if #scene.areas < AREA_LIMIT then
				scene.areas[#scene.areas + 1] = { c = a.c, wx = a.wx, wy = a.wy, r = a.r,
					alt = a.alt, goalIndex = gi, label = labelOf(v), status = v.status }
			else scene.truncated = true end
		end
		local c, wx, wy = world(v.map or g.map, v.x or g.x, v.y or g.y, v.f or g.f)
		if not c and numeric(v.map or g.map) and numeric(v.x or g.x) and numeric(v.y or g.y) then
			f.retryGeometry = true
		end
		if not c and areas[1] then c, wx, wy = areas[1].c, areas[1].wx, areas[1].wy end
		if c and v.t ~= "note" then
			if #scene.markers < MARKER_LIMIT then
				local marker = { c = c, wx = wx, wy = wy, goalIndex = gi, label = labelOf(v),
					detail = v.detail, note = v.note, progress = v.progress, kind = v.t, status = v.status,
					quest = v.quest or g.quest, title = g.title, qlvl = g.qlvl, oi = v.oi or g.oi,
					npcName = v.npcName or g.npcName, objName = g.objName, npc = v.npc or g.npc,
					from = g.from, fromKind = g.fromKind,
					item = v.item or g.item, active = current and targetGoal == gi,
					delayed = v.t == "turnin" and item.ready ~= true and collecting[v.quest or g.quest] == true, spots = #areas }
				local merged
				if v.t == "accept" or v.t == "turnin" then
					marker.entries = { { kind = marker.kind, quest = marker.quest, title = marker.title, qlvl = marker.qlvl, active = marker.active,
						npcName = marker.npcName, objName = marker.objName } }
					for _, existing in ipairs(scene.markers) do
						local sameActor = (numeric(existing.npc) and numeric(marker.npc) and existing.npc == marker.npc)
							or (type(existing.npcName) == "string" and existing.npcName ~= "" and existing.npcName == marker.npcName)
							or (type(existing.objName) == "string" and existing.objName ~= "" and existing.objName == marker.objName)
						if (existing.kind == "accept" or existing.kind == "turnin") and existing.c == c
							and sameActor and math.abs(existing.wx - wx) < 1 and math.abs(existing.wy - wy) < 1 then
							existing.entries[#existing.entries + 1] = marker.entries[1]
							existing.active = existing.active or marker.active
							merged = true; break
						end
					end
				end
				if not merged then scene.markers[#scene.markers + 1] = marker end
			else scene.truncated = true end
		end
	end
	f.scene, f.sceneBuilds = scene, (f.sceneBuilds or 0) + 1
	return true
end

local function project(map, p)
	local b, v = map.bounds, map.View
	if p.c ~= b.c then return nil end
	return v.offsetX + (p.wy - b.left) * b.kx * v.drawWidth,
		v.offsetY + (p.wx - b.top) * b.ky * v.drawHeight
end

local function paintArea(f, map, p)
	local x, y = project(map, p)
	if not x then return end
	local v = map.View
	-- The native area texture's rim is at 59/64 of its half-size. Preserve
	-- the authored radius in world yards instead of shrinking every disc.
	-- Like the web scene, retain a four-pixel radius at continent zoom.
	local radius = max(4, p.r * v.scale) * 64 / 59
	local left, top, size = x - radius, y - radius, radius * 2
	local x0, y0 = max(0, v.offsetX, left), max(0, v.offsetY, top)
	local x1, y1 = min(v.width, v.offsetX + v.drawWidth, left + size), min(v.height, v.offsetY + v.drawHeight, top + size)
	if x1 <= x0 or y1 <= y0 then return end
	f.areaCount = f.areaCount + 1
	local tex = f.Areas[f.areaCount]
	if not tex then tex = f:CreateTexture(nil, "ARTWORK"); tex:SetTexture(MEDIA .. "area"); f.Areas[f.areaCount] = tex end
	tex:SetTexCoord((x0 - left) / size, (x1 - left) / size, (y0 - top) / size, (y1 - top) / size)
	local finished = p.status == "done" or p.status == "skipped"
	tex:SetVertexColor(PURPLE[1], PURPLE[2], PURPLE[3], finished and 0.18 or p.alt and 0.3 or 0.55)
	tex:ClearAllPoints(); tex:SetPoint("TOPLEFT", f, "TOPLEFT", x0, -y0)
	tex:SetSize(x1 - x0, y1 - y0); tex:Show()
	tex.objectiveArea = p
end

local function markerAt(f, parent, i)
	local marker = f.Markers[i]
	if marker then return marker end
	marker = CreateFrame("Button", nil, parent)
	marker:SetSize(26, 26)
	marker.Back = marker:CreateTexture(nil, "BACKGROUND")
	marker.Back:SetAllPoints(marker); marker.Back:SetTexture(MEDIA .. "pin-fill")
	marker.Back:SetVertexColor(0.025, 0.035, 0.055, 1)
	marker.Ring = marker:CreateTexture(nil, "BORDER")
	marker.Ring:SetAllPoints(marker); marker.Ring:SetTexture(MEDIA .. "ring")
	marker.Icon = marker:CreateTexture(nil, "ARTWORK")
	marker.Icon:SetPoint("CENTER", marker, "CENTER"); marker.Icon:SetSize(16, 16)
	marker:SetScript("OnEnter", function(self)
		local p, lines = self.objective, {}
		if not p then return end
		if ns.LiveQuestie and ns.LiveQuestie.ShowGuideTooltip(self, p, p.label) then return end
		if p.status == "done" then lines[#lines + 1] = "Completed"
		elseif p.status == "skipped" then lines[#lines + 1] = "Skipped" end
		if p.active then lines[#lines + 1] = "Current navigation objective" end
		if p.delayed then lines[#lines + 1] = "Turn in after completing the collection objectives" end
		local progress = p.progress
		if progress and numeric(progress.cur) and numeric(progress.max) then
			lines[#lines + 1] = string.format("Progress: %d / %d", progress.cur, progress.max)
		end
		if p.spots > 0 then lines[#lines + 1] = p.spots .. " spawn clusters in this objective" end
		if type(p.detail) == "string" and p.detail ~= "" then lines[#lines + 1] = p.detail end
		if type(p.note) == "string" and p.note ~= "" then lines[#lines + 1] = p.note end
		if ns.Widgets and ns.Widgets.Tooltip then ns.Widgets.Tooltip(self, "ANCHOR_RIGHT", p.label, lines) end
	end)
	marker:SetScript("OnLeave", function(self) if ns.Widgets and ns.Widgets.HideTip then ns.Widgets.HideTip(self) end end)
	marker:SetScript("OnHide", function(self)
		if ns.Widgets and ns.Widgets.HideTip then ns.Widgets.HideTip(self) end
		self.objective = nil
	end)
	f.Markers[i] = marker
	return marker
end

local function paintMarker(f, map, p)
	local x, y = project(map, p)
	local v = map.View
	if not x or x < max(0, v.offsetX) or y < max(0, v.offsetY)
		or x > min(v.width, v.offsetX + v.drawWidth) or y > min(v.height, v.offsetY + v.drawHeight) then return end
	f.markerCount = f.markerCount + 1
	local marker = markerAt(f, map.MarkerLayer, f.markerCount)
	local hovered = GameTooltip and call(GameTooltip.GetOwner, GameTooltip) == marker and call(GameTooltip.IsShown, GameTooltip)
	local old = marker.objective
	local sameGoal = old and old.goalIndex == p.goalIndex and old.quest == p.quest and old.kind == p.kind and old.label == p.label
	if hovered and not sameGoal and ns.Widgets and ns.Widgets.HideTip then ns.Widgets.HideTip(marker) end
	marker.objective = p
	marker:ClearAllPoints(); marker:SetPoint("CENTER", map.MarkerLayer, "TOPLEFT", x, -y)
	marker:SetSize(p.active and 31 or 26, p.active and 31 or 26)
	local finished = p.status == "done" or p.status == "skipped"
	marker:SetAlpha(finished and 0.35 or p.delayed and 0.5 or 1)
	local tint = p.active and GOLD or PURPLE
	marker.Back:Show(); marker.Ring:Show(); marker.Icon:SetSize(16, 16); marker.Icon:SetTexCoord(0, 1, 0, 1)
	marker.Ring:SetVertexColor(tint[1], tint[2], tint[3], 1)
	local icon = call(ns.Compat and ns.Compat.ItemIcon, p.item)
	marker.Icon:SetTexture(icon or call(ns.Theme and ns.Theme.VerbIcon, p.kind) or MEDIA .. "pin")
	if icon then marker.Icon:SetVertexColor(1, 1, 1, 1)
	else marker.Icon:SetVertexColor(tint[1], tint[2], tint[3], 1) end
	if ns.LiveQuestie then ns.LiveQuestie.PaintGuideMarker(marker, p) end
	marker:Show()
	if hovered and sameGoal then marker:GetScript("OnEnter")(marker) end
end

local function refreshHover(f)
	local owner = GameTooltip and call(GameTooltip.GetOwner, GameTooltip)
	if not owner or not call(GameTooltip.IsShown, GameTooltip) then return end
	for _, marker in ipairs(f.Markers) do
		if owner == marker and marker:IsVisible() and marker.objective then marker:GetScript("OnEnter")(marker); return end
	end
end

function Objectives.Create(parent)
	local f = CreateFrame("Frame", nil, parent)
	f:SetAllPoints(parent)
	f.Areas, f.Markers, f.enabled = {}, {}, true
	f.scene = { areas = {}, regions = {}, markers = {} }
	f.showMarkers, f.showCircles = true, true
	function f:SetLayers(markers, circles)
		if self.showMarkers ~= markers or self.showCircles ~= circles then self.paintSignature = nil end
		self.showMarkers, self.showCircles = markers, circles
	end
	function f:SetEnabled(enabled)
		self.enabled, self.paintSignature = enabled and true or false, nil
		self:SetShown(self.enabled)
		if not self.enabled then
			for _, marker in ipairs(self.Markers) do marker:Hide() end
		end
	end
	function f:GetEnabled() return self.enabled end
	function f:Refresh(map, index, override)
		if not self.enabled then return end
		if not (map and map.art and map.View and map.bounds and index) then
			for _, area in ipairs(self.Areas) do area:Hide() end
			for _, marker in ipairs(self.Markers) do marker:Hide() end
			self.paintSignature = nil
			return
		end
		local changed = sceneFor(self, index, override)
		local v, b = map.View, map.bounds
		local sig = { v.width, v.height, v.offsetX, v.offsetY, v.drawWidth, v.drawHeight, v.scale,
			b.c, b.left, b.top, b.kx, b.ky, map.MarkerLayer }
		if not changed and same(self.paintSignature, sig) then refreshHover(self); return end
		self.paintSignature = sig
		self.areaCount, self.markerCount = 0, 0
		if self.showCircles then for _, p in ipairs(self.scene.areas) do paintArea(self, map, p) end end
		if self.showMarkers then for _, p in ipairs(self.scene.markers) do paintMarker(self, map, p) end end
		for i = self.areaCount + 1, #self.Areas do self.Areas[i]:Hide() end
		for i = self.markerCount + 1, #self.Markers do self.Markers[i]:Hide() end
		self.paints = (self.paints or 0) + 1
	end
	return f
end
