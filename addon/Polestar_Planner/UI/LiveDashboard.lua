-- A live, read-only companion to the guide window. This is an ordinary
-- in-game frame: no external transport, saved-file polling or simulated XP.
-- Selecting a row changes this window's inspection only. It never calls
-- Engine.Goto/AimGoal/ToggleGoal or replaces the navigation target.
local ADDON, ns = ...
local Theme, UI = ns.Theme, ns.UI
-- Match the Planner's Inter type ladder locally, without changing the
-- user's compact-guide font or the rest of the addon.
local W = setmetatable({}, { __index = ns.Widgets })
local fontSizes = { small = 11, note = 12, label = 13, body = 13, heading = 16, title = 18, number = 11 }
function W.Text(parent, role, color, layer)
	local fs = ns.Widgets.Text(parent, role, color, layer)
	local weight = (role == "heading" or role == "title" or role == "label") and "SemiBold" or "Medium"
	fs:SetFont("Interface\\AddOns\\Polestar\\Media\\Fonts\\Inter-" .. weight .. ".ttf", fontSizes[role] or 13, "")
	return fs
end
local floor, min, max = math.floor, math.min, math.max
local Dashboard = {}
ns.LiveDashboard = Dashboard

ns.RegisterDefaults("liveDashboard", {
	shown = false, width = 1400, height = 850, followStep = true,
})

local PAD, TOP, FOOT = 12, 72, 28
local F, map, list, details, header, guideTitle, currentText, currentHint
local detailTitle, detailHint, detailText, characterText, xpText, paceText, etaText, xpBar
local followCheck, followButton, empty, emptyText, grip, guideInfo, characterInfo
local stepsHeading, characterHeading, healthText, powerText, characterExtra, characterFacts
local leftPanel, rightPanel, footerText, rightWidth
local rows, views = {}, {}
local selected, guideID, previousCurrent, detailStep, detailGuideID
local dirty, mapDirty, layoutDirty = true, true, true
local elapsed, saving, layingOut = 0, false, false
local ensureVisible = false
local openGeneration = 0
local guideAvailable
local GUIDE_API_UNAVAILABLE = "Polestar guide API unavailable; companion update needed."

local function number(v)
	if ns.Compat and ns.Compat.Readable then v = ns.Compat.Readable(v) end
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
end

local function actual(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, value = pcall(fn, ...)
	return ok and number(value) or nil
end

local function actualText(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, value = pcall(fn, ...)
	if not ok then return nil end
	if ns.Compat and ns.Compat.Readable then value = ns.Compat.Readable(value) end
	return type(value) == "string" and value or nil
end

local function integer(v)
	v = number(v)
	return v and tostring(floor(v + 0.5)) or "Unavailable"
end

local function coreSetting(path)
	if ns.Adapter then return ns.Adapter.CoreSetting(path) end
	return ns.Get(path)
end

-- UnitHealth/UnitPower can return protected numbers in Forever. The client's
-- FontString:SetFormattedText accepts them for display, but Lua must not format,
-- compare or calculate with them. Keep these values out of GetSnapshot entirely.
local function displayNumber(fn)
	if type(fn) == "function" then
		local ok, value = pcall(fn, "player")
		if ok then
			local isSecret = ns.Compat and ns.Compat.IsSecret or issecretvalue
			if isSecret and isSecret(value) then return "%d", value end
			value = number(value)
			if value then return "%d", value end
		end
	end
	return "%s", "Unavailable"
end

local function renderVital(fs, label, color, currentFn, maximumFn, current, maximum)
	local currentFormat, currentValue = displayNumber(currentFn)
	local maximumFormat, maximumValue = displayNumber(maximumFn)
	local prefix = label .. "  |c" .. Theme.Hex(color)
	if type(fs.SetFormattedText) == "function" and
		pcall(fs.SetFormattedText, fs, prefix .. currentFormat .. " / " .. maximumFormat .. "|r", currentValue, maximumValue) then return end
	fs:SetText(prefix .. integer(current) .. " / " .. integer(maximum) .. "|r")
end

local function duration(v)
	v = number(v)
	if not v or v < 0 then return "Unavailable" end
	if v < 60 then return "<1 min" end
	local minutes = math.ceil(v / 60)
	if minutes < 60 then return minutes .. " min" end
	return floor(minutes / 60) .. "h " .. (minutes % 60) .. "m"
end

-- A fresh, primitive-only character snapshot. QoL.GetXPStats returns a
-- reused table; never retain it, and never substitute planner estimates.
function Dashboard.GetSnapshot()
	local E = ns.Engine
	local g = E and E.GetGuide and E.GetGuide() or nil
	local available = E and type(E.GetStepView) == "function" or false
	if ns.Adapter and ns.Adapter.Status then available = ns.Adapter.Status().guide end
	local Q = ns.QoL
	local stats
	if Q and Q.GetXPStats then
		local ok, value = pcall(Q.GetXPStats)
		if ok and type(value) == "table" then stats = value end
	end
	local name = actualText(UnitName, "player")
	local level = (stats and number(stats.level)) or actual(UnitLevel, "player")
	local xp = (stats and number(stats.xp)) or actual(UnitXP, "player")
	local xpMax = (stats and number(stats.xpMax)) or actual(UnitXPMax, "player")
	return {
		guideID = g and g.id, guideTitle = g and (g.title or g.name or g.id),
		guideAvailable = available,
		stepCount = available and E and E.GetStepCount and E.GetStepCount() or 0,
		currentIndex = E and E.GetStepIndex and E.GetStepIndex() or nil,
		liveIndex = E and E.GetLiveStep and E.GetLiveStep() or nil,
		name = type(name) == "string" and name or "Your character",
		class = actualText(UnitClass, "player"),
		health = actual(UnitHealth, "player"), healthMax = actual(UnitHealthMax, "player"),
		power = actual(UnitPower, "player"), powerMax = actual(UnitPowerMax, "player"),
		level = level, xp = xp, xpMax = xpMax,
		percent = xp and xpMax and xpMax > 0 and min(100, max(0, xp / xpMax * 100)) or nil,
		rate = stats and number(stats.rate), timeToLevel = stats and number(stats.timeToLevel),
		maxed = stats and stats.maxed == true or false,
		trackerEnabled = coreSetting("qol.xpTracker") ~= false,
		selectedIndex = selected,
	}
end

local function bounds()
	local sw = number(UIParent:GetWidth()) or 1080
	local sh = number(UIParent:GetHeight()) or 700
	local maxW, maxH = max(320, sw - 24), max(300, sh - 24)
	-- The map has its own controls; below 600px the remaining map viewport
	-- becomes a narrow strip. Small displays still take precedence.
	return min(1080, maxW), min(650, maxH), maxW, maxH
end

local function saveGeometry()
	if not F or saving then return end
	saving = true
	ns.Set("liveDashboard.width", floor(F:GetWidth() + 0.5))
	ns.Set("liveDashboard.height", floor(F:GetHeight() + 0.5))
	local x, y = F:GetLeft(), F:GetTop()
	if x and y then ns.Set("liveDashboard.pos", { floor(x + 0.5), floor(y + 0.5) }) end
	saving = false
end

local function applyGeometry()
	if not F then return end
	local minW, minH, maxW, maxH = bounds()
	if F.SetResizeBounds then F:SetResizeBounds(minW, minH, maxW, maxH)
	elseif F.SetMinResize then F:SetMinResize(minW, minH); F:SetMaxResize(maxW, maxH) end
	local width = min(maxW, max(minW, number(ns.Get("liveDashboard.width")) or 1400))
	local height = min(maxH, max(minH, number(ns.Get("liveDashboard.height")) or 850))
	F:SetSize(width, height)
	F:ClearAllPoints()
	local pos = ns.Get("liveDashboard.pos")
	if type(pos) == "table" and number(pos[1]) and number(pos[2]) then
		local x = min(max(0, pos[1]), max(0, UIParent:GetWidth() - width))
		local y = min(UIParent:GetHeight(), max(height, pos[2]))
		F:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
	else
		F:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

local function summary(v, fallback)
	if not v then return fallback or "Step" end
	local text = UI and UI.StepSummary and UI.StepSummary(v) or v.title
	return type(text) == "string" and text ~= "" and text or fallback or "Step"
end

local function firstGoal(v)
	if not v then return nil end
	if v.current and v.goals[v.current] then return v.goals[v.current] end
	for _, goal in ipairs(v.goals or {}) do
		if not goal.folded and goal.status ~= "done" and goal.status ~= "skipped" and goal.status ~= "na" then return goal end
	end
	return nil
end

local function goalText(g)
	return UI and UI.GoalText and UI.GoalText(g) or g.text or g.subject or g.verb or "Objective"
end

local function ensureCurrentRow(index)
	if not list or not index or not rows[index] then return end
	-- Put the whole heading at the top, even when the row was already visible.
	W.ScrollTo(list, rows[index].psTop or 0)
end

local function showLibrary()
	if ns.UI and ns.UI.ShowPicker then ns.UI.ShowPicker() else ns.Fire("SHOW_PICKER") end
end

function Dashboard.SelectStep(index)
	local E = ns.Engine
	local count = E and E.GetStepCount and E.GetStepCount() or 0
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > count then return false end
	selected = index
	-- Browsing stays put when the game advances. Follow current step restores
	-- tracking explicitly; it does not change the guide engine itself.
	ns.Set("liveDashboard.followStep", false)
	dirty = true
	Dashboard.Refresh()
	if map and map.ShowStep then map:ShowStep(views[index], index) end
	return true
end

function Dashboard.FollowCurrent()
	ns.Set("liveDashboard.followStep", true)
	local E = ns.Engine
	selected = E and E.GetStepIndex and E.GetStepIndex() or nil
	ensureVisible, dirty = true, true
	Dashboard.Refresh()
	if map and map.ShowPlayer then map:ShowPlayer() end
end

local function rowAt(index)
	if rows[index] then return rows[index] end
	local row = CreateFrame("Button", nil, list.Child)
	row:SetHeight(44)
	row.Selected = W.Fill(row, "panelAlt")
	row.Selected:Hide()
	row.Mark = W.Tex(row, "ARTWORK", "white", "accent")
	row.Mark:SetWidth(3)
	row.Mark:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -3)
	row.Mark:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 3)
	row.Num = W.Text(row, "number", "textDim")
	row.Num:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -9)
	row.Num:SetWidth(23)
	row.Title = W.Text(row, "label", "text")
	row.Title:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -8)
	row.Title:SetWordWrap(true)
	row.Title:SetJustifyV("TOP")
	row.State = W.Text(row, "small", "textMuted")
	row.Goals = {}
	row.Rule = W.Divider(row)
	row.Rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 0)
	row.Rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 0)
	row:SetScript("OnClick", function(self) Dashboard.SelectStep(self.psIndex) end)
	row:SetScript("OnEnter", function(self)
		local v = views[self.psIndex]
		W.Tooltip(self, "ANCHOR_RIGHT", summary(v, "Step " .. self.psIndex), {
			"Inspect this step without changing the guide or arrow.",
		})
	end)
	row:SetScript("OnLeave", W.HideTip)
	row.psIndex = index
	rows[index] = row
	return row
end

-- Like the browser Planner, each row contains the actual actions. Every
-- non-folded objective is visible; a future step is never a placeholder.
local function renderRowGoals(row, view, width, state)
	row.Title:SetWidth(max(30, width - 48))
	local y = 10 + max(17, row.Title:GetStringHeight())
	row.State:ClearAllPoints()
	row.State:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -y)
	row.State:SetWidth(max(30, width - 48))
	row.State:SetText(state)
	row.State:SetShown(state ~= "")
	if state ~= "" then y = y + 17 end
	y = y + 4
	local n = 0
	for _, raw in ipairs(view and view.goals or {}) do
		if not raw.folded then
			n = n + 1
			local g = UI and UI.ReadingGoal and UI.ReadingGoal(view, raw) or raw
			local r = row.Goals[n]
			if not r then
				r = CreateFrame("Frame", nil, row)
				r.Icon = W.Tex(r, "ARTWORK", "icon-accept", "quest")
				r.Icon:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -2)
				r.Icon:SetSize(14, 14)
				r.Text = W.Text(r, "small", "text")
				r.Text:SetPoint("TOPLEFT", r, "TOPLEFT", 20, 0)
				r.Text:SetWordWrap(true); r.Text:SetJustifyV("TOP")
				if r.Text.SetNonSpaceWrap then r.Text:SetNonSpaceWrap(true) end
				row.Goals[n] = r
			end
			local done = g.status == "done"
			local skipped = g.status == "skipped" or g.status == "na"
			r.Icon:SetTexture(done and Theme.Media("check") or skipped and Theme.Media("skip") or Theme.VerbIcon(g.t))
			W.Color(r.Icon, done and "success" or skipped and "textMuted" or g.t == "kill" and "danger" or g.t == "collect" and "item" or g.t == "goto" and "place" or "quest")
			local text = UI and UI.GoalLine and UI.GoalLine(g) or goalText(g)
			if g.status == "na" then text = text .. " |c" .. Theme.Hex("textMuted") .. "(not applicable)|r" end
			if g.status == "skipped" and not g.dismissed then text = text .. " |c" .. Theme.Hex("textMuted") .. "(skipped)|r" end
			r.Text:SetWidth(max(30, width - 66))
			r.Text:SetText(text)
			W.Color(r.Text, (done or skipped) and "textMuted" or "text")
			local h = max(18, r.Text:GetStringHeight() + 3)
			r:ClearAllPoints(); r:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -y)
			r:SetSize(max(40, width - 46), h)
			r:Show()
			y = y + h
		end
	end
	for i = n + 1, #row.Goals do row.Goals[i]:Hide() end
	row:SetHeight(max(43, y + 9))
end

local function renderDetails(s)
	local v = selected and views[selected]
	if selected ~= detailStep or s.guideID ~= detailGuideID then
		W.ScrollTo(details, 0)
		detailStep, detailGuideID = selected, s.guideID
	end
	if not v then
		detailTitle:SetText(s.guideAvailable and "Choose a guide to get started" or GUIDE_API_UNAVAILABLE)
		detailHint:SetText("Your character and map remain live.")
		detailText:SetText("")
		return
	end
	detailTitle:SetText("Selected step · " .. selected)
	local atCurrent = selected == s.currentIndex
	if not atCurrent then
		detailHint:SetText("Viewing step " .. selected .. " · route stays on active guide step " .. (s.currentIndex or "—"))
	elseif s.liveIndex and s.liveIndex ~= s.currentIndex then
		detailHint:SetText("Guide preview · first pending step " .. s.liveIndex .. ". Route follows the active guide step.")
	else
		detailHint:SetText("Current guide step · objectives update as you play")
	end
	local lines = {}
	for _, raw in ipairs(v.goals or {}) do
		if not raw.folded then
			local g = UI and UI.ReadingGoal and UI.ReadingGoal(v, raw) or raw
			local status = g.status
			local tag = status == "done" and "[Done] " or status == "skipped" and "[Skipped] " or status == "na" and "[Not applicable] " or "• "
			local progress = UI and UI.GoalProgress and UI.GoalProgress(g)
			lines[#lines + 1] = tag .. goalText(g) .. (progress and ("  " .. progress) or "")
			local extra = UI and UI.GoalSubline and UI.GoalSubline(g) or UI and UI.GoalDetail and UI.GoalDetail(g)
			if extra and extra ~= "" then lines[#lines + 1] = "    " .. extra end
		end
	end
	if v.note and v.note ~= "" then lines[#lines + 1] = "\n" .. v.note end
	detailText:SetText(table.concat(lines, "\n"))
end

local function renderSteps(s)
	local E = ns.Engine
	guideAvailable = s.guideAvailable
	if not guideAvailable then views = {} end
	if s.guideID ~= guideID then
		guideID, previousCurrent, views = s.guideID, nil, {}
		selected = s.currentIndex or (s.stepCount > 0 and 1 or nil)
		ensureVisible = true
		W.ScrollTo(list, 0)
	end
	if selected and selected > s.stepCount then selected = s.currentIndex end
	local following = ns.Get("liveDashboard.followStep") ~= false
	if following and s.currentIndex ~= previousCurrent then
		selected, ensureVisible = s.currentIndex, true
	end
	previousCurrent = s.currentIndex
	followCheck:SetChecked(following)
	guideTitle:SetText(s.guideTitle or "No guide selected")
	guideInfo.psTip = s.guideTitle or "No guide selected"
	guideInfo.psTipLines = s.guideID and { "Guide ID: " .. s.guideID, "This is the guide currently active in Polestar." } or { "Open the library to load your guide." }
	stepsHeading:SetText("Steps  |c" .. Theme.Hex("textMuted") .. s.stepCount .. "|r")
	local top = 0
	for i = 1, s.stepCount do
		local v = E.GetStepView(i)
		views[i] = v
		local row = rowAt(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", list.Child, "TOPLEFT", 0, -top)
		row:SetWidth(max(1, list.Child:GetWidth() - 8))
		row.psTop = top
		row.Num:SetText(i)
		row.Title:SetText(summary(v, "Step " .. i))
		local current = i == s.currentIndex
		local state = current and "CURRENT" or v and v.status == "done" and "Completed" or v and v.status == "skipped" and "Skipped" or v and v.status == "na" and "Not applicable" or ""
		if s.liveIndex == i and not current then state = "First pending step" end
		if selected == i and not current then state = state ~= "" and ("Viewing · " .. state) or "Viewing" end
		renderRowGoals(row, v, row:GetWidth(), state)
		W.Color(row.State, current and "accent" or "textMuted")
		W.Color(row.Num, current and "accent" or "textDim")
		W.Color(row.Title, v and (v.status == "done" or v.status == "skipped" or v.status == "na") and "textDim" or "text")
		row.Mark:SetShown(current)
		row.Selected:SetShown(selected == i)
		row:Show()
		top = top + row:GetHeight()
	end
	for i = s.stepCount + 1, #rows do rows[i]:Hide() end
	-- Leave enough room below the last step to top-align its heading as well.
	local last = s.stepCount > 0 and rows[s.stepCount]
	W.SetScrollContent(list, last and max(top, last.psTop + list:GetHeight()) or top)
	emptyText:SetText(guideAvailable and "No active guide. Open the library and load your guide to see its full step list here." or GUIDE_API_UNAVAILABLE)
	empty:SetShown(s.stepCount == 0)
	local current = s.currentIndex and views[s.currentIndex]
	local goal = firstGoal(current)
	if goal and UI and UI.ReadingGoal then goal = UI.ReadingGoal(current, goal) end
	currentText:SetText(not guideAvailable and GUIDE_API_UNAVAILABLE or goal and ("Now: " .. goalText(goal)) or current and ("Now: " .. summary(current)) or "Open the guide library to choose a route.")
	if not guideAvailable then
		currentHint:SetText("Live character and map")
	elseif s.liveIndex and s.liveIndex ~= s.currentIndex then
		currentHint:SetText("Guide preview · first pending step " .. s.liveIndex)
	else
		currentHint:SetText(s.currentIndex and ("Step " .. s.currentIndex .. " / " .. s.stepCount .. " · live in game") or "Live character · no active guide")
	end
	renderDetails(s)
	if ensureVisible then ensureCurrentRow(s.currentIndex); ensureVisible = false end
end

local function renderStats(s)
	characterText:SetText(s.name .. " · Level " .. integer(s.level) .. (s.class and (" " .. s.class) or ""))
	characterInfo.psTip = "Actual character"
	characterInfo.psTipLines = {
		"These values come from the game. XP/hour measures this play session; time to level is an estimate based on that rate.",
	}
	xpText:SetText("XP  " .. integer(s.xp) .. " / " .. integer(s.xpMax) .. (s.percent and string.format("  (%.0f%%)", s.percent) or ""))
	xpBar:SetValue(s.percent or 0)
	renderVital(healthText, "Health", "success", UnitHealth, UnitHealthMax, s.health, s.healthMax)
	renderVital(powerText, "Resource", "spell", UnitPower, UnitPowerMax, s.power, s.powerMax)
	local rate = s.rate
	if not s.trackerEnabled then
		paceText:SetText("XP/hour: tracker off")
		etaText:SetText("Time to level: tracker off")
	elseif s.maxed then
		paceText:SetText("XP/hour: max level")
		etaText:SetText("Time to level: max level")
	elseif not rate or rate <= 0 then
		paceText:SetText("XP/hour: collecting data")
		etaText:SetText("Time to level: unavailable")
	else
		paceText:SetText("XP/hour: " .. integer(rate))
		etaText:SetText("Time to level: " .. duration(s.timeToLevel))
	end
end

local function renderCharacter()
	local C = ns.LiveCharacter
	local ok, s = false, nil
	if C and C.GetSnapshot then ok, s = pcall(C.GetSnapshot) end
	if not ok or type(s) ~= "table" then
		characterFacts:SetText("")
		characterExtra:SetText("Quest details unavailable")
		return
	end
	local h = s.hearth or {}
	local hearth = h.have == false and "Not carried" or h.ready and "Ready" or h.remaining and ("In " .. duration(h.remaining)) or "Unavailable"
	local facts = {
		"Hearthstone  |c" .. Theme.Hex("text") .. hearth .. "|r",
		"Bind  |c" .. Theme.Hex("place") .. (h.bind or "Unavailable") .. "|r",
		"Quest log  |c" .. Theme.Hex("text") .. (s.questLogAvailable and (integer(s.questCount) .. " / " .. integer(s.questMax)) or "Unavailable") .. "|r",
		"Travel  |c" .. Theme.Hex("text") .. (s.travel or "Unavailable") .. "|r",
	}
	characterFacts:SetText(table.concat(facts, "\n"))
	local lines = { "|c" .. Theme.Hex("text") .. "In the log|r", "" }
	if s.questLogAvailable then
		for _, q in ipairs(s.quests or {}) do
			lines[#lines + 1] = "|c" .. Theme.Hex(q.ready and "success" or "quest") .. (q.title or "Quest") .. (q.ready and " · Ready" or "") .. "|r"
			if q.ready and q.id and ns.RoutePlan then
				local plan = ns.RoutePlan.GetTurnIn(q.id)
				local warning = plan.status == "missed" or plan.status == "skipped" or plan.status == "unplanned"
				lines[#lines + 1] = "  |c" .. Theme.Hex(warning and "quest" or "textDim") .. ns.RoutePlan.Describe(plan) .. "|r"
			end
			for _, o in ipairs(q.objectives or {}) do
				local text = o.text or "Objective"
				local count = number(o.cur) and number(o.max) and ("  " .. integer(o.cur) .. "/" .. integer(o.max)) or ""
				if text:match("%d+%s*/%s*%d+") then count = "" end
				lines[#lines + 1] = "  |c" .. Theme.Hex(o.finished and "success" or "textDim") .. text .. count .. "|r"
			end
			lines[#lines + 1] = ""
		end
		if #(s.quests or {}) == 0 then lines[#lines + 1] = "No quests in your log."; lines[#lines + 1] = "" end
	else lines[#lines + 1] = "Quest log unavailable"; lines[#lines + 1] = "" end
	lines[#lines + 1] = "|c" .. Theme.Hex("text") .. "Quest items|r"
	if s.itemsAvailable then
		for _, item in ipairs(s.items or {}) do
			lines[#lines + 1] = "|c" .. Theme.Hex("item") .. (item.name or "Quest item") .. "|r  ×" .. integer(item.count)
		end
		if #(s.items or {}) == 0 then lines[#lines + 1] = "No quest items carried." end
	else lines[#lines + 1] = "Bag information unavailable" end
	if type(s.flightPaths) == "table" then
		lines[#lines + 1] = "\n|c" .. Theme.Hex("text") .. "Flight paths|r"
		for _, name in ipairs(s.flightPaths) do lines[#lines + 1] = name end
	end
	characterExtra:SetText(table.concat(lines, "\n"))
end

local function layoutCharacter()
	if not details or not rightWidth then return end
	local width, y = max(40, rightWidth - 30), 12
	local function text(fs, gap, minimum, fixed)
		fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", details.Child, "TOPLEFT", 12, -y)
		fs:SetWidth(width)
		-- A fixed height limits the client's wrapped-text measurement. Clear
		-- the previous layout's height before measuring new or resized text;
		-- otherwise the empty first layout can keep a whole block on one line.
		fs:SetHeight(0)
		-- Protected text can also have protected measurements. Vitals use a
		-- fixed single-line slot; never read their rendered text back into Lua.
		local h = fixed or max(minimum or 15, math.ceil(fs:GetStringHeight()))
		fs:SetHeight(h)
		y = y + h + (gap or 7)
	end
	text(characterText, 10, 24)
	text(xpText, 7)
	xpBar:ClearAllPoints(); xpBar:SetPoint("TOPLEFT", details.Child, "TOPLEFT", 12, -y)
	xpBar:SetSize(width, 3); y = y + 14
	text(paceText, 6); text(etaText, 12)
	text(healthText, 6, nil, 15); text(powerText, 14, nil, 15)
	text(characterFacts, 18)
	text(characterExtra, 22)
	text(detailTitle, 6, 20)
	text(detailHint, 12)
	text(detailText, 12)
	characterInfo:ClearAllPoints(); characterInfo:SetPoint("TOPLEFT", characterText, "TOPLEFT", 0, 0)
	characterInfo:SetSize(width, characterText:GetHeight())
	W.SetScrollContent(details, y)
end

local function layout()
	if not F or layingOut then return end
	layingOut = true
	local width, height = F:GetWidth(), F:GetHeight()
	local left = min(340, max(280, floor(width * 0.23)))
	rightWidth = min(320, max(250, floor(width * 0.21)))
	local bodyHeight = max(150, height - TOP - FOOT)
	leftPanel:SetSize(left, bodyHeight)
	leftPanel:ClearAllPoints(); leftPanel:SetPoint("TOPLEFT", F, "TOPLEFT", 0, -TOP)
	rightPanel:SetSize(rightWidth, bodyHeight)
	rightPanel:ClearAllPoints(); rightPanel:SetPoint("TOPRIGHT", F, "TOPRIGHT", 0, -TOP)
	list:ClearAllPoints()
	list:SetPoint("TOPLEFT", F, "TOPLEFT", 0, -(TOP + 38))
	list:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", 0, FOOT)
	list:SetWidth(left)
	list.Child:SetWidth(left)
	if map then
		map:ClearAllPoints()
		map:SetPoint("TOPLEFT", F, "TOPLEFT", left + 1, -TOP)
		map:SetSize(max(1, width - left - rightWidth - 2), bodyHeight)
	end
	details:ClearAllPoints()
	details:SetPoint("TOPRIGHT", F, "TOPRIGHT", 0, -(TOP + 38))
	details:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", 0, FOOT)
	details:SetWidth(rightWidth)
	details.Child:SetWidth(max(1, rightWidth - 10))
	guideTitle:SetWidth(max(1, width - 600))
	guideInfo:SetSize(max(1, width - 400), 22)
	currentText:SetWidth(max(1, width - 470))
	currentHint:SetWidth(280)
	layoutCharacter()
	layoutDirty, layingOut = false, false
end

function Dashboard.Refresh(force)
	if not F or not F:IsShown() then dirty, mapDirty = true, true; return end
	if layoutDirty then layout() end
	local s = Dashboard.GetSnapshot()
	if force or s.guideID ~= guideID or s.currentIndex ~= previousCurrent or s.guideAvailable ~= guideAvailable then dirty = true end
	if dirty then renderSteps(s); dirty = false end
	renderStats(s)
	renderCharacter()
	layoutCharacter()
	if map and (force or mapDirty) and map.Refresh then map:Refresh(true); mapDirty = false end
end

local function update(self, delta)
	elapsed = elapsed + delta
	if elapsed < 0.2 then return end
	elapsed = 0
	Dashboard.Refresh()
end

local function build()
	if F then return end
	F = CreateFrame("Frame", "PolestarPlannerDashboard", UIParent)
	F:Hide()
	Dashboard.frame = F
	F:SetFrameStrata("DIALOG")
	F:SetClampedToScreen(true)
	F:SetMovable(true)
	F:SetResizable(true)
	F:EnableMouse(true)
	Theme.Skin(F, "window")
	if UISpecialFrames then table.insert(UISpecialFrames, "PolestarPlannerDashboard") end

	header = CreateFrame("Frame", nil, F)
	header:SetPoint("TOPLEFT", F, "TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", F, "TOPRIGHT", -1, -1)
	header:SetHeight(43)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function() F:StartMoving() end)
	header:SetScript("OnDragStop", function() F:StopMovingOrSizing(); saveGeometry() end)
	local band = Theme.Band(header); band:SetAllPoints(header)
	local title = W.Text(header, "label", "text")
	title:SetPoint("LEFT", header, "LEFT", PAD, 0)
	title:SetText("Polestar Planner")
	local close = W.Button(header, "Close", function() Dashboard.Hide() end, { ghost = true, width = 65 })
	close:SetPoint("RIGHT", header, "RIGHT", -7, 0)
	local compact = W.Button(header, "Small map", function()
		if ns.LiveMiniMap then Dashboard.Hide(); ns.LiveMiniMap.Show() end
	end, { ghost = true, width = 85 })
	compact:SetPoint("RIGHT", close, "LEFT", -4, 0)
	F.CompactButton = compact
	local library = W.Button(header, "Library", showLibrary, { ghost = true, width = 68 })
	library:SetPoint("LEFT", title, "RIGHT", 14, 0)
	F.CloseButton, F.LibraryButton = close, library
	guideTitle = W.Text(header, "label", "text")
	guideTitle:SetPoint("LEFT", library, "RIGHT", 12, 0)
	guideInfo = CreateFrame("Frame", nil, header)
	guideInfo:SetPoint("TOPLEFT", guideTitle, "TOPLEFT", 0, 0)
	guideInfo:EnableMouse(true)
	guideInfo:SetScript("OnEnter", W.SimpleTip)
	guideInfo:SetScript("OnLeave", W.HideTip)
	local badge = W.Text(header, "small", "success")
	badge:SetPoint("RIGHT", compact, "LEFT", -12, 0)
	badge:SetText("LIVE IN GAME")
	local strip = F:CreateTexture(nil, "BACKGROUND")
	strip:SetColorTexture(0.07, 0.086, 0.14, 1)
	strip:SetPoint("TOPLEFT", F, "TOPLEFT", 0, -44)
	strip:SetPoint("TOPRIGHT", F, "TOPRIGHT", 0, -44); strip:SetHeight(28)
	followButton = W.Button(F, "Follow current", function() Dashboard.FollowCurrent() end, { width = 112, height = 23 })
	followButton:SetPoint("TOPRIGHT", F, "TOPRIGHT", -8, -46)
	followCheck = W.Checkbox(F, function(self)
		if self:GetChecked() then Dashboard.FollowCurrent() else ns.Set("liveDashboard.followStep", false) end
	end)
	followCheck:SetPoint("RIGHT", followButton, "LEFT", -5, 0)
	followCheck.psTip = "Keep current in view"
	followCheck.psTipLines = { "Follow the active guide step as it advances. Clicking a step pauses this window's following." }
	followCheck:SetScript("OnEnter", W.SimpleTip)
	followCheck:SetScript("OnLeave", W.HideTip)
	currentText = W.Text(F, "small", "textDim")
	currentText:SetPoint("TOPLEFT", F, "TOPLEFT", PAD, -51)
	currentHint = W.Text(F, "small", "accent")
	currentHint:SetPoint("TOPRIGHT", F, "TOPRIGHT", -160, -51)
	currentHint:SetJustifyH("RIGHT")
	leftPanel, rightPanel = CreateFrame("Frame", nil, F), CreateFrame("Frame", nil, F)
	local leftGround = leftPanel:CreateTexture(nil, "BACKGROUND"); leftGround:SetAllPoints(leftPanel); leftGround:SetColorTexture(18 / 255, 22 / 255, 36 / 255, 1)
	local rightGround = rightPanel:CreateTexture(nil, "BACKGROUND"); rightGround:SetAllPoints(rightPanel); rightGround:SetColorTexture(24 / 255, 29 / 255, 45 / 255, 1)
	stepsHeading = W.Text(leftPanel, "label", "text")
	stepsHeading:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", PAD, -12)
	characterHeading = W.Text(rightPanel, "label", "text")
	characterHeading:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", PAD, -12); characterHeading:SetText("Character · live")
	local lr = W.Divider(leftPanel); lr:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, -37); lr:SetPoint("TOPRIGHT", leftPanel, "TOPRIGHT", 0, -37)
	local rr = W.Divider(rightPanel); rr:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, -37); rr:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", 0, -37)
	list, details = W.Scroll(F), W.Scroll(F)
	list:SetFrameLevel(leftPanel:GetFrameLevel() + 1)
	details:SetFrameLevel(rightPanel:GetFrameLevel() + 1)
	characterText = W.Text(details.Child, "heading", "text")
	characterInfo = CreateFrame("Frame", nil, details.Child)
	characterInfo:EnableMouse(true); characterInfo:SetScript("OnEnter", W.SimpleTip); characterInfo:SetScript("OnLeave", W.HideTip)
	xpText = W.Text(details.Child, "note", "textDim")
	paceText, etaText = W.Text(details.Child, "note", "text"), W.Text(details.Child, "note", "textDim")
	healthText, powerText = W.Text(details.Child, "small", "textDim"), W.Text(details.Child, "small", "textDim")
	healthText:SetWordWrap(false); powerText:SetWordWrap(false)
	characterFacts, characterExtra = W.Text(details.Child, "note", "textDim"), W.Text(details.Child, "small", "textDim")
	xpBar = CreateFrame("StatusBar", nil, details.Child)
	xpBar:SetStatusBarTexture(Theme.Media("white")); xpBar:SetMinMaxValues(0, 100)
	W.Fill(xpBar, "panelAlt"); W.Painter(xpBar, function(self) self:SetStatusBarColor(Theme.Color("accent")) end)
	map = ns.LiveMap and ns.LiveMap.Create and ns.LiveMap.Create(F) or nil
	if not map then
		map = CreateFrame("Frame", nil, F)
		Theme.Skin(map, "panel")
		local unavailable = W.Text(map, "body", "textDim")
		unavailable:SetPoint("CENTER", map, "CENTER", 0, 0)
		unavailable:SetText("Live map component is unavailable.")
	end
	detailTitle = W.Text(details.Child, "label", "text")
	detailHint = W.Text(details.Child, "small", "textDim")
	detailText = W.Text(details.Child, "note", "text")
	for _, fs in ipairs({ characterText, xpText, paceText, etaText, characterFacts, characterExtra, detailTitle, detailHint, detailText }) do
		fs:SetWordWrap(true); fs:SetJustifyV("TOP")
		if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(true) end
	end
	characterFacts:SetSpacing(4); characterExtra:SetSpacing(3); detailText:SetSpacing(3)
	empty = CreateFrame("Frame", nil, list)
	empty:SetAllPoints(list)
	emptyText = W.Text(empty, "body", "textDim")
	emptyText:SetPoint("TOPLEFT", empty, "TOPLEFT", 9, -16)
	emptyText:SetWidth(225)
	emptyText:SetWordWrap(true)
	emptyText:SetText("No active guide. Open the library and load your guide to see its full step list here.")
	local open = W.Button(empty, "Open guide library", showLibrary, { primary = true })
	open:SetPoint("TOPLEFT", emptyText, "BOTTOMLEFT", 0, -16)
	local footer = W.Text(F, "small", "textMuted")
	footer:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", PAD, 9)
	footer:SetPoint("RIGHT", F, "RIGHT", -40, 0)
	footer:SetText("Live in game · browsing steps does not change progress or the arrow · drag the title bar to move")
	grip = CreateFrame("Button", nil, F)
	grip:SetSize(25, 25)
	grip:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", -2, 2)
	grip:SetFrameLevel(F:GetFrameLevel() + 10)
	grip.Icon = W.Tex(grip, "OVERLAY", "resize", "textDim")
	grip.Icon:SetSize(14, 14)
	grip.Icon:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -3, 3)
	grip.psTip = "Resize width and height"
	grip:SetScript("OnEnter", function(self) W.Color(self.Icon, "text"); W.SimpleTip(self) end)
	grip:SetScript("OnLeave", function(self) W.Color(self.Icon, "textDim"); W.HideTip(self) end)
	grip:SetScript("OnMouseDown", function(_, button) if button == "LeftButton" then F:StartSizing("BOTTOMRIGHT") end end)
	grip:SetScript("OnMouseUp", function() F:StopMovingOrSizing(); saveGeometry(); layoutDirty = true; Dashboard.Refresh() end)
	F:SetScript("OnSizeChanged", function() layoutDirty, dirty = true, true end)
	F:SetScript("OnShow", function()
		elapsed, dirty, mapDirty, layoutDirty = 0, true, true, true
		openGeneration = openGeneration + 1
		F:SetScript("OnUpdate", update)
		Dashboard.FollowCurrent()
		-- The client can settle wrapped text/anchors after the frame first shows.
		-- Remeasure once, without pulling the user back after they scroll or browse.
		if C_Timer and C_Timer.After then
			local generation, index, offset = openGeneration, selected, list:GetVerticalScroll()
			C_Timer.After(0, function()
				if F:IsShown() and generation == openGeneration and selected == index and
					ns.Get("liveDashboard.followStep") ~= false and list:GetVerticalScroll() == offset then
					dirty, ensureVisible = true, true
					Dashboard.Refresh()
				end
			end)
		end
	end)
	F:SetScript("OnHide", function()
		F:SetScript("OnUpdate", nil)
		F:StopMovingOrSizing()
		saveGeometry()
		ns.Set("liveDashboard.shown", false)
	end)
	F.Map, F.List, F.Details, F.Rows = map, list, details, rows
	F.CharacterText, F.XPText, F.PaceText, F.ETAText = characterText, xpText, paceText, etaText
	F.FollowButton, F.FollowCheck, F.Grip = followButton, followCheck, grip
	F.GuideInfo, F.CharacterInfo = guideInfo, characterInfo
	F.CurrentText, F.CurrentHint, F.DetailTitle, F.DetailText = currentText, currentHint, detailTitle, detailText
	F.EmptyText = emptyText
	F.CharacterScroll, F.CharacterBody, F.CharacterExtra = details, details.Child, characterExtra
	F.CharacterFacts, F.HealthText, F.PowerText = characterFacts, healthText, powerText
	applyGeometry()
	layout()
end

function Dashboard.GetFrame() return F end
function Dashboard.Show()
	build()
	ns.Set("liveDashboard.shown", true)
	applyGeometry()
	F:Show()
	Dashboard.Refresh(true)
end
function Dashboard.Hide() if F then F:Hide() else ns.Set("liveDashboard.shown", false) end end
function Dashboard.Toggle() if F and F:IsShown() then Dashboard.Hide() else Dashboard.Show() end end

local function markDirty() dirty, mapDirty = true, true end
for _, event in ipairs({ "GUIDE_CHANGED", "STEP_CHANGED", "STEP_UPDATED", "GUIDES_REGISTERED", "PACKS_CHANGED", "GUIDE_COMPLETED", "WAYPOINT_CHANGED", "TABS_CHANGED" }) do
	ns.On(event, markDirty)
end
ns.On("QOL_XP_UPDATED", function() if F and F:IsShown() then elapsed = 0.2 end end)
ns.On("SETTING_CHANGED", function(path)
	if path == "liveDashboard.followStep" then dirty = true end
end)
if ns.RegisterEvent then
	ns.RegisterEvent("DISPLAY_SIZE_CHANGED", function() if F then applyGeometry(); layoutDirty = true end end)
	ns.RegisterEvent("UI_SCALE_CHANGED", function() if F then applyGeometry(); layoutDirty = true end end)
end
ns.OnLogin(function() if ns.Get("liveDashboard.shown") then Dashboard.Show() end end)
