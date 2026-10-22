'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');
const native = require('./fixtures/openmap/native-maps.json');

function lua(value) {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return `{${Object.entries(value).map(([k, v]) => `[${Array.isArray(value) ? +k + 1 : /^\d+$/.test(k) ? +k : JSON.stringify(k)}]=${lua(v)}`).join(',')}}`;
}

function run(script, { before = '', setup = '' } = {}) {
  return runAddon({
    stubs: ['live-openmap.lua'],
    before: `openmapstub.install(${lua(native)}); ${before}`,
    addons: [{ name: 'Polestar', files: ['Core/Init.lua', 'OpenMap/OpenMap.xml', 'UI/LiveOpenMap.lua'] }],
    script: `
      local F, OM = openmapstub, PolestarPlanner.LiveOpenMap
      Polestar.Compat={IsSecret=function(v) return v==F.secret end}
      local function parent(w,h) local p=CreateFrame('Frame',nil,UIParent); p:SetSize(w,h); return p end
      ${setup}
      ${script}
    `,
  }).emitted;
}

test('panning reuses map layout and zoom styling without blurred terrain copies',()=>{
  const [out]=run(`
    local r=OM.Create(parent(600,400));local b=F.bounds(1429)
    assert(r:Paint(1429,F.view(1429,600,400,3,70,60),b))
    local S=r.S;local layout,zoom=S.Layout,S.SetZoom;local layouts,zooms=0,0
    S.Layout=function(...) layouts=layouts+1;return layout(...) end
    S.SetZoom=function(...) zooms=zooms+1;return zoom(...) end
    assert(r:Paint(1429,F.view(1429,600,400,3,71,60),b))
    assert(r:Paint(1429,F.view(1429,600,400,3,72,60),b))
    local panZooms=zooms
    assert(r:Paint(1429,F.view(1429,600,400,4,72,60),b))
    emit({layouts=layouts,panZooms=panZooms,zoomChanges=zooms,soften=r.ctx.GetModule().db.soften})
  `);
  assert.deepEqual(out,{layouts:0,panZooms:0,zoomChanges:1,soften:false});
});

test('the actual OpenMap renderer draws native detail with its original named map artwork', () => {
  const [out] = run(`
    local p=parent(600,400); local r=OM.Create(p)
    local ok=r:Paint(1429,F.view(1429,600,400,3,70,60),F.bounds(1429))
    stub.advance(0.5)
    local terrain,originalArt=0,0
    local terrainFiles,artFiles={},{}
    for _,tiles in pairs(r.ctx.MapMinimap) do for _,fid in pairs(tiles) do terrainFiles[fid]=true end end
    for _,m in pairs(F.maps) do for _,fid in ipairs(m.textures) do artFiles[fid]=true end end
    for _,pieces in pairs(r.ctx.MapReveal) do for _,files in pairs(pieces) do
      for fid in files:gmatch('%d+') do artFiles[tonumber(fid)]=true end
    end end
    for _,t in ipairs(F.textures(p,true)) do
      local file=t:GetTexture()
      if terrainFiles[file] then terrain=terrain+1 end
      if artFiles[file] or type(file)=='string' and file:find('MapZones',1,true) then originalArt=originalArt+1 end
    end
    emit({ok=ok,diagnostics=r:Diagnostics(),terrain=terrain,art=originalArt,
      detail=r.ctx:GetModule('worldmap').db.minimap,mix=r.S.closeView and r.S.closeView.mix,
      globals=OpenMap~=nil or OpenMapAPI~=nil or OpenMapDB~=nil})
  `);
  assert.equal(out.ok, true, out.diagnostics.error);
  assert.equal(out.diagnostics.available, true);
  assert.match(out.diagnostics.backend, /OpenMap.*detail/);
  assert.equal(out.detail, true);
  assert.ok(out.mix > 0, 'the original Minimap detail layer must be enabled');
  assert.ok(out.terrain > 0, 'native minimap FileDataIDs must draw');
  assert.ok(out.art > 0, 'OpenMap original zone artwork retains its original lettering');
  assert.equal(out.globals, false);
});

test('full and compact views have independent renderer closures and cameras', () => {
  const [out] = run(`
    local full=OM.Create(parent(1000,700)); local mini=OM.Create(parent(420,354))
    local a=full:Paint(1429,F.view(1429,1000,700,2,50,50),F.bounds(1429))
    local b=mini:Paint(1450,F.view(1450,420,354,4,40,50),F.bounds(1450))
    local fullScale=full.canvas:GetScale()
    local fullUpdates=full.S.closeView.updates
    mini:Paint(1439,F.view(1439,420,354,5,35,40),F.bounds(1439))
    emit({a=a,b=b,full=full:Diagnostics(),mini=mini:Diagnostics(),
      separate=full.S~=mini.S and full.ctx~=mini.ctx and full.canvas~=mini.canvas,
      fullScale=fullScale,afterScale=full.canvas:GetScale(),fullUpdates=fullUpdates,afterUpdates=full.S.closeView.updates})
  `);
  assert.equal(out.a, true, out.full.error);
  assert.equal(out.b, true, out.mini.error);
  assert.equal(out.separate, true);
  assert.equal(out.full.map, 1429);
  assert.equal(out.mini.map, 1439);
  assert.equal(out.fullScale, out.afterScale);
  assert.equal(out.fullUpdates, out.afterUpdates);
});

test('missing optional OpenMap API falls back before querying illustrated art', () => {
  const [out] = run(`
    local r=OM.Create(parent(420,354)); local ok=r:Paint(1429,F.view(1429,420,354),F.bounds(1429))
    emit({ok=ok,art=F.reads.art or 0,canvas=r.canvas~=nil,diagnostics=r:Diagnostics()})
  `, { before: 'C_Map.GetMapRectOnMap=nil' });
  assert.equal(out.ok, false);
  assert.equal(out.art, 0);
  assert.equal(out.canvas, false);
  assert.equal(out.diagnostics.available, false);
  assert.match(out.diagnostics.error, /unavailable/);
});

test('actual stitched world points coincide with navigation pixels on both axes at deep zoom', () => {
  const [out] = run(`
    local results={}
    for _,id in ipairs({1429,1450,1453,1439}) do
      local p=parent(420,354); local r=OM.Create(p)
      local v=F.view(id,420,354,48,62,34); local bounds=F.bounds(id)
      local ok=r:Paint(id,v,bounds)
      local points={}
      for _,xy in ipairs({{0,0},{100,100},{62,34},{29.4,87.2}}) do
        local c,w=C_Map.GetWorldPosFromMapPos(id,CreateVector2D(xy[1]/100,xy[2]/100))
        local u,vv=r.S.FromYards(c,w.x,w.y)
        local root=r.canvas.children[1]
        local marker=root:CreateTexture(nil,'OVERLAY')
        r.S.PlaceWorld(marker,u,vv,u+0.00001,vv+0.00001)
        local sx,sy=F.pixel(marker)
        points[#points+1]={x=sx,y=sy,expectedX=v.offsetX+xy[1]/100*v.drawWidth,
          expectedY=v.offsetY+xy[2]/100*v.drawHeight}
        r.S.UnplaceWorld(marker)
      end
      results[#results+1]={id=id,ok=ok,diagnostics=r:Diagnostics(),points=points}
      r:Hide()
    end
    emit(results)
  `);
  for (const result of out) {
    assert.equal(result.ok, true, `${result.id}: ${result.diagnostics.error}`);
    for (const point of result.points) {
      assert.ok(Math.abs(point.x - point.expectedX) < 0.001, `${result.id}: X drift ${point.x - point.expectedX}`);
      assert.ok(Math.abs(point.y - point.expectedY) < 0.001, `${result.id}: Y drift ${point.y - point.expectedY}`);
    }
  }
});

test('hiding both renderers stops queued texture loads and unparented lettering watchers', () => {
  const [out] = run(`
    local full=OM.Create(parent(1000,700)); local mini=OM.Create(parent(420,354))
    full:Paint(1429,F.view(1429,1000,700,3),F.bounds(1429))
    mini:Paint(1450,F.view(1450,420,354,4),F.bounds(1450))
    -- Consecutive moves activate OpenMap's standalone lettering watcher.
    for i=1,6 do
      stub.now=stub.now+0.02
      mini:Paint(1450,F.view(1450,420,354,4,40+i,50),F.bounds(1450))
    end
    local running=F.activeUpdates()
    full:Hide(); mini:Hide(); F.clearReads()
    local updates=F.activeUpdates(); stub.advance(2)
    local reads=0;for _,n in pairs(F.reads) do reads=reads+n end
    emit({running=running,updates=updates,after=F.activeUpdates(),reads=reads,writes=F.textureWrites,
      full=full.canvas:IsShown(),mini=mini.canvas:IsShown()})
  `);
  assert.ok(out.running > 0, 'test must first schedule real upstream background jobs');
  assert.deepEqual({ ...out, running: undefined }, { running: undefined, updates: 0, after: 0, reads: 0, writes: 0, full: false, mini: false });
});

test('opening during a loading screen recovers without poisoning cached map rectangles', () => {
  const [out] = run(`
    local r=OM.Create(parent(420,354)); local v=F.view(1450,420,354,4)
    F.loading=true
    local loading=r:Paint(1450,v,F.bounds(1450))
    local created=r.S~=nil
    F.loading=false
    local recovered=r:Paint(1450,v,F.bounds(1450))
    emit({loading=loading,created=created,recovered=recovered,diagnostics=r:Diagnostics()})
  `);
  assert.equal(out.loading, false);
  assert.equal(out.created, false);
  assert.equal(out.recovered, true, out.diagnostics.error);
  assert.equal(out.diagnostics.available, true);
});

test('secret and nonfinite camera values cause a safe fallback without map API work', () => {
  const [out] = run(`
    local results={}
    for _,value in ipairs({F.secret,0/0,math.huge,-math.huge}) do
      local r=OM.Create(parent(420,354)); local v=F.view(1429,420,354)
      v.width=value;F.clearReads()
      local ok=r:Paint(1429,v,F.bounds(1429));local reads=0
      for _,n in pairs(F.reads) do reads=reads+n end
      results[#results+1]={ok=ok,reads=reads,created=r.S~=nil,available=r:Diagnostics().available}
    end
    emit(results)
  `);
  for (const result of out) assert.deepEqual(result, { ok: false, reads: 0, created: false, available: false });
});

test('new texture files unavailable until restart preserve fallback and recover when available', () => {
  const [out] = run(`
    local r=OM.Create(parent(420,354)); local v=F.view(1429,420,354,3)
    F.failTextures=true
    local missing=r:Paint(1429,v,F.bounds(1429));local reason=r:Diagnostics().error
    local hidden=r.canvas and not r.canvas:IsShown()
    F.failTextures=false
    local recovered=r:Paint(1429,v,F.bounds(1429))
    emit({missing=missing,reason=reason,hidden=hidden,recovered=recovered,diagnostics=r:Diagnostics()})
  `);
  assert.equal(out.missing, false);
  assert.match(out.reason, /restart/);
  assert.equal(out.hidden, true);
  assert.equal(out.recovered, true, out.diagnostics.error);
});

test('the complete full and compact LiveMap frames use actual OpenMap art under aligned route and quest layers', () => {
  const [out] = runAddon({
    stubs: ['stub_ui.lua', 'live-dashboard.lua', 'live-openmap.lua'],
    addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'Theme/Theme.xml', 'Maps/RouteStrokes.lua', 'UI/UI.xml'] }],
    script: `
      local F=openmapstub
      local terrain=PolestarPlanner.LiveTerrain
      uistub.install(); livestub.install(); PolestarPlanner.LiveTerrain=terrain
      F.install(${lua(native)})
      local C=Polestar.Compat
      C.IsSecret=function(v) return v==F.secret end
      C.MapToWorld=function(id,x,y)
        local c,p=C_Map.GetWorldPosFromMapPos(id,CreateVector2D(x/100,y/100))
        return c,p and p.x,p and p.y
      end
      C.WorldToMap=function(c,wx,wy,id)
        local b=F.maps[id] and F.bounds(id)
        if not b or b.c~=c then return nil end
        return (wy-b.left)*b.kx*100,(wx-b.top)*b.ky*100
      end
      C.GetPlayerMapPosition=function() local p=livestub.player;return p.map,p.x,p.y end
      C.GetPlayerWorldPosition=function() local p=livestub.player;return C.MapToWorld(p.map,p.x,p.y) end
      C.GetMapName=function(id) return F.maps[id] and F.maps[id].info.name end
      local function world(x,y) local c,wx,wy=C.MapToWorld(1429,x,y);return {c,wx,wy} end
      livestub.geometry={legs={{kind='walk',current=true,pts={world(44,39),world(45,39),world(46,40)}}}}
      stub.login();uistub.setGuide(uistub.elwynn,3)
      uistub.target={map=1429,x=46,y=40,kind='manual',label='Test destination'}
      PolestarPlanner.LiveDashboard.Show();PolestarPlanner.LiveMiniMap.Show()
      local full=PolestarPlanner.LiveDashboard.GetFrame().Map
      local mini=PolestarPlanner.LiveMiniMap.GetFrame().Map
      full.Viewport:SetSize(900,680);mini.Viewport:SetSize(420,354)
      full:ApplyViewState({mapID=1429,zoom=3,focusX=46,focusY=40,follow=false})
      mini:ApplyViewState({mapID=1429,zoom=8,focusX=46,focusY=40,follow=false})
      full:Refresh(true);mini:Refresh(true);stub.advance(0.5)
      local function capture(m)
        local v=m.View
        local sx,sy=PolestarPlanner.LiveMap.Project(v,46,40)
        local _,_,_,mx,my=m.GoalMarker:GetPoint(1)
        local c,wx,wy=C.MapToWorld(1429,46,40)
        local u,vv=m.OpenMap.S.FromYards(c,wx,wy)
        local root=m.OpenMap.canvas.children[1]
        local probe=root:CreateTexture(nil,'OVERLAY')
        m.OpenMap.S.PlaceWorld(probe,u,vv,u+0.00001,vv+0.00001)
        local ax,ay=F.pixel(probe)
        m.OpenMap.S.UnplaceWorld(probe)
        local ox,oy=F.pixel(m.Canvas)
        return {open=m.usingOpenMap,diagnostics=m.OpenMap:Diagnostics(),marker=m.GoalMarker:IsShown(),
          sx=sx,sy=sy,mx=mx,my=-my,ax=ax-ox,ay=ay-oy,routeCount=#m.Lines,
          artLevel=m.Canvas:GetFrameLevel()+35,routeLevel=m.RouteLayer:GetFrameLevel(),
          markerLevel=m.GoalMarker:GetFrameLevel()}
      end
      local a,b=capture(full),capture(mini)
      mini:Hide();local miniHidden=not mini.OpenMap.canvas:IsVisible()
      full:Refresh(true)
      emit({full=a,mini=b,independent=full.OpenMap.S~=mini.OpenMap.S,
        miniHidden=miniHidden,fullStillVisible=full.OpenMap.canvas:IsVisible()})
    `,
  }).emitted;
  assert.equal(out.independent, true);
  assert.equal(out.miniHidden, true);
  assert.equal(out.fullStillVisible, true);
  for (const state of [out.full, out.mini]) {
    assert.equal(state.open, true, state.diagnostics.error);
    assert.equal(state.marker, true);
    assert.ok(state.routeCount > 0, 'real navigation route strokes remain present');
    assert.ok(Math.abs(state.sx - state.mx) < 0.001);
    assert.ok(Math.abs(state.sy - state.my) < 0.001);
    assert.ok(Math.abs(state.sx - state.ax) < 0.001, `X overlay mismatch ${state.sx-state.ax}`);
    assert.ok(Math.abs(state.sy - state.ay) < 0.001, `Y overlay mismatch ${state.sy-state.ay}`);
    assert.ok(state.routeLevel > state.artLevel);
    assert.ok(state.markerLevel > state.artLevel);
  }
});

test('a stationary LiveMap retries temporary OpenMap failures at most once per second', () => {
  const [out] = runAddon({
    stubs: ['stub_ui.lua', 'live-dashboard.lua', 'live-openmap.lua'],
    addons: [{name:'Polestar',files:['Core/Core.xml','Theme/Theme.xml','Maps/RouteStrokes.lua','UI/UI.xml']}],
    script: `
      local terrain=PolestarPlanner.LiveTerrain
      uistub.install();livestub.install();PolestarPlanner.LiveTerrain=terrain
      openmapstub.install(${lua(native)})
      stub.login();uistub.setGuide(uistub.elwynn,3)
      PolestarPlanner.LiveMiniMap.Show()
      local m=PolestarPlanner.LiveMiniMap.GetFrame().Map
      m.Viewport:SetSize(420,354)
      m:ApplyViewState({mapID=1429,zoom=3,focusX=44,focusY=39,follow=false,autoZoom=false})
      m:Refresh(true)
      local paint=m.OpenMap.Paint;local attempts=0
      m.OpenMap.Paint=function(self,...) attempts=attempts+1;return paint(self,...) end
      openmapstub.loading=true;m:Refresh(true)
      local unavailable=not m.usingOpenMap;local before=attempts
      m.dirty=false
      stub.advance(0.5)
      local early=attempts
      openmapstub.loading=false
      stub.advance(1)
      local recovered=m.usingOpenMap
      local final=attempts
      emit({unavailable=unavailable,before=before,early=early,final=final,recovered=recovered,
        map=m.mapID,focusX=m.focusX,focusY=m.focusY})
    `,
  }).emitted;
  assert.equal(out.unavailable,true);
  assert.equal(out.early,out.before,'fallback retries must not poll every frame');
  assert.equal(out.final,out.before+1);
  assert.equal(out.recovered,true,'the host should recover without Player/reopen/camera movement');
  assert.equal(out.map,1429);
  assert.equal(out.focusX,44);
  assert.equal(out.focusY,39);
});

test('public export keeps usable compact terrain and route layers without separately installed OpenMap artwork',()=>{
 const [out]=runAddon({
  stubs:['stub_ui.lua','live-dashboard.lua','live-openmap.lua'],
  addons:[{name:'Polestar',files:['Core/Core.xml','Theme/Theme.xml','Maps/RouteStrokes.lua','UI/UI.xml']}],
  script:`
   local terrain=PolestarPlanner.LiveTerrain
   uistub.install();livestub.install();PolestarPlanner.LiveTerrain=terrain
   openmapstub.install(${lua(native)})
   local original=stub.Methods.SetTexture
   stub.Methods.SetTexture=function(self,value,...)
    if type(value)=='string' and value:find('AddOns\\\\OpenMap\\\\Media',1,true) then return false end
    return original(self,value,...)
   end
   stub.login();uistub.setGuide(uistub.elwynn,3)
   PolestarPlanner.LiveMiniMap.Show()
   local m=PolestarPlanner.LiveMiniMap.GetFrame().Map
   m.Viewport:SetSize(420,354)
   m:ApplyViewState({mapID=1429,zoom=3,focusX=44,focusY=39,follow=false,autoZoom=false})
   m:Refresh(true)
   emit({open=m.usingOpenMap,tiles=m.tileCount,missing=m.missingTiles,empty=m.Empty:IsShown(),
    marker=m.PlayerMarker:IsShown(),paths=#m.paths,diagnostics=m.OpenMap:Diagnostics()})
  `
 }).emitted;
 assert.equal(out.open,false);
 assert.ok(out.tiles>0);assert.equal(out.missing,0);assert.equal(out.empty,false);
 assert.equal(out.marker,true);assert.ok(out.paths>0);
 assert.match(out.diagnostics.error,/Install OpenMap/);
});
