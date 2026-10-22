-- Flight masters on both native Planner maps. The loaded Codex supplies NPC
-- names/spawns; the navigation taxi network remains a fallback without it.
-- This read-only layer owns its pins and never borrows Questie's frames.
local ADDON, ns = ...
local Services = {}
ns.LiveServices = Services

local ICON = 136456 -- interface/minimap/tracking/flightmaster (also used by the browser Planner)
local EMPTY, LIMIT = {}, 256
local function numeric(v)
	if ns.Compat and ns.Compat.IsSecret and ns.Compat.IsSecret(v) then return false end
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end
local function text(v)
	if ns.Compat and ns.Compat.IsSecret and ns.Compat.IsSecret(v) then return nil end
	return type(v) == "string" and v ~= "" and v or nil
end
local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end
local function hideTip(marker)
	if ns.Widgets and ns.Widgets.HideTip then ns.Widgets.HideTip(marker) end
end
local function friendly(faction, side)
	if faction == nil or faction == "AH" or faction == 0 or faction == 3 then return true end
	if side == "Alliance" then return faction == "A" or faction == 1 end
	if side == "Horde" then return faction == "H" or faction == 2 end
	return false
end
local function world(map, x, y, floor)
	if not (numeric(map) and numeric(x) and numeric(y)) or x < 0 or x > 100 or y < 0 or y > 100 then return nil end
	local c, wx, wy = call(ns.Compat and ns.Compat.MapToWorld, map, x, y, floor)
	if numeric(c) and numeric(wx) and numeric(wy) then return c, wx, wy end
end

local function sources(f)
	local X, now = ns.Codex, call(GetTime) or 0
	local loaded = X and call(X.IsLoaded) == true
	-- Loading a data addon is optional and never attempted in combat. Once a
	-- real load failed, let the network fallback stand without repeated loads.
	if X and not loaded and not f.loadAttempted and not call(InCombatLockdown) and type(X.Load) == "function" then
		f.loadAttempted = true
		call(X.Load)
		loaded = call(X.IsLoaded) == true
	end
	local network = call(ns.Nav and ns.Nav.GetTravelData)
	local taxi = type(network) == "table" and type(network.taxi) == "table" and network.taxi or EMPTY
	local info = call(ns.Compat and ns.Compat.GetPlayerInfo)
	local side = type(info) == "table" and text(info.faction)
	local guide = call(ns.Engine and ns.Engine.GetGuide)
	if f.taxi == taxi and f.codex == X and f.loaded == loaded and f.side == side and f.guide == guide
		and (not f.retryGeometry or now < f.retryAt) then return end
	f.taxi, f.codex, f.loaded, f.side, f.guide = taxi, X, loaded, side, guide
	f.scene, f.retryGeometry, f.retryAt = {}, false, now + 1
	f.scans = (f.scans or 0) + 1
	local scene = f.scene
	local exact = {}
	-- Codex spawn coordinates are rounded to 0.1%. A matching compiled flight
	-- master target retains the reference data's full precision and live frame.
	for _, step in ipairs(type(guide) == "table" and guide.steps or EMPTY) do
		for _, goal in ipairs(step.goals or EMPTY) do
			if goal.t == "getfp" and numeric(goal.npc) and numeric(goal.map) and numeric(goal.x) and numeric(goal.y) then
				exact[goal.npc] = goal
			end
		end
	end
	if loaded then
		for _, id in ipairs(call(X.WithRole, "flightmaster") or EMPTY) do
			local npc = call(X.Npc, id)
			if type(npc) == "table" and not npc.instance and friendly(npc.faction, side) then
				for _, spawn in ipairs(type(npc.spawns) == "table" and npc.spawns or EMPTY) do
					local target = exact[id]
					if target and target.map == spawn.map and numeric(spawn.x) and numeric(spawn.y)
						and (target.f or "l") == (spawn.f or "l") and math.abs(target.x-spawn.x) <= 0.11 and math.abs(target.y-spawn.y) <= 0.11 then spawn = target end
					local c, wx, wy = world(spawn.map, spawn.x, spawn.y, spawn.f)
					if c and #scene < LIMIT then
						scene[#scene + 1] = { npc = id, name = text(npc.name), service = text(npc.subName) or ns.L["Flight master"],
							c = c, wx = wx, wy = wy, map = spawn.map, x = spawn.x, y = spawn.y, f = spawn.f }
					elseif not c then f.retryGeometry = true end
				end
			end
		end
	end
	local npcCount = #scene
	for _, node in ipairs(taxi) do
		if friendly(node.faction, side) and numeric(node.c) and numeric(node.wx) and numeric(node.wy) then
			local duplicate
			for i = 1, npcCount do
				local p = scene[i]
				if p.c == node.c and (p.wx - node.wx)^2 + (p.wy - node.wy)^2 < 100^2 then duplicate = true; break end
			end
			if not duplicate and #scene < LIMIT then
				scene[#scene + 1] = { node = node.id, name = text(node.short) or text(node.name), service = ns.L["Flight master"],
					c = node.c, wx = node.wx, wy = node.wy, map = node.map, x = node.x, y = node.y, f = node.f }
			end
		end
	end
	f.paintSignature = nil
end

local function markerAt(f, i)
	local marker = f.Markers[i]
	if marker then return marker end
	marker = CreateFrame("Button", nil, f)
	marker:SetFrameLevel(f:GetFrameLevel() + 1)
	marker:SetSize(22, 22)
	marker.Icon = marker:CreateTexture(nil, "ARTWORK")
	marker.Icon:SetAllPoints(marker)
	if marker.Icon:SetTexture(ICON) == false then marker.Icon:SetTexture("Interface\\Minimap\\Tracking\\FlightMaster") end
	marker:SetScript("OnEnter", function(self)
		local p = self.service
		if p and ns.Widgets and ns.Widgets.Tooltip then
			ns.Widgets.Tooltip(self, "ANCHOR_RIGHT", p.name or p.service, p.name and { p.service } or EMPTY)
		end
	end)
	marker:SetScript("OnLeave", hideTip)
	marker:SetScript("OnHide", function(self) hideTip(self); self.service = nil end)
	f.Markers[i] = marker
	return marker
end

function Services.Create(parent)
	local f = CreateFrame("Frame", nil, parent)
	f:SetAllPoints(parent)
	f.Markers, f.scene, f.markerCount = {}, {}, 0
	function f:Clear()
		for _, marker in ipairs(self.Markers) do marker:Hide() end
		self.markerCount, self.paintSignature = 0, nil
	end
	function f:Refresh(map)
		if not self:IsVisible() then return end
		if not (map and map.art and map.View and map.bounds) then self:Clear(); return end
		sources(self)
		local v, b = map.View, map.bounds
		if not (numeric(b.c) and numeric(b.left) and numeric(b.top) and numeric(b.kx) and numeric(b.ky)
			and numeric(v.width) and numeric(v.height) and numeric(v.offsetX) and numeric(v.offsetY)
			and numeric(v.drawWidth) and numeric(v.drawHeight)) then self:Clear(); return end
		local sig = table.concat({ b.c, b.left, b.top, b.kx, b.ky, v.width, v.height, v.offsetX, v.offsetY, v.drawWidth, v.drawHeight }, ":")
		if sig == self.paintSignature then return end
		self.paintSignature, self.markerCount = sig, 0
		for _, p in ipairs(self.scene) do
			if p.c == b.c then
				local x = v.offsetX + (p.wy - b.left) * b.kx * v.drawWidth
				local y = v.offsetY + (p.wx - b.top) * b.ky * v.drawHeight
				if x >= math.max(11, v.offsetX + 11) and y >= math.max(11, v.offsetY + 11)
					and x <= math.min(v.width - 11, v.offsetX + v.drawWidth - 11) and y <= math.min(v.height - 11, v.offsetY + v.drawHeight - 11) then
					self.markerCount = self.markerCount + 1
					local marker = markerAt(self, self.markerCount)
					if marker.service ~= p then hideTip(marker) end
					marker.service = p
					marker:ClearAllPoints(); marker:SetPoint("CENTER", self, "TOPLEFT", x, -y); marker:Show()
				end
			end
		end
		for i = self.markerCount + 1, #self.Markers do self.Markers[i]:Hide() end
		self.paints = (self.paints or 0) + 1
	end
	f:SetScript("OnHide", function(self) self:Clear() end)
	return f
end
