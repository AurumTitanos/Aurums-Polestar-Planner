-- Native C_Map contracts captured from the Forever client's DB2 exports.
-- This fixture deliberately executes the vendored OpenMap renderer, rather
-- than stubbing its drawing methods or substituting a different map renderer.
openmapstub = { reads = {}, textureWrites = 0, secret = {}, loading = false }
local F = openmapstub

function F.clearReads()
	F.reads = {}
	F.textureWrites = 0
end
local function read(name)
	F.reads[name] = (F.reads[name] or 0) + 1
end
function F.install(data)
	F.maps = data.maps
	-- The generic UI stub treats all unspecified frame levels as one. Native
	-- child frames inherit their parent's level plus one; map art and marker
	-- stacking regressions require that real contract here.
	stub.Methods.GetFrameLevel = function(self)
		if self.level then return self.level end
		return self.parent and self.parent:GetFrameLevel()+1 or 1
	end
	Enum.UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5 }
	issecretvalue = function(value) return value == F.secret end
	canaccessvalue = function(value) return value ~= F.secret end
	CreateVector2D = function(x, y)
		return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
	end
	local function entry(id) return F.maps[id] end
	C_Map = {}
	function C_Map.GetMapInfo(id)
		read("info")
		local m = entry(id)
		return m and m.info
	end
	function C_Map.GetMapRectOnMap(id, parent)
		read("rect")
		if F.loading then return nil end
		local m, p = entry(id), entry(parent)
		if not m or not p then return nil end
		local a, b = m.rect, p.rect
		return (a[1]-b[1])/(b[2]-b[1]), (a[2]-b[1])/(b[2]-b[1]),
			(a[3]-b[3])/(b[4]-b[3]), (a[4]-b[3])/(b[4]-b[3])
	end
	function C_Map.GetMapChildrenInfo(parent, kind, recursive)
		read("children")
		local out = {}
		for id, m in pairs(F.maps) do
			local p, seen = m.info.parentMapID, {}
			while p and p > 0 and not seen[p] do
				seen[p] = true
				if p == parent then
					if not kind or m.info.mapType == kind then out[#out+1] = m.info end
					break
				end
				if not recursive then break end
				p = entry(p) and entry(p).info.parentMapID
			end
		end
		table.sort(out, function(a,b) return a.mapID < b.mapID end)
		return out
	end
	function C_Map.GetMapInfoAtPosition(id, x, y)
		read("at")
		if F.loading or not entry(id) then return nil end
		local p = entry(id).rect
		local u, v = p[1] + x*(p[2]-p[1]), p[3] + y*(p[4]-p[3])
		local best
		for _, m in pairs(F.maps) do
			local r = m.rect
			if m.info.parentMapID == id and u >= r[1] and u <= r[2] and v >= r[3] and v <= r[4] then
				if not best or (r[2]-r[1])*(r[4]-r[3]) < (best.rect[2]-best.rect[1])*(best.rect[4]-best.rect[3]) then best=m end
			end
		end
		return best and best.info or entry(id).info
	end
	function C_Map.GetMapArtLayers(id)
		read("art")
		if F.loading then return nil end
		local m = entry(id)
		return m and { m.layer }
	end
	function C_Map.GetMapArtLayerTextures(id)
		read("textures")
		if F.loading then return nil end
		return entry(id) and entry(id).textures
	end
	function C_Map.GetMapArtID(id)
		read("artID")
		return entry(id) and entry(id).artID
	end
	function C_Map.GetWorldPosFromMapPos(id, point)
		read("world")
		if F.loading then return nil end
		local b = entry(id) and entry(id).bounds
		if not b then return nil end
		return b.c, CreateVector2D(b.top + point.y*(b.bottom-b.top), b.left + point.x*(b.right-b.left))
	end
	function C_Map.GetAreaInfo(id)
		return ({ [457] = "The Veiled Sea", [214] = "The Great Sea", [308] = "The Forbidding Sea" })[id]
	end
	C_MapExplorationInfo = { GetExploredMapTextures = function() read("exploration"); return {} end }
	GetPlayerFacing = function() return 0 end
	GetLocale = function() return "enUS" end
	UnitFactionGroup = function() return "Alliance" end
	GetCursorPosition = function() return 0, 0 end
	InCombatLockdown = function() return stub.inCombat end
	local originalSetTexture = stub.Methods.SetTexture
	stub.Methods.SetTexture = function(self, value, ...)
		F.textureWrites = F.textureWrites + 1
		if F.failTextures then self.texture=nil; return false end
		return originalSetTexture(self,value,...)
	end
end

function F.bounds(id) return F.maps[id].bounds end

-- One view definition is consumed by both Polestar overlays and OpenMap.
function F.view(id, width, height, zoom, focusX, focusY)
	local m, layer = F.maps[id], F.maps[947].layer
	local worldW, worldH = (m.rect[2]-m.rect[1])*layer.layerWidth, (m.rect[4]-m.rect[3])*layer.layerHeight
	local scale = math.min(width/worldW,height/worldH)*(zoom or 1)
	local dw, dh = worldW*scale, worldH*scale
	local ox, oy = width/2-(focusX or 50)/100*dw, height/2-(focusY or 50)/100*dh
	ox = dw <= width and (width-dw)/2 or math.min(0,math.max(width-dw,ox))
	oy = dh <= height and (height-dh)/2 or math.min(0,math.max(height-dh,oy))
	return {width=width,height=height,drawWidth=dw,drawHeight=dh,offsetX=ox,offsetY=oy,scale=scale}
end

-- Renderer geometry uses TOPLEFT anchors in each frame's scaled units.
function F.pixel(object)
	local point=object.points and object.points[1]
	if not point then return 0,0 end
	local relative=point.rel or object.parent
	local x,y=F.pixel(relative)
	local scale=object:GetEffectiveScale()
	return x+point.x*scale,y-point.y*scale
end

function F.walk(object, fn)
	fn(object)
	for _, region in ipairs(object.regions or {}) do F.walk(region,fn) end
	for _, child in ipairs(object.children or {}) do F.walk(child,fn) end
end
function F.textures(root, visibleOnly)
	local out={}
	F.walk(root,function(o)
		if o.kind == "Texture" and o:GetTexture() and (not visibleOnly or o:IsVisible()) then out[#out+1]=o end
	end)
	return out
end
function F.activeUpdates()
	local n=0
	for _,frame in ipairs(stub.frames) do
		if frame:IsVisible() and frame:GetScript("OnUpdate") then n=n+1 end
	end
	return n
end
