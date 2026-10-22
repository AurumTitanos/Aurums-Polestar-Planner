-- Bounded, local quest-dialogue diagnostics. Secure post-hooks observe selections;
-- they never select, accept, decline, close or rewrite another addon's functions.
local _, ns = ...
local Dialog = {}
ns.QuestDialog = Dialog
ns.RegisterDefaults("questDialog", { trace = true, announceAccept = true })
local records, hooks, announced = {}, {}, {}
local LIMIT = 24
local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, value = pcall(fn, ...)
	if ok and not (ns.Compat.IsSecret and ns.Compat.IsSecret(value)) then return value end
end
local function id(value) return type(value) == "number" and value > 0 and value or nil end
local function now() return call(GetTime) or 0 end
local function caller()
	local stack = call(debugstack, 3, 16, 0)
	if type(stack) ~= "string" then return "Caller unavailable" end
	for line in stack:gmatch("[^\r\n]+") do
		local normalized = line:gsub("\\", "/")
		if normalized:find("AddOns/", 1, true) and not normalized:find("Polestar_Planner/UI/QuestDialog.lua", 1, true) then
			return normalized:sub(1, 240)
		end
	end
	return "Client/C code or caller unavailable"
end
local function record(kind, quest, extra)
	if not ns.Get("questDialog.trace") then return end
	records[#records + 1] = { at = now(), kind = kind, quest = id(quest),
		npc = call(ns.Compat.GetNpcID, "npc") or call(ns.Compat.GetNpcID, "questnpc"), extra = extra }
	if #records > LIMIT then table.remove(records, 1) end
end
local function installHooks()
	if type(hooksecurefunc) ~= "function" then return end
	if not hooks.greeting and type(SelectAvailableQuest) == "function" then
		hooks.greeting = pcall(hooksecurefunc, "SelectAvailableQuest", function(index)
			if ns.Get("questDialog.trace") then
				record("SelectAvailableQuest", call(GetQuestID), "index " .. tostring(index) .. "; " .. caller())
			end
		end)
	end
	local G = C_GossipInfo
	if type(G) == "table" and not hooks[G] and type(G.SelectAvailableQuest) == "function" then
		hooks[G] = pcall(hooksecurefunc, G, "SelectAvailableQuest", function(quest)
			if ns.Get("questDialog.trace") then record("GossipSelectAvailableQuest", quest, caller()) end
		end)
	end
end
ns.RegisterEvent("QUEST_DETAIL", function()
	record("QUEST_DETAIL", call(GetQuestID))
end)
ns.RegisterEvent("QUEST_ACCEPTED", function(_, first, second)
	local quest = id(second) or id(first)
	if not quest then return end
	record("QUEST_ACCEPTED", quest)
	-- The event plus log membership confirm success; a selection attempt does not.
	if not ns.Get("questDialog.announceAccept") or not call(ns.Compat.IsOnQuest, quest)
		or not call(ns.Engine.WantsQuest, "accept", quest) then return end
	local at = now()
	if announced[quest] == at then return end
	announced = { [quest] = at }
	local title = call(ns.Compat.GetQuestTitle, quest)
	ns.Print("Guide quest accepted: " .. (type(title) == "string" and title ~= "" and title or ("#" .. quest)))
end)
ns.RegisterEvent("GOSSIP_SHOW", installHooks)
ns.OnLogin(installHooks)
installHooks()
function Dialog.GetTrace() return records end
ns.RegisterCommand("questtrace", function(action)
	action = (action or ""):lower()
	if action == "off" or action == "on" then
		ns.Set("questDialog.trace", action == "on")
		ns.Print("Quest selection trace " .. action .. ".")
		return
	elseif action == "clear" then records = {}; ns.Print("Quest selection trace cleared."); return end
	ns.Print("Quest selection trace (local only; " .. #records .. "/" .. LIMIT .. " records):")
	for _, entry in ipairs(records) do
		ns.Print(string.format("%.2f %s quest=%s npc=%s%s", entry.at, entry.kind,
			tostring(entry.quest or "?"), tostring(entry.npc or "?"), entry.extra and ("; " .. entry.extra) or ""))
	end
end, "Show the last quest-selection calls and their callers")
