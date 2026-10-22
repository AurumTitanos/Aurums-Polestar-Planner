-- Shared guide spawn-region geometry for world, minimap, and live Planner.
local ADDON, ns = ...
local Regions = {}
ns.FallbackRegions = Regions

-- Spawn regions: the places a goal's mobs or objects spawn (compiled
-- `spots`: centres with the radius that covers their spawns) grouped into
-- regions, each the convex hull of its spots' discs (REGION_PAD wider) as a
-- REGION_SIDES-gon around it. Spots whose discs come within REGION_LINK yards
-- of each other join, nearest first, while the region stays at most
-- REGION_MAX_SPAN across: where the player hunts, not one camp at a time, and
-- a long coast of spawns is a chain of regions, not one hull over the sea.
-- Every polygon side is tangent to the hull, so the polygon covers every
-- spawn. Built once per goal (the compiled guide never changes):
-- regions = { { c, wx, wy (its centre), hull = { wx1, wy1, ... }, n (spawns), alt (only
-- places the arrow does not pick by itself) }, ... }, nil without spots or a map frame.
-- A region narrower than REGION_SMALL yards is an 8-gon (a handful of pixels
-- on the world map), the others REGION_SIDES-gons.
local REGION_SIDES, REGION_SMALL = 16, 200
local REGION_LINK = 90
local REGION_MAX_SPAN = 700
local REGION_PAD = 10
local REGION_MIN_RADIUS = 15
local regionCache = setmetatable({}, { __mode = "k" })
local sides = {}
for _, k in ipairs({ 8, REGION_SIDES }) do
	local t = { n = k, cos = {}, sin = {}, det = math.sin(2 * math.pi / k) }
	for i = 1, k do
		local a = 2 * math.pi * (i - 1) / k
		t.cos[i], t.sin[i] = math.cos(a), math.sin(a)
	end
	sides[k] = t
end

-- The polygon whose sides touch the hull of the discs (members of cs, xs,
-- ys, rs listed in group, span yards across) from outside.
local function regionOf(group, span, cs, xs, ys, rs, spots)
	local t = sides[span < REGION_SMALL and 8 or REGION_SIDES]
	local K, cosK, sinK = t.n, t.cos, t.sin
	local h = {}
	for k = 1, K do
		local ux, uy, best = cosK[k], sinK[k], -math.huge
		for _, i in ipairs(group) do
			local v = xs[i] * ux + ys[i] * uy + rs[i]
			if v > best then best = v end
		end
		h[k] = best
	end
	-- Corner k: where side k meets side k + 1.
	local hull, sx, sy, m = {}, 0, 0, 0
	for k = 1, K do
		local j = k % K + 1
		local x = (h[k] * sinK[j] - h[j] * sinK[k]) / t.det
		local y = (h[j] * cosK[k] - h[k] * cosK[j]) / t.det
		if m == 0 or math.abs(x - hull[2 * m - 1]) > 0.5 or math.abs(y - hull[2 * m]) > 0.5 then
			m = m + 1
			hull[2 * m - 1], hull[2 * m] = x, y
			sx, sy = sx + x, sy + y
		end
	end
	local n, alt = 0, true
	for _, i in ipairs(group) do
		n = n + (tonumber(spots[i].n) or 0)
		if not spots[i].alt then alt = false end
	end
	return { c = cs[group[1]], wx = sx / m, wy = sy / m, hull = hull, n = n, alt = alt }
end

local function regionsOf(goal)
	local cached = regionCache[goal]
	if cached ~= nil then return cached or nil end
	local C = ns.Compat
	local spots = goal.spots
	if not (C and C.MapToWorld and type(spots) == "table" and goal.map) then return nil end
	local cs, xs, ys, rs = {}, {}, {}, {}
	local groupOf, members, span = {}, {}, {}
	for i, s in ipairs(spots) do
		local c, wx, wy = C.MapToWorld(goal.map, s.x, s.y, goal.f)
		if not c then return nil end -- not resolvable yet: try again later
		cs[i], xs[i], ys[i] = c, wx, wy
		rs[i] = math.max(tonumber(s.r) or 0, REGION_MIN_RADIUS) + REGION_PAD
		groupOf[i], members[i], span[i] = i, { i }, 2 * rs[i]
	end
	local function across(i, j)
		local dx, dy = xs[i] - xs[j], ys[i] - ys[j]
		return math.sqrt(dx * dx + dy * dy) + rs[i] + rs[j]
	end
	-- Pairs close enough to join, nearest (smallest gap between discs) first:
	-- a sweep along wx (no pair further apart than the widest reach), each
	-- pair one number (the gap in hundredths of a yard, then i, then j), so
	-- the sort compares plain numbers.
	local n, order, maxR = #spots, {}, 0
	for i = 1, n do
		order[i] = i
		if rs[i] > maxR then maxR = rs[i] end
	end
	table.sort(order, function(a, b)
		if xs[a] ~= xs[b] then return xs[a] < xs[b] end
		return a < b
	end)
	local reach, B, bias = 2 * maxR + REGION_LINK, n + 1, math.ceil(2 * maxR * 100) + 1
	local near = {}
	for a = 1, n do
		local i = order[a]
		for b = a + 1, n do
			local j = order[b]
			if xs[j] - xs[i] > reach then break end
			if cs[i] == cs[j] then
				local gap = across(i, j) - 2 * (rs[i] + rs[j])
				if gap <= REGION_LINK then
					local lo, hi = math.min(i, j), math.max(i, j)
					near[#near + 1] = (math.floor(gap * 100 + 0.5) + bias) * B * B + lo * B + hi
				end
			end
		end
	end
	table.sort(near)
	-- Groups found too wide together stay apart: groups only grow.
	local apart = {}
	local function keepApart(a, b)
		apart[a] = apart[a] or {}
		apart[b] = apart[b] or {}
		apart[a][b], apart[b][a] = true, true
	end
	for _, key in ipairs(near) do
		local a, b = groupOf[math.floor(key / B) % B], groupOf[key % B]
		if a ~= b and not (apart[a] and apart[a][b]) then
			local s = math.max(span[a], span[b])
			for _, i in ipairs(members[a]) do
				for _, j in ipairs(members[b]) do
					local d = across(i, j)
					if d > s then s = d end
				end
				if s > REGION_MAX_SPAN then break end
			end
			if s <= REGION_MAX_SPAN then
				if a > b then a, b = b, a end
				for _, j in ipairs(members[b]) do
					groupOf[j] = a
					table.insert(members[a], j)
				end
				members[b], span[a] = nil, s
				for c in pairs(apart[b] or {}) do keepApart(a, c) end
			else
				keepApart(a, b)
			end
		end
	end
	local regions = {}
	for i = 1, #spots do
		local group = members[i]
		if group then
			table.sort(group)
			regions[#regions + 1] = regionOf(group, span[i], cs, xs, ys, rs, spots)
		end
	end
	regionCache[goal] = regions
	return regions
end
Regions.ForGoal = regionsOf
