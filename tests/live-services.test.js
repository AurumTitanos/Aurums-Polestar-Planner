'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

// Verified Thor facts and deliberately simple client geometry. Taxi data is
// slightly displaced to prove the known NPC spawn wins over its fallback.
const fixture = `
uistub.install(); stub.login()
QuestieLoader=nil; Questie=nil
local reads={world=0,npc=0,loads=0}
local tip, hidden
PolestarPlanner.Widgets={Tooltip=function(owner,anchor,title,lines) tip={owner=owner,title=title,lines=lines} end,
  HideTip=function(owner) hidden=owner end}
Polestar.Compat.MapToWorld=function(map,x,y,f)
  reads.world=reads.world+1
  if UNAVAILABLE then return nil end
  return map==1438 and 1 or 0,1000-y*10,1000-x*10
end
local thor={id=523,name="Thor",faction="A",spawns={{map=1436,x=56.55,y=52.64,f="e"}}}
local ids={523}
local npcs={[523]=thor}
local loaded=true
Polestar.Codex={IsLoaded=function() return loaded end,
  Load=function() reads.loads=reads.loads+1; loaded=true; return true end,
  WithRole=function(role) assert(role=="flightmaster"); return ids end,
  Npc=function(id) reads.npc=reads.npc+1; return npcs[id] end}
local taxi={{id=4,name="Sentinel Hill, Westfall",short="Sentinel Hill",c=0,wx=473.3,wy=434.3,map=1436,x=56.57,y=52.67,f="e",faction=1}}
Polestar.Nav.GetTravelData=function() return {taxi=taxi} end
local parent=CreateFrame("Frame"); parent:SetSize(1000,1000); parent:Show()
local layer=PolestarPlanner.LiveServices.Create(parent)
local map={art=true,bounds={c=0,left=1000,top=1000,kx=-.001,ky=-.001},
  View={width=1000,height=1000,offsetX=0,offsetY=0,drawWidth=1000,drawHeight=1000,scale=1}}
`;

function run(script) {
  return runAddon({ stubs: ['stub_ui.lua'], addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'UI/LiveServices.lua'] }], script: fixture + script }).emitted[0];
}

test('a flight-master service appears with native art, verified Thor position and tooltip without Questie', () => {
  const out = run(`
    PolestarPlanner.Set("liveMap.questie",false)
    layer:Refresh(map)
    local m=layer.Markers[1]; m:GetScript("OnEnter")(m)
    emit({count=layer.markerCount,scene=#layer.scene,npc=m.service.npc,x=m.points[1].x,y=m.points[1].y,
      icon=m.Icon:GetTexture(),title=tip.title,lines=tip.lines,questie=QuestieLoader or false})
  `);
  assert.deepEqual(out, { count: 1, scene: 1, npc: 523, x: 565.5, y: -526.4, icon: 136456,
    title: 'Thor', lines: ['Flight master'], questie: false });
});

test('the taxi network supplies friendly service pins if the optional Codex is absent', () => {
  const out = run(`
    Polestar.Codex=nil
    taxi[2]={id=99,name="Enemy",short="Enemy",c=0,wx=500,wy=500,faction=2}
    taxi[3]={id=100,name="Other continent",c=1,wx=500,wy=500,faction=1}
    taxi[4]={id=101,name="Outside viewport",c=0,wx=-1000,wy=-1000,faction=1}
    layer:Refresh(map)
    layer.Markers[1]:GetScript("OnEnter")(layer.Markers[1])
    emit({count=layer.markerCount,title=tip.title,lines=tip.lines,x=layer.Markers[1].points[1].x})
  `);
  assert.deepEqual(out, { count: 1, title: 'Sentinel Hill', lines: ['Flight master'], x: 565.7 });
});

test('full and compact layers retain independent cameras and recycle their own pins during pan and zoom', () => {
  const out = run(`
    local second=PolestarPlanner.LiveServices.Create(parent)
    local compact={art=true,bounds=map.bounds,View={width=300,height=250,offsetX=-400,offsetY=-350,drawWidth=1000,drawHeight=1000}}
    layer:Refresh(map); second:Refresh(compact)
    local firstPin,compactPin=layer.Markers[1],second.Markers[1]
    local first={firstPin.points[1].x,firstPin.points[1].y}
    local compactPos={compactPin.points[1].x,compactPin.points[1].y}
    for i=1,10 do compact.View.offsetX=compact.View.offsetX-1; second:Refresh(compact) end
    local reused=second.Markers[1]==compactPin
    compact.View.offsetX=-900; second:Refresh(compact)
    emit({first=first,compact=compactPos,fullStill={firstPin.points[1].x,firstPin.points[1].y},separate=firstPin~=compactPin,
      reused=reused,pools={#layer.Markers,#second.Markers},counts={layer.markerCount,second.markerCount},scans={layer.scans,second.scans}})
  `);
  assert.deepEqual(out.first, [565.5, -526.4]);
  assert.deepEqual(out.compact, [165.5, -176.4]);
  assert.deepEqual(out.fullStill, out.first);
  assert.equal(out.separate, true);
  assert.equal(out.reused, true);
  assert.deepEqual(out.pools, [1, 1]);
  assert.deepEqual(out.counts, [1, 0]);
  assert.deepEqual(out.scans, [1, 1]);
});

test('hidden service layers stop reading sources, clear hovered pins and reuse them when shown', () => {
  const out = run(`
    layer:Refresh(map); local pin=layer.Markers[1]
    pin:GetScript("OnEnter")(pin); layer:Hide()
    local before={world=reads.world,npc=reads.npc,scans=layer.scans}
    for i=1,20 do layer:Refresh(map) end
    local stopped=reads.world==before.world and reads.npc==before.npc and layer.scans==before.scans
    local cleared=pin.service==nil and not pin:IsShown() and hidden==pin
    layer:Show(); layer:Refresh(map)
    emit({stopped=stopped,cleared=cleared,reused=pin==layer.Markers[1],count=layer.markerCount,updater=layer:GetScript("OnUpdate") or false})
  `);
  assert.deepEqual(out, { stopped: true, cleared: true, reused: true, count: 1, updater: false });
});

test('Codex enrichment defers optional loading until after combat and replaces its taxi fallback', () => {
  const out = run(`
    loaded=false; local combat=true
    InCombatLockdown=function() return combat end
    layer:Refresh(map)
    local before={loads=reads.loads,npc=layer.Markers[1].service.npc or false}
    combat=false; layer:Refresh(map)
    for i=1,10 do layer:Refresh(map) end
    emit({before=before,loads=reads.loads,npc=layer.Markers[1].service.npc,count=layer.markerCount,scans=layer.scans})
  `);
  assert.deepEqual(out, { before: { loads: 0, npc: false }, loads: 1, npc: 523, count: 1, scans: 2 });
});

test('temporarily unavailable NPC geometry recovers and secret or missing map values hide stale service pins', () => {
  const out = run(`
    UNAVAILABLE=true; layer:Refresh(map)
    local fallback=layer.Markers[1].service.npc or false
    UNAVAILABLE=false; stub.advance(1.1); layer:Refresh(map)
    local recovered=layer.Markers[1].service.npc
    local secret={}; Polestar.Compat.IsSecret=function(v) return v==secret end
    map.View.drawWidth=secret; layer:Refresh(map)
    local restricted=layer.markerCount
    map.View.drawWidth=1000; map.art=nil; layer:Refresh(map)
    emit({fallback=fallback,recovered=recovered,restricted=restricted,missing=layer.markerCount,hidden=not layer.Markers[1]:IsShown()})
  `);
  assert.deepEqual(out, { fallback: false, recovered: 523, restricted: 0, missing: 0, hidden: true });
});

test('a matching precise guide target refines rounded Codex data without changing navigation or clipping half an icon', () => {
  const out = run(`
    thor.spawns[1].x=56.6; thor.spawns[1].y=52.6
    local goal={t="getfp",npc=523,npcName="Thor",map=1436,x=56.55,y=52.64,f="e"}
    local guide={steps={{goals={goal}}}}
    Polestar.Engine.GetGuide=function() return guide end
    layer:Refresh(map)
    local precise={layer.Markers[1].points[1].x,layer.Markers[1].points[1].y}
    map.View.offsetX=-560; layer:Refresh(map)
    local edge=layer.markerCount
    map.View.offsetX=-550; layer:Refresh(map)
    emit({precise=precise,edge=edge,inside=layer.markerCount,goal={goal.x,goal.y}})
  `);
  assert.deepEqual(out, { precise: [565.5, -526.4], edge: 0, inside: 1, goal: [56.55, 52.64] });
});

test('both real shared map constructors wire the service layer independently of quest overlays and stop it while hidden', () => {
  const out = runAddon({
    stubs: ['stub_ui.lua', 'live-dashboard.lua'],
    addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'Theme/Theme.xml', 'Nav/Regions.lua', 'Maps/RouteStrokes.lua', 'UI/UI.xml'] }],
    script: `uistub.install(); livestub.install(); stub.login()
      QuestieLoader=nil; PolestarPlanner.Set("liveMap.questie",false); PolestarPlanner.Set("liveMap.objectives",false)
      local reads=0
      Polestar.Nav.GetTravelData=function() reads=reads+1; return {taxi={{id=4,name="Thor's verified taxi",short="Sentinel Hill",c=0,wx=736.8,wy=434.5,faction=1}}} end
      local full=PolestarPlanner.LiveMap.Create(UIParent)
      local small=PolestarPlanner.LiveMap.Create(UIParent,{compact=true})
      full.Viewport:SetSize(1000,500); small.Viewport:SetSize(400,250)
      full:Refresh(true); small:Refresh(true)
      local visible={full.Services.markerCount,small.Services.markerCount}
      full:Hide(); small:Hide(); local before=reads; stub.advance(2)
      emit({visible=visible,separate=full.Services.Markers~=small.Services.Markers,hiddenReads=reads-before,
        order=full.Questie:GetFrameLevel()<full.Services:GetFrameLevel() and full.Services.Markers[1]:GetFrameLevel()<full.PlayerMarker:GetFrameLevel(),
        counts={full.Services.markerCount,small.Services.markerCount},questie=PolestarPlanner.Get("liveMap.questie")})`,
  }).emitted[0];
  assert.deepEqual(out.visible, [1, 1]);
  assert.equal(out.separate, true);
  assert.equal(out.hiddenReads, 0);
  assert.equal(out.order, true);
  assert.deepEqual(out.counts, [0, 0]);
  assert.equal(out.questie, false);
});
