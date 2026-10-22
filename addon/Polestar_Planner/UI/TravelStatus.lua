-- Informational fallback only. Stock Polestar owns navigation, flight timing
-- and transport detection; this companion never replaces or writes them.
local _, ns = ...
local Status = {}
ns.TravelStatus = Status
ns.RegisterDefaults("travelStatus", { enabled = true })

local INTERVAL, BOARD_WINDOW = 0.2, 10
local driver = CreateFrame("Frame")
driver:Hide()
local pendingUntil, gossip, flight, boat, blockedRoute
local elapsed = 0

local function number(value)
	if ns.Compat.IsSecret and ns.Compat.IsSecret(value) then return nil end
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then return value end
end
local function clock() return GetTime() end
local function duration(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
local function visible(kind)
	if ns.Adapter.TravelUIShown(kind) then return false end
	if kind == "flight" then return ns.Adapter.CoreSetting("maps.flightTimer") ~= false end
	return ns.Adapter.CoreSetting("nav.alerts") ~= false and ns.Adapter.CoreSetting("nav.alertBanner") ~= false
end
local function hide()
	if Status.frame then Status.frame:Hide() end
end
local function show(title, detail)
	local f = Status.frame
	if not f then
		f = CreateFrame("Frame", "PolestarPlannerTravelStatus", UIParent)
		Status.frame = f
		f:SetSize(340, 52)
		f:SetPoint("TOP", UIParent, "TOP", 0, -140)
		f:SetFrameStrata("MEDIUM")
		ns.Widgets.Fill(f, "panel")
		f.Title = ns.Widgets.Text(f, "body", "text")
		f.Title:SetPoint("TOPLEFT", 12, -9); f.Title:SetWidth(316)
		f.Detail = ns.Widgets.Text(f, "small", "textDim")
		f.Detail:SetPoint("TOPLEFT", 12, -29); f.Detail:SetWidth(316)
	end
	if f.Title:GetText() ~= title then f.Title:SetText(title) end
	if f.Detail:GetText() ~= detail then f.Detail:SetText(detail) end
	f:Show()
end

local function update()
	if not ns.Get("travelStatus.enabled") then
		pendingUntil, gossip, flight, boat, blockedRoute = nil, nil, nil, nil, nil
		hide(); driver:Hide(); return
	end
	local now = clock()
	local onTaxi = ns.Compat.IsOnTaxi and ns.Compat.IsOnTaxi()
	if onTaxi then
		if not flight then
			local named = gossip and now - gossip.at <= BOARD_WINDOW
			flight = { started = now, destination = named and "Rut'theran Village" or nil }
			gossip, pendingUntil = nil, nil
		end
		if visible("flight") then
			show(flight.destination and ("Flight to " .. flight.destination) or "In flight",
				"Elapsed " .. duration(now - flight.started))
		else hide() end
		return
	end
	flight = nil
	if pendingUntil and now >= pendingUntil then pendingUntil, gossip = nil, nil end

	local ride = ns.Transit.Riding and ns.Transit.Riding()
	if type(ride) ~= "table" then ride = nil end
	if ride and ns.Compat.IsSecret and (ns.Compat.IsSecret(ride.kind) or ns.Compat.IsSecret(ride.dock)
		or ns.Compat.IsSecret(ride.route)) then ride = nil end
	local remaining = ride and number(ride.arriveIn)
	local kind = ride and ride.kind
	local supported = kind == "boat" or kind == "zeppelin" or kind == "tram"
	if supported and remaining and remaining > 0 and type(ride.dock) == "string" and ride.route then
		-- Riding() selects the next stop on a loop. Once this stop is reached,
		-- don't label its return trip as underway while the player is docked.
		if boat and (boat.route ~= ride.route or boat.dock ~= ride.dock or now >= boat.untilTime) then
			if boat.route == ride.route then blockedRoute = ride.route end
			boat = nil
		end
		if blockedRoute ~= ride.route and not boat then
			boat = { route = ride.route, dock = ride.dock, untilTime = now + remaining }
		end
		if boat and visible("boat") then
			local label = kind == "boat" and "Boat" or (kind == "zeppelin" and "Zeppelin" or "Tram")
			show(label .. " to " .. ride.dock, "Arrives in " .. duration(remaining))
		else hide() end
	else
		boat, blockedRoute = nil, nil
		hide()
		if not pendingUntil then driver:Hide() end
	end
end
local function wake()
	if not ns.Get("travelStatus.enabled") then hide(); driver:Hide(); return end
	driver:Show(); update()
end
driver:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed < INTERVAL then return end
	elapsed = 0
	update()
end)
Status.driver = driver

ns.RegisterEvent("GOSSIP_SHOW", function()
	local info = ns.Compat.GetPlayerInfo and ns.Compat.GetPlayerInfo()
	local npc = ns.Compat.GetNpcID and ns.Compat.GetNpcID("npc")
	-- Silva's free Druid flight is distinct from Sindrayl's normal taxi node.
	gossip = npc == 11800 and info and info.class == "DRUID" and info.faction == "Alliance"
		and { at = clock() } or nil
end)
ns.RegisterEvent("GOSSIP_CLOSED", function()
	if gossip then gossip.at = clock() end
end)
ns.RegisterEvent("PLAYER_CONTROL_LOST", function()
	-- The client's taxi flag can lag this event. Bound the wait instead of
	-- permanently polling or assuming all control loss is a flight.
	pendingUntil = clock() + BOARD_WINDOW
	wake()
end)
ns.RegisterEvent("PLAYER_CONTROL_GAINED", wake)
ns.RegisterEvent("PLAYER_ENTERING_WORLD", wake)
ns.RegisterEvent("ZONE_CHANGED_NEW_AREA", wake)
ns.On("NAV_TRANSIT", wake)
ns.On("SETTING_CHANGED", function(path)
	if path == "travelStatus.enabled" then wake() end
end)
ns.OnLogin(wake)
