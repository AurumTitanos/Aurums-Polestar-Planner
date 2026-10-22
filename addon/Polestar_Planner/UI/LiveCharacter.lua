-- Read-only character details for the live dashboard. Quest/inventory scans
-- are lazy and event-invalidated; this module has no timer or OnUpdate.
-- Unknown API data remains unknown, rather than looking like an empty log.
local ADDON, ns = ...
local LC = {}
ns.LiveCharacter = LC

local questDirty, itemDirty = true, true
local cachedQuests, cachedItems = {}, {}
local questCount, questMax, questAvailable, itemsAvailable

local function clean(v)
	local fn = ns.Compat and ns.Compat.IsSecret or issecretvalue
	if type(fn) == "function" then
		local ok, secret = pcall(fn, v)
		if not ok or secret then return nil, false end
	end
	return v, true
end

local function number(v)
	v = clean(v)
	if type(v) == "number" and v == v and v >= 0 and v < math.huge then return v end
end

local function stringValue(v)
	v = clean(v)
	if type(v) == "string" and v ~= "" then return v end
end

local function boolean(v)
	v = clean(v)
	if type(v) == "boolean" then return v end
end

local function call(fn, ...)
	if type(fn) ~= "function" then return false end
	local ok, a, b, c, d, e, f = pcall(fn, ...)
	if not ok then return false end
	local ra, rb, rc, rd, re, rf
	a, ra = clean(a); b, rb = clean(b); c, rc = clean(c)
	d, rd = clean(d); e, re = clean(e); f, rf = clean(f)
	if not (ra and rb and rc and rd and re and rf) then return false end
	return true, a, b, c, d, e, f
end

local function objectives(Q, id)
	local ok, raw = call(Q and Q.GetQuestObjectives, id)
	if not ok or type(raw) ~= "table" then return nil end
	local out = {}
	for _, entry in ipairs(raw) do
		entry = clean(entry)
		if type(entry) == "table" then
			out[#out + 1] = { text = stringValue(entry.text), cur = number(entry.numFulfilled),
				max = number(entry.numRequired), finished = boolean(entry.finished) }
		end
	end
	return out
end

local function refreshQuests()
	questDirty = false
	cachedQuests, questCount, questMax, questAvailable = {}, nil, nil, false
	local Q = C_QuestLog
	local maxFn = Q and (Q.GetMaxNumQuestsCanAccept or Q.GetMaxNumQuests)
	local _, limit = call(maxFn)
	questMax = number(limit) or number(MAX_QUESTLOG_QUESTS)
	local ok, entries, count = call(Q and Q.GetNumQuestLogEntries or GetNumQuestLogEntries)
	entries, count = number(entries), number(count)
	if not ok or not entries or entries > 1000 or entries % 1 ~= 0 or not (Q and type(Q.GetInfo) == "function") then return end
	questAvailable = true
	for index = 1, entries do
		local success, info = call(Q.GetInfo, index)
		if not success or type(info) ~= "table" then
			questAvailable = false
		else
			local header, id = boolean(info.isHeader), number(info.questID)
			if header == false and id and id > 0 then
				local title = stringValue(info.title)
				if not title then local _, value = call(Q.GetTitleForQuestID, id); title = stringValue(value) end
				local readyOK, ready = call(Q.ReadyForTurnIn or Q.IsComplete, id)
				cachedQuests[#cachedQuests + 1] = { id = id, title = title,
					ready = boolean(ready), objectives = objectives(Q, id) }
			elseif header ~= true then questAvailable = false end
		end
	end
	questCount = count or (questAvailable and #cachedQuests or nil)
end

local function refreshItems()
	itemDirty = false
	cachedItems, itemsAvailable = {}, false
	local B, I = C_Container, C_Item
	local slotsFn, itemFn = B and B.GetContainerNumSlots, B and B.GetContainerItemInfo
	local classFn = I and I.GetItemInfoInstant or GetItemInfoInstant
	if not (type(slotsFn) == "function" and type(itemFn) == "function" and type(classFn) == "function") then return end
	local bags = number(NUM_BAG_SLOTS) or 4
	if bags > 20 or bags % 1 ~= 0 then return end
	itemsAvailable = true
	local byID = {}
	for bag = 0, bags do
		local ok, slots = call(slotsFn, bag)
		slots = number(slots)
		if not ok or not slots or slots > 1000 or slots % 1 ~= 0 then
			itemsAvailable = false
		else
			for slot = 1, slots do
				local readOK, item = call(itemFn, bag, slot)
				if not readOK then itemsAvailable = false
				elseif type(item) == "table" then
					local id, count = number(item.itemID), number(item.stackCount)
					if not id or id <= 0 or not count then itemsAvailable = false
					else
						local classOK, _, _, _, _, _, classID = call(classFn, id)
						classID = number(classID)
						if not classOK or not classID then itemsAvailable = false
						elseif classID == 12 then -- Enum.ItemClass.Questitem
							local existing = byID[id]
							if existing then existing.count = existing.count + count
							else
								local _, name = call(I and I.GetItemNameByID, id)
								name = stringValue(name)
								if not name then local _, value = call(I and I.GetItemInfo or GetItemInfo, id); name = stringValue(value) end
								existing = { id = id, name = name, count = count }
								byID[id] = existing
								cachedItems[#cachedItems + 1] = existing
							end
						end
					end
				end
			end
		end
	end
	table.sort(cachedItems, function(a, b) return a.id < b.id end)
end

local function hearth()
	local out = {}
	local ok, h = call(ns.QoL and ns.QoL.GetHearth)
	if ok and type(h) == "table" then
		out.have, out.ready = boolean(h.have), boolean(h.ready)
		out.remaining, out.bind = number(h.remaining), stringValue(h.bind)
	end
	if not out.bind then local _, bind = call(GetBindLocation); out.bind = stringValue(bind) end
	return out
end

local function travel()
	local taxiOK, taxi = call(UnitOnTaxi, "player")
	local flyingOK, flying = call(IsFlying)
	local mountedOK, mounted = call(IsMounted)
	local swimmingOK, swimming = call(IsSwimming)
	taxi, flying, mounted, swimming = boolean(taxi), boolean(flying), boolean(mounted), boolean(swimming)
	if taxi == true or flying == true then return "Flying" end
	if mounted == true then return "Mounted" end
	if swimming == true then return "Swimming" end
	if taxiOK and flyingOK and mountedOK and swimmingOK and taxi == false and flying == false and mounted == false and swimming == false then return "On foot" end
	return "Unavailable"
end

function LC.GetSnapshot()
	if questDirty then refreshQuests() end
	if itemDirty then refreshItems() end
	return { quests = cachedQuests, questCount = questCount, questMax = questMax, questLogAvailable = questAvailable,
		hearth = hearth(), travel = travel(), items = cachedItems, itemsAvailable = itemsAvailable,
		flightPaths = nil } -- No reliable complete list is exposed away from a flight master.
end

local function invalidateQuests() questDirty = true end
local function invalidateItems() itemDirty = true end
local function invalidateAll() questDirty, itemDirty = true, true end
if type(ns.RegisterEvent) == "function" then
	for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN" }) do
		pcall(ns.RegisterEvent, event, invalidateQuests)
	end
	for _, event in ipairs({ "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT" }) do
		pcall(ns.RegisterEvent, event, invalidateItems)
	end
	pcall(ns.RegisterEvent, "PLAYER_ENTERING_WORLD", invalidateAll)
end
