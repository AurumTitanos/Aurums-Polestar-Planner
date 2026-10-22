-- Companion entry points; /polestar remains owned by the official addon.
local _, ns = ...
ns.Bindings = {
	Live = function() ns.LiveDashboard.Toggle() end,
	MiniMap = function() ns.LiveMiniMap.Toggle() end,
}
ns.RegisterCommand("live", ns.Bindings.Live, "Toggle the full Planner")
ns.RegisterCommand("map", ns.Bindings.MiniMap, "Toggle the small map")
ns.RegisterCommand("perf", function()
	local s = ns.LiveQuestie.GetPerformance()
	ns.Print(string.format("Questie map worker: %d scans, %d slices, worst %.2f ms; %s.",
		s.scans, s.slices, s.worstMs, s.pending and "refresh pending" or "idle"))
	if s.lastError then ns.Print("Last interrupted scan: " .. s.lastError) end
end, "Show companion pin refresh timing")
local function help()
	ns.Print("/polestarplanner — full Planner; /polestarplanner minimap or /psmap — small map")
end
SLASH_POLESTARPLANNER1 = "/polestarplanner"
SLASH_POLESTARPLANNER2 = "/psplanner"
SlashCmdList.POLESTARPLANNER = function(message)
	local command, rest = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
	command = command:lower()
	if command == "" then ns.SafeCall(ns.Bindings.Live); return end
	if command == "help" then help(); return end
	local found = ns.Commands[command]
	if found then ns.SafeCall(found.run, rest) else help() end
end
SLASH_POLESTARPLANNERMAP1 = "/psmap"
SlashCmdList.POLESTARPLANNERMAP = function() ns.SafeCall(ns.Bindings.MiniMap) end
BINDING_HEADER_POLESTARPLANNER = "Polestar Planner"
BINDING_NAME_POLESTARPLANNER_LIVE = "Toggle full Planner"
BINDING_NAME_POLESTARPLANNER_MINIMAP = "Toggle small map"
BINDING_NAME_POLESTAR_LIVE = "Toggle full Planner (legacy key)"
BINDING_NAME_POLESTAR_MINIMAP = "Toggle small map (legacy key)"
