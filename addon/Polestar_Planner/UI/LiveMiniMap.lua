-- A movable map-only companion to the full live planner. Each window owns
-- its camera; this frame never selects a guide step or changes navigation.
local ADDON, ns = ...
local W, Theme = ns.Widgets, ns.Theme
local Mini = {}
ns.LiveMiniMap = Mini

ns.RegisterDefaults("liveMiniMap", {
	shown = false, width = 420, height = 380, locked = false, opacity = 1, autoZoom = true,
})

local F, map, header, grip, options
local layingOut, saving = false, false
local TOP, CONTROLS = 26, 270
local min, max, floor = math.min, math.max, math.floor

local function number(value)
	if ns.Compat and ns.Compat.Readable then value = ns.Compat.Readable(value) end
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then return value end
end

local function bounds()
	local sw, sh = number(UIParent:GetWidth()) or 1920, number(UIParent:GetHeight()) or 1080
	local maxW, maxH = max(1, sw - 16), max(1, sh - 16)
	return min(320, maxW), min(180, maxH), maxW, maxH
end

local function layout()
	if not F or layingOut then return end
	layingOut = true
	map:ClearAllPoints()
	map:SetPoint("TOPLEFT", F, "TOPLEFT", 0, -TOP)
	map:SetSize(max(1, F:GetWidth()), max(1, F:GetHeight() - TOP))
	F.Title:SetWidth(max(1, F:GetWidth() - CONTROLS))
	layingOut = false
end

local function applyGeometry()
	if not F then return end
	local minW, minH, maxW, maxH = bounds()
	if F.SetResizeBounds then F:SetResizeBounds(minW, minH, maxW, maxH)
	elseif F.SetMinResize then F:SetMinResize(minW, minH); F:SetMaxResize(maxW, maxH) end
	local width = min(maxW, max(minW, number(ns.Get("liveMiniMap.width")) or 420))
	local height = min(maxH, max(minH, number(ns.Get("liveMiniMap.height")) or 380))
	F:SetSize(width, height)
	F:ClearAllPoints()
	local pos = ns.Get("liveMiniMap.pos")
	if type(pos) == "table" and number(pos[1]) and number(pos[2]) then
		local x = min(max(0, pos[1]), max(0, UIParent:GetWidth() - width))
		local y = min(UIParent:GetHeight(), max(height, pos[2]))
		F:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
	else
		F:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	layout()
end

function Mini.SaveState()
	if not F or saving then return end
	saving = true
	ns.Set("liveMiniMap.width", floor(F:GetWidth() + 0.5))
	ns.Set("liveMiniMap.height", floor(F:GetHeight() + 0.5))
	local x, y = F:GetLeft(), F:GetTop()
	if number(x) and number(y) then ns.Set("liveMiniMap.pos", { floor(x + 0.5), floor(y + 0.5) }) end
	if map and map.GetViewState then ns.Set("liveMiniMap.view", map:GetViewState()) end
	saving = false
end

function Mini.GetLocked() return ns.Get("liveMiniMap.locked") == true end
function Mini.GetAutoZoom() return ns.Get("liveMiniMap.autoZoom") ~= false end
function Mini.SetAutoZoom(on)
	if map then map:SetAutoZoom(on) else ns.Set("liveMiniMap.autoZoom", on and true or false) end
end
function Mini.GetOpacity() return min(1, max(0.25, number(ns.Get("liveMiniMap.opacity")) or 1)) end

local function applyOptions()
	if not F then return end
	local locked = Mini.GetLocked()
	if locked then F:StopMovingOrSizing() end
	F:SetMovable(not locked)
	F:SetResizable(not locked)
	grip:SetShown(not locked)
	F:SetAlpha(Mini.GetOpacity())
end

function Mini.SetLocked(locked)
	if F then Mini.SaveState() end
	ns.Set("liveMiniMap.locked", locked and true or false)
	applyOptions()
end
function Mini.SetOpacity(value)
	value = number(value)
	if not value then return end
	ns.Set("liveMiniMap.opacity", min(1, max(0.25, value)))
	applyOptions()
end

function Mini.ShowOptions()
	if not F then return end
	if W.MenuShown(options) then W.HideMenu(); return end
	local items = {
		{ text = "Auto zoom", checked = Mini.GetAutoZoom(), tip = "While Follow is on, frame the remaining walk or your flight destination. Manual zoom pauses this for 5 seconds; Player resumes it immediately.",
			onClick = function() Mini.SetAutoZoom(not Mini.GetAutoZoom()) end },
		{ text = "Lock window", checked = Mini.GetLocked(), tip = "Prevent moving and resizing; map pan and zoom remain available.",
			onClick = function() Mini.SetLocked(not Mini.GetLocked()) end },
		{ separator = true },
	}
	for _, value in ipairs({ 0.25, 0.5, 0.75, 1 }) do
		local opacity = value
		items[#items + 1] = { text = "Opacity " .. floor(opacity * 100 + 0.5) .. "%", checked = Mini.GetOpacity() == opacity,
			onClick = function() Mini.SetOpacity(opacity) end }
	end
	items[#items + 1] = { separator = true }
	items[#items + 1] = { text = "Open full planner", onClick = function()
		if ns.LiveDashboard and ns.LiveDashboard.Show then ns.LiveDashboard.Show() end
	end }
	W.ShowMenu(options, items, { minWidth = 200 })
end

function Mini.Refresh(force)
	if not F or not F:IsVisible() then return end
	layout()
	if force and map and map.Refresh then map:Refresh(true) end
end

-- Reuse the map's controls, but place them beside the zone name in one
-- shallow toolbar. The whole remaining window is terrain, edge to edge.
local function compactToolbar(close)
	map.Info:Hide()
	map.Viewport:ClearAllPoints()
	map.Viewport:SetAllPoints(map)
	map.Zone:SetParent(header)
	map.Zone:ClearAllPoints()
	map.Zone:SetPoint("LEFT", header, "LEFT", 6, 0)
	map.Zone:SetText("Polestar map")
	Theme.Font(map.Zone, "small")
	local previous
	for _, control in ipairs({
		{ close, 20, "Close compact map" },
		{ options, 22, "Map options", "Auto zoom, lock, opacity and the full planner." },
		{ map.LayersButton, 44, "Map layers", "Toggle objective regions, markers and Questie spawn icons." },
		{ map.ZoomInButton, 20, "Zoom in", "You can also scroll the mouse wheel over the map." },
		{ map.ZoomOutButton, 20, "Zoom out", "At the zone overview, zoom out again to see the parent map." },
		{ map.ParentButton, 24, "Parent map", "Show the continent or world map." },
		{ map.PlayerButton, 44, "Center on player", "Return to your current zone and resume following." },
		{ map.FollowButton, 56, "Follow player", "Toggle automatic map following. Panning pauses it until you click Follow or Player, or enter another zone." },
	}) do
		local button, width = control[1], control[2]
		button:SetParent(header)
		button:ClearAllPoints()
		button:SetPoint("RIGHT", previous or header, previous and "LEFT" or "RIGHT", -2, 0)
		button.psFixedWidth = width
		button:SetSize(width, 22)
		Theme.Font(button.Label, "small")
		button.psTip, button.psTipLines = control[3], control[4] and { control[4] } or nil
		button:SetScript("OnEnter", W.SimpleTip); button:SetScript("OnLeave", W.HideTip)
		previous = button
	end
end

local function build()
	if F then return end
	F = CreateFrame("Frame", "PolestarPlannerMiniMap", UIParent)
	F:Hide()
	F:SetFrameStrata("MEDIUM")
	F:SetClampedToScreen(true)
	F:EnableMouse(true)
	-- This is a persistent HUD map; Escape closes game menus, not this view.
	header = CreateFrame("Frame", nil, F)
	header:SetPoint("TOPLEFT", F, "TOPLEFT", 0, 0)
	header:SetPoint("TOPRIGHT", F, "TOPRIGHT", 0, 0)
	header:SetHeight(TOP)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function() if not Mini.GetLocked() then F:StartMoving() end end)
	header:SetScript("OnDragStop", function() F:StopMovingOrSizing(); Mini.SaveState() end)
	header:SetScript("OnEnter", function(self)
		W.Tooltip(self, "ANCHOR_TOP", map.Zone:GetText(), {
			Mini.GetLocked() and "Polestar map · locked. Unlock in Options to move or resize."
				or "Polestar map · drag the zone name to move. Drag the terrain to pan.",
			map.Status:GetText(), map.Hint:GetText(),
		})
	end)
	header:SetScript("OnLeave", W.HideTip)
	W.Fill(header, "bg")
	local close = W.Button(header, "×", function() Mini.Hide() end, { ghost = true, width = 20, height = 22 })
	options = W.Button(header, "...", Mini.ShowOptions, { ghost = true, width = 22, height = 22 })
	map = ns.LiveMap.Create(F, { compact = true, autoZoom = Mini.GetAutoZoom(),
		onAutoZoomChanged = function(on) ns.Set("liveMiniMap.autoZoom", on) end })
	compactToolbar(close)
	grip = CreateFrame("Button", nil, F)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", 0, 0)
	grip:SetFrameLevel(F:GetFrameLevel() + 10)
	grip.Icon = W.Tex(grip, "OVERLAY", "resize", "textDim")
	grip.Icon:SetSize(11, 11)
	grip.Icon:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -2, 2)
	grip.psTip = "Resize compact map"
	grip:SetScript("OnEnter", W.SimpleTip); grip:SetScript("OnLeave", W.HideTip)
	grip:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" and not Mini.GetLocked() then F:StartSizing("BOTTOMRIGHT") end
	end)
	grip:SetScript("OnMouseUp", function()
		F:StopMovingOrSizing(); Mini.SaveState(); applyGeometry(); Mini.Refresh(true)
	end)
	F.Map, F.Title, F.Header, F.Grip = map, map.Zone, header, grip
	F.OptionsButton, F.CloseButton = options, close
	F:SetScript("OnSizeChanged", function() layout() end)
	F:SetScript("OnShow", function()
		map:Show()
		Mini.Refresh(true)
	end)
	F:SetScript("OnHide", function()
		F:StopMovingOrSizing()
		Mini.SaveState()
		map:Hide()
		if W.MenuShown(options) then W.HideMenu() end
		-- Alt+Z hides UIParent and invokes OnHide on visible descendants,
		-- while their own IsShown flag stays true. Preserve the user's HUD
		-- preference in that case so a later reload still restores the map.
		if not F:IsShown() then ns.Set("liveMiniMap.shown", false) end
	end)
	applyGeometry()
	applyOptions()
	if map.ApplyViewState then map:ApplyViewState(ns.Get("liveMiniMap.view")) end
end

function Mini.GetFrame() return F end
function Mini.Show()
	build()
	ns.Set("liveMiniMap.shown", true)
	applyGeometry()
	applyOptions()
	F:Show()
	Mini.Refresh(true)
end
function Mini.Hide() if F then F:Hide() else ns.Set("liveMiniMap.shown", false) end end
function Mini.Toggle() if F and F:IsShown() then Mini.Hide() else Mini.Show() end end

ns.RegisterCommand("minimap", Mini.Toggle, "Toggle the compact live planner map")
ns.On("SETTING_CHANGED", function(path)
	if path == "liveMiniMap.locked" or path == "liveMiniMap.opacity" then applyOptions()
	end
end)
if ns.RegisterEvent then
	ns.RegisterEvent("PLAYER_LOGOUT", Mini.SaveState)
	for _, event in ipairs({ "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
		ns.RegisterEvent(event, function() if F then applyGeometry(); if F:IsShown() then Mini.Refresh(true) end end end)
	end
end
ns.OnLogin(function() if ns.Get("liveMiniMap.shown") then Mini.Show() end end)
