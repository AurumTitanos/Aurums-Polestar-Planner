-- Optional, read-only Questie spawn layer for the native Planner.
-- Questie has already applied its Forever database, phase and objective filters
-- when it registers these pins. Mirror their data; never reuse/move their
-- frames or call their tooltip (which recolours and mutates Questie's pins).
local ADDON, ns = ...
local QuestieLayer = {}
ns.LiveQuestie = QuestieLayer

local min, max = math.min, math.max
local SCAN_INTERVAL, SCAN_LIMIT, POINT_LIMIT, MARKER_LIMIT = 5, 12000, 3000, 600
local FALLBACK = "Interface\\AddOns\\Polestar\\Media\\Nav\\pin"
local coordinates = setmetatable({}, { __mode = "k" })
local guideMetadata = setmetatable({}, { __mode = "k" })
local hovered
local snapshot
local revision, job, sliceStart, sliceUnits = 0, nil, 0, 0
local consumers = setmetatable({}, { __mode = "k" })
local worker = CreateFrame("Frame")
worker:Hide()
local stats = { slices = 0, worstMs = 0, scans = 0 }
local function clockMS() return debugprofilestop and debugprofilestop() or 0 end
local function checkpoint(units)
	-- A pin rebuild used to synchronously visit thousands of Questie frames.
	-- Spread both scanning and finalization over frames, including off-map pins.
	sliceUnits = sliceUnits + (units or 1)
	if sliceUnits >= 16 or clockMS() - sliceStart >= 0.75 then coroutine.yield() end
end
local function sortByKey(list)
	-- table.sort cannot yield in Lua 5.1. Merge incrementally so a dense zone
	-- (or many objectives sharing one spawn) cannot monopolize a frame here.
	local count, width, scratch = #list, 1, {}
	while width < count do
		for first = 1, count, width * 2 do
			local middle, last = min(first + width, count + 1), min(first + width * 2 - 1, count)
			local left, right = first, middle
			for i = first, last do
				checkpoint(1 / 32)
				if left < middle and (right > last or list[left].key <= list[right].key) then
					scratch[i], left = list[left], left + 1
				else scratch[i], right = list[right], right + 1 end
			end
		end
		for i = 1, count do checkpoint(1 / 32); list[i] = scratch[i] end
		width = width * 2
	end
end
local function visibleConsumer()
	for f in pairs(consumers) do if f.enabled and f:IsVisible() then return true end end
	return false
end
local function invalidate() revision = revision + 1 end
if ns.RegisterEvent then
	for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
		"PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
		ns.RegisterEvent(event, invalidate)
	end
end
function QuestieLayer.GetPerformance() stats.pending = job ~= nil; return stats end

local function readable(v)
	return not (ns.Compat and ns.Compat.IsSecret and ns.Compat.IsSecret(v))
end
local function numeric(v)
	return readable(v) and type(v) == "number" and v == v and v > -math.huge and v < math.huge
end
local function positive(v) return numeric(v) and v > 0 and v or nil end
local function text(v) return readable(v) and type(v) == "string" and v ~= "" and v or nil end
local function tableOf(v) return readable(v) and type(v) == "table" and v or nil end
local function kindOf(goal)
	local authored = text(goal.t) or text(goal.kind)
	if authored then return authored end
	local external = text(goal.Type)
	return external == "available" and "accept" or external == "complete" and "turnin" or external
end
local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then return a, b, c, d end
end
local function same(a, b)
	if not a or #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

local function modules()
	local loader = tableOf(QuestieLoader)
	return loader and tableOf(loader._modules)
end

local function profile()
	local q = tableOf(Questie)
	local db = q and tableOf(q.db)
	return db and tableOf(db.profile) or {}
end

local function shifted() return call(IsShiftKeyDown) == true end

local function detailModules()
	local loaded = modules()
	return loaded and (tableOf(loaded.QuestieLib) or tableOf(loaded.QuestieDB) or tableOf(loaded.QuestXP))
end

local function coloredReward(title, reward)
	local color = title:match("^(|c%x%x%x%x%x%x%x%x)")
	return color and color .. reward .. "|r" or reward
end

local function questRecord(id, goal)
	local loaded = modules()
	local db = loaded and tableOf(loaded.QuestieDB)
	return tableOf(call(db and db.GetQuest, id)) or tableOf(goal and goal.QuestData)
end

local function coloredQuest(id, fallback, state)
	local loaded, p = modules(), profile()
	local lib = loaded and tableOf(loaded.QuestieLib)
	return text(call(lib and lib.GetColoredQuestName, lib, id, p.enableTooltipsQuestLevel, state)) or fallback
end

-- Questie's XP helper applies the current player's level and its max-level
-- preference. This is quest reward XP, never XP for killing the shown mob.
local function rewardText(id, money)
	local loaded, p = modules(), profile()
	local xp = loaded and tableOf(loaded.QuestXP)
	local reward = positive(call(xp and xp.GetQuestLogRewardXP, xp, id, p.showQuestXpAtMaxLevel))
	local out = reward and "(" .. (text(call(FormatLargeNumber, reward)) or tostring(reward)) .. "xp)" or ""
	if money then
		local copper = positive(call(xp and xp.GetQuestRewardMoney, id))
		local currency = tableOf(C_CurrencyInfo)
		local coins = copper and text(call(currency and currency.GetCoinTextureString or GetCoinTextureString, copper))
		if coins then out = out .. (out ~= "" and " " or "") .. "(" .. coins .. ")" end
	end
	return out ~= "" and out or nil
end

local function creatureName(id, name)
	local loaded = modules()
	local db = loaded and tableOf(loaded.QuestieDB)
	local quest = questRecord(id)
	local levels = quest and tableOf(call(db and db.GetCreatureLevels, db, quest))
	local range = levels and tableOf(levels[name])
	if not range then return name end
	local lo, hi = positive(range[1]), positive(range[2])
	if not lo then return name end
	hi = hi or lo
	return name .. " (" .. tostring(lo) .. (hi ~= lo and "-" .. tostring(hi) or "") .. (range[3] == 1 and "+" or "") .. ")"
end

local function boolean(v) if readable(v) and type(v) == "boolean" then return v end end

-- Borrow only documented snapshots and plain data. Questie's tooltip handlers
-- update objectives, recolour pins and attach hover state to their source data.
local function metadata(id)
	local guide = tableOf(call(ns.Engine and ns.Engine.GetGuide))
	if not guide then return nil end
	local entries = guideMetadata[guide]
	if not entries then
		entries = {}
		for _, step in ipairs(tableOf(guide.steps) or {}) do
			for _, g in ipairs(tableOf(step.goals) or {}) do
				if numeric(g.quest) then
					local entry = entries[g.quest] or {}
					entry.title = entry.title or text(g.title)
					entry.level = entry.level or positive(g.qlvl)
					entries[g.quest] = entry
				end
			end
		end
		guideMetadata[guide] = entries
	end
	return entries[id]
end

local function questInfo(goal, includeObjectives)
	goal = tableOf(goal) or {}
	local id = numeric(goal.quest) and goal.quest or numeric(goal.Id) and goal.Id
	if not id then return {} end
	local loaded = modules()
	local cache = loaded and tableOf(loaded.QuestLogCache)
	local cached = id and cache and tableOf(call(cache.TryGetQuest, id))
	local q = questRecord(id, goal)
	local Q = tableOf(C_QuestLog)
	local title = id and Q and text(call(Q.GetTitleForQuestID, id))
	title = title or cached and text(cached.title) or text(goal.title) or q and (text(q.name) or text(q.Name))
	local level = Q and positive(call(Q.GetQuestDifficultyLevel, id))
	level = level or positive(goal.qlvl) or q and (positive(q.level) or positive(q.Level))
	if not level or not title then
		local entry = metadata(id)
		if entry then title = title or entry.title; level = level or entry.level end
	end
	local ready, nativeKnown
	if id and Q then
		local a, b = boolean(call(Q.ReadyForTurnIn, id)), boolean(call(Q.IsComplete, id))
		if a == true or b == true then ready, nativeKnown = true, true
		elseif a == false or b == false then ready, nativeKnown = false, true end
	end
	if not nativeKnown and id then ready = boolean(call(ns.Compat and ns.Compat.IsQuestReadyForTurnIn, id)) end
	if ready == nil and cached and numeric(cached.isComplete) then ready = cached.isComplete == 1 end
	local kind = kindOf(goal)
	local objectives
	if includeObjectives and ready ~= true and kind ~= "accept" and kind ~= "available" then
		objectives = Q and tableOf(call(Q.GetQuestObjectives, id))
		objectives = objectives or cached and tableOf(cached.objectives)
	end
	return { id = id, title = title, level = positive(level),
		ready = ready, objectives = objectives, record = q }
end

function QuestieLayer.QuestReady(goal) return questInfo(goal).ready end

function QuestieLayer.GuideAppearance(goal)
	goal = tableOf(goal) or {}
	local entries = tableOf(goal.entries)
	if entries then
		local preferred = entries[1]
		for _, entry in ipairs(entries) do
			if entry.active then preferred = entry; break end
			if entry.kind == "turnin" and questInfo(entry).ready == true then preferred = entry end
		end
		goal = preferred or goal
	end
	local kind = kindOf(goal)
	if kind ~= "accept" and kind ~= "turnin" then return nil end
	local ready = questInfo(goal).ready
	local key = (kind == "accept" or kind == "available") and "available" or ready == true and "complete" or "incomplete"
	local questie = tableOf(Questie)
	local used, icons = questie and tableOf(questie.usedIcons), questie and tableOf(questie.icons)
	local enum = questie and questie["ICON_TYPE_" .. string.upper(key)]
	local icon = used and numeric(enum) and used[enum] or icons and icons[key]
	local custom = text(icon) or numeric(icon)
	if not custom then icon = "Interface\\GossipFrame\\" .. (key == "available" and "AvailableQuestIcon" or "ActiveQuestIcon") end
	local tint = not custom and key == "incomplete" and .55 or 1
	return { icon = icon, r = tint, g = tint, b = tint, quest = true, ready = ready }
end

local function questLine(goal, info)
	local kind = kindOf(goal)
	local state = (kind == "accept" or kind == "available") and "Available"
		or info.ready == true and "Complete" or info.ready == false and "Incomplete" or "Turn in"
	local title = info.title or text(goal.subject) or "Quest"
	local prefix = info.level and string.format("[%d] ", info.level) or ""
	return "|cffffff00" .. prefix .. title .. " (" .. state .. ")|r"
end

function QuestieLayer.GuideTooltip(goal, fallbackLabel)
	goal = tableOf(goal) or {}
	local info, lines = questInfo(goal), {}
	local shift = shifted()
	local name = text(goal.npcName) or text(goal.objName) or text(goal.Name) or text(goal.from)
	if not name then name = text(fallbackLabel) or text(goal.label) or info.title or "Quest objective" end
	local entries = {}
	for _, entry in ipairs(tableOf(goal.entries) or { goal }) do entries[#entries + 1] = entry end
	for _, entry in ipairs(tableOf(goal.questieEntries) or {}) do entries[#entries + 1] = entry end
	local seen = {}
	for _, entry in ipairs(entries) do
		local current = questInfo(entry, true)
		local role = kindOf(entry) or ""
		local key = tostring(current.id or text(entry.label) or text(entry.title) or "quest") .. ":" .. role
		if not seen[key] then
			seen[key] = true
			local label = questLine(entry, current)
			local title = coloredQuest(current.id, nil, false)
			if title then
				local state = (role == "accept" or role == "available") and "Available"
					or current.ready == true and "Complete" or current.ready == false and "Incomplete" or "Turn in"
				label = title .. " |cffffff00(" .. state .. ")|r"
			end
			local reward = shift and rewardText(current.id, true)
			lines[#lines + 1] = reward and { left = label, right = coloredReward(label, reward) } or label
			if shift then
				local q = current.record
				local description = q and (text(q.Description) or text(q.description))
				if description then lines[#lines + 1] = description
				else
					for _, raw in pairs(q and (tableOf(q.Description) or tableOf(q.description)) or {}) do
						local line = text(raw)
						if line then lines[#lines + 1] = line end
					end
				end
			end
			if current.ready ~= true then
				for i, objective in ipairs(current.objectives or {}) do
					objective = tableOf(objective)
					if objective and (not numeric(entry.oi) or i == entry.oi) then
						local progress = text(objective.text)
						if progress and not string.find(progress, "%d+%s*/%s*%d+") and numeric(objective.numFulfilled) and numeric(objective.numRequired) and objective.numRequired > 0 then
							progress = progress .. string.format("  %d/%d", objective.numFulfilled, objective.numRequired)
						end
						if progress then lines[#lines + 1] = progress end
					end
				end
			end
		end
	end
	local title = "|cff00ff00" .. name .. "|r"
	if not shift and detailModules() then title = title .. " |cff6e6e6e(Hold Shift)|r" end
	return title, lines
end

local function rememberHover(marker, kind, payload, fallback)
	local field = kind == "spawn" and "spawn" or marker.objective == payload and "objective"
		or marker.guideGoal == payload and "guideGoal" or nil
	hovered = { owner = marker, kind = kind, payload = payload, field = field, fallback = fallback }
end

function QuestieLayer.PaintGuideMarker(marker, goal)
	local a = QuestieLayer.GuideAppearance(goal)
	if not a then return false end
	local back, ring = marker.Back, marker.Ring
	if (type(back) == "table" or type(back) == "userdata") and type(back.Hide) == "function" then back:Hide() end
	if (type(ring) == "table" or type(ring) == "userdata") and type(ring.Hide) == "function" then ring:Hide() end
	marker.Icon:SetTexture(a.icon); marker.Icon:SetVertexColor(a.r, a.g, a.b, 1)
	marker.Icon:SetTexCoord(0, 1, 0, 1)
	marker.Icon:SetSize(22, 22)
	if GameTooltip and call(GameTooltip.GetOwner, GameTooltip) == marker and call(GameTooltip.IsShown, GameTooltip) then
		QuestieLayer.ShowGuideTooltip(marker, goal)
	end
	return true
end

function QuestieLayer.ShowGuideTooltip(marker, goal, fallbackLabel)
	goal = tableOf(goal)
	if not goal or not (numeric(goal.quest) or numeric(goal.Id) or QuestieLayer.GuideAppearance(goal)) then return false end
	local title, lines = QuestieLayer.GuideTooltip(goal, fallbackLabel)
	if ns.Widgets and ns.Widgets.Tooltip then ns.Widgets.Tooltip(marker, "ANCHOR_RIGHT", title, lines) end
	rememberHover(marker, "guide", goal, fallbackLabel)
	return true
end

function QuestieLayer.SpawnTooltip(point)
	point = tableOf(point) or {}
	local entries = tableOf(point.entries) or {}
	if point.giver then
		local goals = {}
		for _, e in ipairs(entries) do if e.giver then goals[#goals + 1] = e.goal end end
		return QuestieLayer.GuideTooltip({ entries = goals, npcName = point.name }, point.name)
	end
	local loaded = modules()
	-- Older Questie versions still get the useful copied objective wording.
	if not loaded or not (loaded.QuestieLib or loaded.QuestieDB or loaded.QuestXP) then
		return point.name or "Quest objective", point.lines or {}
	end
	local groups, order = {}, {}
	for _, entry in ipairs(entries) do
		local id = entry.questID
		if numeric(id) then
			local group = groups[id]
			if not group then
				local info = questInfo(entry.goal or { quest = id })
				local fallback = entry.quest or info.title or "Quest " .. id
				if info.level and not fallback:find("^%[") then fallback = "[" .. info.level .. "] " .. fallback end
				group = { id = id, title = coloredQuest(id, fallback, true), entries = {} }
				groups[id], order[#order + 1] = group, group
			end
			group.entries[#group.entries + 1] = entry
		end
	end
	if #order == 0 then return point.name or "Quest objective", point.lines or {} end
	local shift, lines = shifted(), {}
	local title = order[1].title
	if not shift then title = title .. " |cff6e6e6e(Hold Shift)|r" end
	for i, group in ipairs(order) do
		local reward = shift and rewardText(group.id)
		if i == 1 then
			if reward then title = title .. " " .. coloredReward(group.title, reward) end
		elseif reward then lines[#lines + 1] = { left = group.title, right = coloredReward(group.title, reward) }
		else lines[#lines + 1] = group.title end
		local names, progress = {}, {}
		for _, entry in ipairs(group.entries) do
			if shift and not names[entry.name] then
				names[entry.name] = true
				lines[#lines + 1] = "  " .. creatureName(group.id, entry.name)
			end
			local line = text(entry.progress)
			if line and not progress[line] then
				progress[line] = true
				lines[#lines + 1] = line .. (entry.party and " (party objective)" or "")
			end
		end
	end
	return title, lines
end

function QuestieLayer.ShowSpawnTooltip(marker, point)
	if not tableOf(point) then return false end
	local title, lines = QuestieLayer.SpawnTooltip(point)
	if ns.Widgets and ns.Widgets.Tooltip then ns.Widgets.Tooltip(marker, "ANCHOR_RIGHT", title, lines) end
	rememberHover(marker, "spawn", point)
	return true
end

-- Questie only refreshes modifier tooltips while the cursor is over its own
-- maps. Our two maps own this listener; only a currently owned, visible tip
-- can rebuild, and a pooled marker must still refer to the same payload.
ns.RegisterEvent("MODIFIER_STATE_CHANGED", function(_, key)
	if key ~= "LSHIFT" and key ~= "RSHIFT" and key ~= "SHIFT" then return end
	local h = hovered
	if not h then return end
	local owner = h.owner
	if not GameTooltip or call(GameTooltip.GetOwner, GameTooltip) ~= owner
		or call(GameTooltip.IsShown, GameTooltip) ~= true or call(owner.IsVisible, owner) ~= true
		or (h.field and owner[h.field] ~= h.payload) then hovered = nil; return end
	if h.kind == "spawn" then QuestieLayer.ShowSpawnTooltip(owner, h.payload)
	else QuestieLayer.ShowGuideTooltip(owner, h.payload, h.fallback) end
end)

local function world(frame)
	local map, x, y = frame.UiMapID, frame.x, frame.y
	if not (numeric(map) and numeric(x) and numeric(y)) or x < 0 or x > 100 or y < 0 or y > 100 then return nil end
	local convert = ns.Compat and ns.Compat.MapToWorld
	local old = coordinates[frame]
	if old and old.map == map and old.x == x and old.y == y and old.convert == convert then return old end
	local c, wx, wy = call(convert, map, x, y)
	if not (numeric(c) and numeric(wx) and numeric(wy)) then return nil end
	local p = { map = map, x = x, y = y, c = c, wx = wx, wy = wy, convert = convert }
	coordinates[frame] = p
	return p
end

local function visibleObjective(frame)
	local d = tableOf(frame.data)
	if not d or d.Type == "manual" then return nil end
	local o, q = tableOf(d.ObjectiveData), tableOf(d.QuestData)
	local giver = d.Type == "available" or d.Type == "complete"
	if (not giver and not o) or (o and o.HideIcons) or (q and q.HideIcons) then return nil end
	if not giver and o and o.Completed == true and not o.IsPartyObjective then return nil end
	-- IsShown/IsVisible is deliberately irrelevant: the Blizzard map may be
	-- closed, or its minimap may be showing a different zone. `hidden` is
	-- Questie's logical FakeHide flag and retains its tracking/profile filters.
	if frame.hidden then return nil end
	return d, o, q
end

local function appearance(frame, d)
	local t = frame.texture
	local icon = t and call(t.GetTexture, t)
	if not ((text(icon)) or numeric(icon)) then
		local used = Questie and tableOf(Questie.usedIcons)
		icon = used and used[d.Icon]
	end
	if not (text(icon) or numeric(icon)) then icon = FALLBACK end
	local r, g, b
	if t then r, g, b = call(t.GetVertexColor, t) end
	if not (numeric(r) and numeric(g) and numeric(b)) then r, g, b = 1, 1, 1 end
	local db = Questie and tableOf(Questie.db)
	local profile = db and tableOf(db.profile)
	local color = tableOf(d.IconColor)
	-- Match the minimap's objective-color preference even when only the
	-- hidden world-map copy is registered. Its distance fade is irrelevant here.
	if profile and profile.questMinimapObjectiveColors ~= nil then
		if profile.questMinimapObjectiveColors and color
			and numeric(color[1]) and numeric(color[2]) and numeric(color[3]) then
			r, g, b = color[1], color[2], color[3]
		else r, g, b = 1, 1, 1 end
	end
	local uv
	if t and type(t.GetTexCoord) == "function" then
		local result = { pcall(t.GetTexCoord, t) }
		if result[1] and (#result == 5 or #result == 9) then
			uv = {}
			for i = 2, #result do if not numeric(result[i]) then uv = nil; break end; uv[#uv + 1] = result[i] end
		end
	end
	-- Questie draws objective colors on a separate halo, not on the bag art.
	-- BaseOnHide clears that halo when the source map closes; use its minimap
	-- preference and ObjectiveData.Color so our map doesn't lose those colors.
	local glowTexture = frame.glowTexture
	local glowShown = glowTexture and call(glowTexture.IsShown, glowTexture)
	if profile and profile.alwaysGlowMinimap ~= nil then glowShown = profile.alwaysGlowMinimap end
	local glow
	if glowShown then
		local objective = tableOf(d.ObjectiveData)
		local rgb = objective and tableOf(objective.Color)
		local gr, gg, gb
		if rgb then gr, gg, gb = rgb[1], rgb[2], rgb[3] end
		local glowIcon = glowTexture and call(glowTexture.GetTexture, glowTexture)
		local icons = Questie and tableOf(Questie.icons)
		if not (text(glowIcon) or numeric(glowIcon)) then glowIcon = icons and icons.glow end
		if (text(glowIcon) or numeric(glowIcon)) and numeric(gr) and numeric(gg) and numeric(gb) then
			glow = { icon = glowIcon, r = gr, g = gg, b = gb }
		end
	end
	return { icon = icon, r = r, g = g, b = b, uv = uv, glow = glow }
end

local function objectiveEntry(modules, d, o, q)
	if d.Type == "available" or d.Type == "complete" then
		return { name = text(d.Name) or "Quest giver", giver = true,
			goal = { quest = numeric(d.Id) and d.Id, kind = d.Type == "available" and "accept" or "turnin",
				title = q and (text(q.name) or text(q.Name)), qlvl = q and (positive(q.level) or positive(q.Level)),
				npcName = text(d.Name), QuestData = q }, questID = numeric(d.Id) and d.Id,
			key = tostring(d.Id) .. ":" .. d.Type .. ":" .. (text(d.Name) or "") }
	end
	local cache = tableOf(modules.QuestLogCache)
	local cached = cache and call(cache.TryGetQuest, d.Id)
	cached = tableOf(cached)
	local native = cached and not o.IsPartyObjective and not o.IsSourceItem and not o.IsRequiredSourceItem
		and tableOf(cached.objectives) and tableOf(cached.objectives[d.ObjectiveIndex])
	local progress = native and text(native.text) or text(o.NativeText)
	if not progress then
		progress = text(o.Description) or "Quest objective"
		if numeric(o.Collected) and numeric(o.Needed) then
			progress = progress .. string.format("  %d/%d", o.Collected, o.Needed)
		end
	end
	return { name = text(d.Name) or "Quest spawn", questID = numeric(d.Id) and d.Id, quest = cached and text(cached.title)
		or q and (text(q.name) or text(q.Name)) or (numeric(d.Id) and "Quest " .. d.Id or "Quest objective"),
		progress = progress, party = o.IsPartyObjective and true or false,
		goal = { quest = numeric(d.Id) and d.Id, QuestData = q, oi = d.ObjectiveIndex },
		key = tostring(d.Id) .. ":" .. tostring(d.ObjectiveIndex) .. ":" .. (text(d.Name) or "") }
end

local function sameStyle(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do if not sameStyle(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end
local function samePoint(a, b)
	if not a or not b or a.key ~= b.key or a.c ~= b.c or a.wx ~= b.wx or a.wy ~= b.wy
		or a.name ~= b.name or a.giver ~= b.giver or #a.entries ~= #b.entries or not sameStyle(a.appearance, b.appearance) then return false end
	for i, e in ipairs(a.entries) do
		checkpoint(1 / 4)
		local other = b.entries[i]
		if e.key ~= other.key or e.name ~= other.name or e.quest ~= other.quest or e.progress ~= other.progress
			or e.party ~= other.party or e.giver ~= other.giver then return false end
		local g, h = e.goal or {}, other.goal or {}
		if g.quest ~= h.quest or g.kind ~= h.kind or g.title ~= h.title or g.qlvl ~= h.qlvl
			or g.npcName ~= h.npcName or g.oi ~= h.oi or g.QuestData ~= h.QuestData then return false end
	end
	return true
end

local function collect(f, scanRevision)
	local loader = tableOf(QuestieLoader)
	local modules = loader and tableOf(loader._modules)
	local qm = modules and tableOf(modules.QuestieMap)
	local registry = qm and tableOf(qm.questIdFrames)
	if not registry then
		snapshot = nil
		f.scene, f.status, f.available, f.truncated = {}, loader and "Questie pins not ready" or "Questie not loaded", false, false
		return
	end
	-- Both maps read the same registry. Keep one immutable, bounded snapshot
	-- for this scan interval; each window still projects it through its own
	-- camera and owns all of its marker frames. No work runs while hidden.
	local now = call(GetTime) or 0
	local convert = ns.Compat and ns.Compat.MapToWorld
	local qdb = tableOf(Questie) and tableOf(Questie.db)
	local prefs = qdb and tableOf(qdb.profile)
	if snapshot and snapshot.registry == registry and snapshot.modules == modules
		and snapshot.convert == convert and snapshot.prefs == prefs
		and snapshot.revision == scanRevision
		and now >= snapshot.at and now - snapshot.at < SCAN_INTERVAL then
		f.scene, f.status, f.available, f.truncated = snapshot.scene, snapshot.status, true, snapshot.truncated
		return
	end
	local points, byPosition, entriesByData, scans = {}, {}, {}, 0
	local truncated = false
	for _, names in pairs(registry) do
		if type(names) == "table" then
			for name, value in pairs(names) do
				checkpoint()
				scans = scans + 1
				if scans > SCAN_LIMIT then truncated = true; break end
				local frame = type(name) == "string" and _G[name] or type(value) == "string" and _G[value]
				if frame then
					local d, o, q = visibleObjective(frame)
					local p = d and world(frame)
					if p then
						local key = string.format("%d:%.6f:%.6f", p.map, p.x, p.y)
						if d.Type == "available" or d.Type == "complete" then key = key .. ":giver:" .. (text(d.Name) or "") end
						local point = byPosition[key]
						if not point and #points < POINT_LIMIT then
							point = { c = p.c, wx = p.wx, wy = p.wy, map = p.map, x = p.x, y = p.y,
								entries = {}, entryKeys = {}, key = key }
							byPosition[key], points[#points + 1] = point, point
						elseif not point then truncated = true end
						if point then
							-- Prefer the minimap styling, without its distance-dependent alpha.
							local mini = frame.miniMapIcon and true or false
							local appearanceKey = tostring(d.Id) .. ":" .. tostring(d.ObjectiveIndex) .. ":" .. (text(d.Name) or "")
							if not point.appearance or (not point.mini and mini)
								or (point.mini == mini and appearanceKey < point.appearanceKey) then
								point.appearance, point.mini, point.appearanceKey = appearance(frame, d), mini, appearanceKey
							end
							local entry = entriesByData[d]
							if not entry then entry = objectiveEntry(modules, d, o, q); entriesByData[d] = entry end
							if not point.entryKeys[entry.key] then
								point.entryKeys[entry.key] = true; point.entries[#point.entries + 1] = entry
							end
						end
					end
				end
			end
		end
		if scans > SCAN_LIMIT then break end
	end

	sortByKey(points)
	for _, p in ipairs(points) do
		checkpoint()
		sortByKey(p.entries)
		p.name, p.lines = p.entries[1].name, {}
		local multipleNames = false
		for _, e in ipairs(p.entries) do
			checkpoint(1 / 4)
			if e.name ~= p.name then multipleNames = true; break end
		end
		if multipleNames then p.name = "Questie spawns" end
		for _, e in ipairs(p.entries) do
			checkpoint(1 / 4)
			if multipleNames then p.lines[#p.lines + 1] = e.name end
			if e.giver then
				-- SpawnTooltip reads live details on hover, including Shift. Building
				-- them here queried every giver's rewards twice a second unused.
				p.giver = true
			else
				p.lines[#p.lines + 1] = e.quest .. (e.party and " (party objective)" or "")
				p.lines[#p.lines + 1] = e.progress
			end
		end
		if p.giver then p.name = "|cff00ff00" .. p.name .. "|r"
		elseif #p.lines == 0 then
			p.lines[#p.lines + 1] = string.format("Questie spawn location: %.1f, %.1f", p.x, p.y)
		end
		p.entryKeys = nil
	end
	-- Keep unchanged point objects and the scene itself. A safety scan must
	-- not reposition/retexture hundreds of identical pins while standing still.
	if snapshot and snapshot.registry == registry then
		local unchanged = #points == #snapshot.scene
		for i, p in ipairs(points) do
			checkpoint()
			if samePoint(p, snapshot.scene[i]) then points[i] = snapshot.scene[i] else unchanged = false end
		end
		if unchanged then points = snapshot.scene end
	end
	-- The live registry may be replaced while this coroutine yields.
	local live = tableOf(QuestieLoader) and tableOf(QuestieLoader._modules)
	if live ~= modules or not live.QuestieMap or live.QuestieMap.questIdFrames ~= registry then return end
	f.scene, f.available, f.truncated = points, true, truncated
	f.status = #points == 0 and "No active Questie spawn pins" or "Questie quest and objective pins"
	f.scanCount = (f.scanCount or 0) + 1
	stats.scans = stats.scans + 1
	stats.lastError = nil
	snapshot = { at = call(GetTime) or now, revision = scanRevision, registry = registry, modules = modules, convert = convert, prefs = prefs,
		scene = points, status = f.status, truncated = truncated }
end

local function pump()
	if not job or not visibleConsumer() then job = nil; worker:Hide(); return end
	sliceStart, sliceUnits = clockMS(), 0
	local ok, err = coroutine.resume(job.thread)
	stats.slices = stats.slices + 1
	stats.worstMs = math.max(stats.worstMs, clockMS() - sliceStart)
	if not ok or coroutine.status(job.thread) == "dead" then
		-- Questie can remove a table key while a scan yields. Discard that
		-- interrupted scan, preserve the displayed snapshot and retry later.
		if not ok then stats.lastError = tostring(err) end
		job = nil; worker:Hide()
	end
end
worker:SetScript("OnUpdate", pump)

local function requestSnapshot(f)
	local loaded = modules()
	local qm = loaded and tableOf(loaded.QuestieMap)
	local registry = qm and tableOf(qm.questIdFrames)
	local now = call(GetTime) or 0
	local qdb = tableOf(Questie) and tableOf(Questie.db)
	local prefs = qdb and tableOf(qdb.profile)
	if not registry then
		job, snapshot = nil, nil; worker:Hide()
		f.scene, f.status, f.available = {}, loaded and "Questie pins not ready" or "Questie not loaded", false
		return
	end
	if job and job.registry ~= registry then job = nil end
	local stale = not snapshot or snapshot.registry ~= registry or snapshot.modules ~= loaded
		or snapshot.convert ~= (ns.Compat and ns.Compat.MapToWorld)
		or snapshot.revision ~= revision or snapshot.prefs ~= prefs or now < snapshot.at or now - snapshot.at >= SCAN_INTERVAL
	if stale and not job then
		local scanRevision = revision
		job = { registry = registry, thread = coroutine.create(function() collect(f, scanRevision) end) }
		worker:Show(); pump()
	end
	if snapshot and snapshot.registry == registry then
		f.scene, f.status, f.available, f.truncated = snapshot.scene, snapshot.status, true, snapshot.truncated
	else
		if f.sceneRegistry ~= registry then f.scene = {} end
		f.status, f.available, f.truncated = "Loading Questie pins", false, false
	end
	f.sceneRegistry = registry
end

local function markerAt(f, parent, i)
	local marker = f.Markers[i]
	if marker then return marker end
	marker = CreateFrame("Button", nil, parent)
	marker:SetSize(18, 18)
	marker.Glow = marker:CreateTexture(nil, "BACKGROUND")
	marker.Glow:SetPoint("CENTER", marker, "CENTER")
	marker.Glow:SetSize(18 * 1.13, 18 * 1.13)
	marker.Glow:Hide()
	marker.Icon = marker:CreateTexture(nil, "ARTWORK")
	marker.Icon:SetAllPoints(marker)
	marker:SetScript("OnEnter", function(self)
		local p = self.spawn
		if p then QuestieLayer.ShowSpawnTooltip(self, p) end
	end)
	marker:SetScript("OnLeave", function(self)
		if hovered and hovered.owner == self then hovered = nil end
		if ns.Widgets and ns.Widgets.HideTip then ns.Widgets.HideTip(self) end
	end)
	marker:SetScript("OnHide", function(self)
		if hovered and hovered.owner == self then hovered = nil end
		if ns.Widgets and ns.Widgets.HideTip then ns.Widgets.HideTip(self) end
		self.spawn = nil
	end)
	f.Markers[i] = marker
	return marker
end

local function hide(f)
	for _, marker in ipairs(f.Markers) do marker:Hide(); marker.spawn = nil end
	f.markerCount, f.paintSignature = 0, nil
end

local function paint(f, map)
	local b, v = map.bounds, map.View
	local padding = 18 * 1.13 / 2
	local left, right = max(padding, v.offsetX + padding), min(v.width - padding, v.offsetX + v.drawWidth - padding)
	local top, bottom = max(padding, v.offsetY + padding), min(v.height - padding, v.offsetY + v.drawHeight - padding)
	f.markerCount, f.displayTruncated = 0, false
	local objectives = map.Objectives
	local authoredMarkers = objectives and objectives.scene and objectives.scene.markers or {}
	for _, guide in ipairs(authoredMarkers) do guide.questieEntries = nil end
	for _, p in ipairs(f.scene) do
		local duplicate
		if p.giver and objectives and objectives.enabled and objectives.showMarkers then
			for _, guide in ipairs(authoredMarkers) do
				if guide.c == p.c and math.abs(guide.wx - p.wx) < 3 and math.abs(guide.wy - p.wy) < 3 then
					for _, entry in ipairs(p.entries) do
						for _, authored in ipairs(guide.entries or { guide }) do
							local actor = text(authored.npcName) or text(authored.objName) or text(guide.npcName) or text(guide.objName)
							if authored.quest == entry.questID and actor == entry.name then
								duplicate = true
								guide.questieEntries = {}
								for _, other in ipairs(p.entries) do
									if other.giver then guide.questieEntries[#guide.questieEntries + 1] = other.goal end
								end
							end
						end
					end
				end
			end
		end
		if not duplicate and p.c == b.c then
			local x = v.offsetX + (p.wy - b.left) * b.kx * v.drawWidth
			local y = v.offsetY + (p.wx - b.top) * b.ky * v.drawHeight
			if x >= left and x <= right and y >= top and y <= bottom then
				if f.markerCount >= MARKER_LIMIT then f.displayTruncated = true; break end
				f.markerCount = f.markerCount + 1
				local marker, a = markerAt(f, f, f.markerCount), p.appearance
				local hovered = GameTooltip and call(GameTooltip.GetOwner, GameTooltip) == marker and call(GameTooltip.IsShown, GameTooltip)
				local sameSpawn = marker.spawn and marker.spawn.key == p.key
				if hovered and not sameSpawn and ns.Widgets and ns.Widgets.HideTip then ns.Widgets.HideTip(marker) end
				marker.spawn = p
				marker:ClearAllPoints(); marker:SetPoint("CENTER", f, "TOPLEFT", x, -y)
				marker.Icon:SetTexture(a.icon); marker.Icon:SetVertexColor(a.r, a.g, a.b, 1)
				if a.uv then marker.Icon:SetTexCoord(unpack(a.uv)) else marker.Icon:SetTexCoord(0, 1, 0, 1) end
				if a.glow then
					marker.Glow:SetTexture(a.glow.icon)
					marker.Glow:SetVertexColor(a.glow.r, a.glow.g, a.glow.b, 1)
					marker.Glow:Show()
				else marker.Glow:Hide() end
				marker:Show()
				if hovered and sameSpawn then marker:GetScript("OnEnter")(marker) end
			end
		end
	end
	for i = f.markerCount + 1, #f.Markers do f.Markers[i]:Hide(); f.Markers[i].spawn = nil end
	f.paints = (f.paints or 0) + 1
end

function QuestieLayer.Create(parent)
	local f = CreateFrame("Frame", nil, parent)
	consumers[f] = true
	f:SetAllPoints(parent)
	f.Markers, f.scene, f.enabled, f.status = {}, {}, true, "Questie pins not checked"
	function f:SetEnabled(enabled)
		self.enabled, self.lastScan = enabled and true or false, nil
		self:SetShown(self.enabled)
		if not self.enabled then hide(self) end
	end
	function f:GetEnabled() return self.enabled end
	function f:GetStatus() return self.status, self.available, self.truncated or self.displayTruncated end
	function f:Refresh(map)
		if not self.enabled or not self:IsVisible() then return end
		if not (map and map.art and map.View and map.bounds) then hide(self); return end
		requestSnapshot(self)
		local v, b, objectives = map.View, map.bounds, map.Objectives
		local sig = { v.width, v.height, v.offsetX, v.offsetY, v.drawWidth, v.drawHeight,
			b.c, b.left, b.top, b.kx, b.ky, self.scene,
			objectives and objectives.scene or false, objectives and objectives.enabled or false,
			objectives and objectives.showMarkers or false }
		if not same(self.paintSignature, sig) then paint(self, map); self.paintSignature = sig end
	end
	f:SetScript("OnHide", function(self)
		hide(self)
		if not visibleConsumer() then job = nil; worker:Hide() end
	end)
	return f
end
