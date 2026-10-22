'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {runAddon, ROOT, STOCK} = require('./helpers/lua');

const WORLD = `
local w=stub.world
w.addMap(1429,{name="Elwynn Forest",c=0,left=1500,right=-1500,top=500,bottom=-1500})
w.moveTo(1429,20,80)
`;
const GUIDE = `
assert(Polestar.RegisterPack({addon="Polestar_Test",id="test",format=1,title="Test",author="Test",version="1",license="MIT"}))
Polestar.RegisterGuide({id="test/companion",pack="test",title="Companion integration",category="Exploration",steps={
 {title="First",goals={{t="level",level=50,map=1429,x=25,y=70}}},
 {title="Second",goals={{t="level",level=55,map=1429,x=55,y=30}}},
 {title="Third",goals={{t="level",level=60,map=1429,x=75,y=20}}},
}})
`;
function run(script, options={}) {
  return runAddon({fullCore:true,stubs:['stub_world.lua'],before:WORLD,...options,script}).emitted;
}

test('complete stock core and companion use separate namespaces, helpers, frames and command owners', () => {
  const [out] = run(`
    stub.login()
    local P=PolestarPlanner
    P.LiveDashboard.Show(); P.LiveMiniMap.Show()
    emit({separate=P~=Polestar,theme=P.Theme~=Polestar.Theme,widgets=P.Widgets~=Polestar.Widgets,
      coreViewer=Polestar.LiveDashboard~=nil,coreTracker=Polestar.QuestieTurnIns~=nil,companionTracker=P.QuestieTurnIns~=nil,
      full=P.LiveDashboard.GetFrame():GetName(),small=P.LiveMiniMap.GetFrame():GetName(),
      coreSlash=SlashCmdList.POLESTAR~=nil,plannerSlash=SlashCmdList.POLESTARPLANNER~=nil,
      navWrite=P.Nav.SetTarget~=nil,engineWrite=P.Engine.Goto~=nil,status=P.Adapter.Status()})
  `);
  assert.equal(out.separate,true);
  assert.equal(out.theme,true);
  assert.equal(out.widgets,true);
  assert.equal(out.coreViewer,false);
  assert.equal(out.coreTracker,true);
  assert.equal(out.companionTracker,false);
  assert.equal(out.full,'PolestarPlannerDashboard');
  assert.equal(out.small,'PolestarPlannerMiniMap');
  assert.equal(out.coreSlash,true);
  assert.equal(out.plannerSlash,true);
  assert.equal(out.navWrite,false);
  assert.equal(out.engineWrite,false);
  assert.equal(out.status.guide,true);
  assert.equal(out.status.routes,true);
  assert.equal(out.status.coordinates,true);
});

test('legacy viewer preferences migrate once as deep copies without importing engine or guide settings', () => {
  const [out] = run(`
    local P=PolestarPlanner
    local first=P.Get("liveMiniMap.view").zoom
    local different=P.Get("liveMiniMap")~=PolestarDB.settings.liveMiniMap and P.Get("liveMiniMap.view")~=PolestarDB.settings.liveMiniMap.view
    P.Get("liveMiniMap.view").zoom=9
    PolestarDB.settings.liveDashboard.width=1111
    P.MigrateSettings()
    emit({first=first,different=different,oldZoom=PolestarDB.settings.liveMiniMap.view.zoom,
      width=P.Get("liveDashboard.width"),auto=P.Get("liveMiniMap.autoZoom"),follow=P.Get("liveMiniMap.view").follow,
      navCopied=P.DB().settings.nav~=nil,uiCopied=P.DB().settings.ui~=nil,
      charGuide=PolestarCharDB.guide,flag=PolestarCharDB.flags.private,
      migration=P.DB().migrations.legacyViewer})
  `,{saved:{Polestar:`
    PolestarDB={schema=1,settings={liveMiniMap={autoZoom=false,view={zoom=7,follow=false}},liveDashboard={width=1277},liveMap={questie=false},nav={arrow=false},ui={width=399}}}
    PolestarCharDB={schema=1,guide="private/progress",flags={private=true},manual={private={abc=true}}}
  `}});
  assert.deepEqual(out,{first:7,different:true,oldZoom:7,width:1277,auto:false,follow:false,navCopied:false,uiCopied:false,charGuide:'private/progress',flag:true,migration:1});
});

test('existing companion preferences win over legacy settings and reload does not migrate again', () => {
  const [out] = run(`
    local P=PolestarPlanner
    emit({width=P.Get("liveMiniMap.width"),old=PolestarDB.settings.liveMiniMap.width,
      follow=P.Get("liveDashboard.followStep"),migration=P.MigrateSettings()})
  `,{saved:{
    Polestar:'PolestarDB={settings={liveMiniMap={width=777},liveDashboard={followStep=false}}}',
    Polestar_Planner:'PolestarPlannerDB={schema=1,settings={liveMiniMap={width=511}},migrations={legacyViewer=1}}',
  }});
  assert.deepEqual(out,{width:511,old:777,follow:true,migration:false});
});

test('browsing real stock step views and maps leaves current guide, manual progress and navigation intact', () => {
  const [out] = run(`
    ${GUIDE}
    stub.login(); Polestar.Engine.SetGuide("test/companion"); stub.advance(.3)
    Polestar.Nav.SetTarget(1429,40,60,"Kept navigation")
    local E,N,P=Polestar.Engine,Polestar.Nav,PolestarPlanner
    local target=N.GetTarget()
    local before=stub.json(PolestarCharDB)
    local start=E.GetStepIndex()
    P.LiveDashboard.Show(); P.LiveMiniMap.Show()
    P.LiveDashboard.SelectStep(3)
    local selected=P.LiveDashboard.GetSnapshot().selectedIndex
    P.LiveMiniMap.GetFrame().Map:ShowPlayer()
    P.LiveDashboard.FollowCurrent()
    P.LiveDashboard.Hide(); P.LiveMiniMap.Hide()
    emit({start=start,current=E.GetStepIndex(),selected=selected,sameTarget=target==N.GetTarget(),
      targetLabel=N.GetTarget().label,guide=E.GetGuide().id,progressSame=before==stub.json(PolestarCharDB)})
  `);
  assert.equal(out.start,1);
  assert.equal(out.current,1);
  assert.equal(out.selected,3);
  assert.equal(out.sameTarget,true);
  assert.equal(out.targetLabel,'Kept navigation');
  assert.equal(out.guide,'test/companion');
  assert.equal(out.progressSame,true);
});

test('stock events and dynamically replaced read methods remain visible without duplicating event subscriptions', () => {
  const [out] = run(`
    local P=PolestarPlanner
    local events=0
    P.On("STEP_CHANGED",function() events=events+1 end)
    P.Adapter.Connect(); P.Adapter.Connect()
    Polestar.Fire("STEP_CHANGED",2)
    local old=Polestar.Engine.GetStepCount
    Polestar.Engine.GetStepCount=function() return 37 end
    local count=P.Engine.GetStepCount()
    Polestar.Engine.GetStepCount=old
    local ui=Polestar.UI
    Polestar.UI={PlainGoalText=function() return "updated formatter" end}
    local text=P.UI.PlainGoalText({})
    Polestar.UI=ui
    emit({events=events,count=count,text=text,write=P.Engine.SetGuide~=nil})
  `);
  assert.deepEqual(out,{events:1,count:37,text:'updated formatter',write:false});
});

test('stock region geometry is used through the adapter and missing optional contracts fall back safely', () => {
  const [out] = run(`
    local P=PolestarPlanner
    local goal={map=1429,spots={{x=40,y=30,r=20},{x=40.5,y=30.5,r=20}}}
    local expected=Polestar.Nav.layers.Regions(goal)
    local actual=P.NavRegions.ForGoal(goal)
    local same=expected==actual
    Polestar.Nav.layers=nil
    local fallback=P.NavRegions.ForGoal(goal)
    Polestar.Codex=nil; Polestar.QoL=nil; Polestar.RoutePlan=nil
    local snapshot=P.LiveDashboard.GetSnapshot()
    emit({same=same,regions=#actual,fallback=#fallback,count=snapshot.stepCount,
      codexMissing=P.Codex.IsLoaded==nil,qolMissing=P.QoL.GetHearth==nil})
  `);
  assert.equal(out.same,true);
  assert.equal(out.regions,1);
  assert.equal(out.fallback,1);
  assert.equal(out.count,0);
  assert.equal(out.codexMissing,true);
  assert.equal(out.qolMissing,true);
});

test('previous private viewer key IDs still open companion windows without changing any assigned keys', () => {
  const xml = fs.readFileSync(path.join(ROOT,'addon/Polestar_Planner/Bindings.xml'),'utf8');
  const stock = fs.readFileSync(path.join(STOCK,'addon/Polestar/Bindings.xml'),'utf8');
  const bodies = Object.fromEntries([...xml.matchAll(/<Binding name="([^"]+)"[^>]*>([\s\S]*?)<\/Binding>/g)]
    .map(m => [m[1],m[2]]));
  assert.doesNotMatch(stock, /name="POLESTAR_(?:LIVE|MINIMAP)"/);
  const [out] = run(`
    stub.login()
    SetBinding=function() error("must not rewrite saved key assignments") end
    SaveBindings=function() error("must not rewrite saved key assignments") end
    ${bodies.POLESTAR_LIVE}
    ${bodies.POLESTAR_MINIMAP}
    emit({full=PolestarPlanner.LiveDashboard.GetFrame():IsShown(),small=PolestarPlanner.LiveMiniMap.GetFrame():IsShown(),
      coreLive=Polestar.Bindings.Live~=nil,coreMini=Polestar.Bindings.MiniMap~=nil})
  `);
  assert.deepEqual(out,{full:true,small:true,coreLive:false,coreMini:false});
});

test('missing step-view contracts leave the companion usable without advancing the stock guide', () => {
  const [out] = run(`
    ${GUIDE}
    stub.login(); Polestar.Engine.SetGuide("test/companion"); stub.advance(.3)
    local P,E=PolestarPlanner,Polestar.Engine
    local before=stub.json(PolestarCharDB)
    local stepView=E.GetStepView
    E.GetStepView=nil
    P.LiveDashboard.Show(); P.LiveMiniMap.Show()
    local unavailable=P.Adapter.Status().guide==false and P.Engine.GetStepView(1)==nil
    local count=P.LiveDashboard.GetSnapshot().stepCount
    local warning=P.LiveDashboard.GetFrame().EmptyText:GetText()
    E.GetStepCount=nil
    P.LiveDashboard.Hide(); P.LiveDashboard.Show()
    local empty=P.LiveDashboard.GetSnapshot().stepCount
    E.GetStepView=stepView
    P.LiveDashboard.Refresh()
    emit({unavailable=unavailable,count=count,empty=empty,warning=warning,
      shown=P.LiveDashboard.GetFrame():IsShown(),small=P.LiveMiniMap.GetFrame():IsShown(),
      recovered=P.LiveDashboard.GetFrame().EmptyText:GetText()~=warning,
      progressSame=before==stub.json(PolestarCharDB)})
  `);
  assert.deepEqual(out,{unavailable:true,count:0,empty:0,
    warning:'Polestar guide API unavailable; companion update needed.',
    shown:true,small:true,recovered:true,progressSame:true});
});

test('ordinary world-map ownership and optional OpenMap settings stay independent of both companion cameras', () => {
  const [out] = run(`
    stub.login()
    local api,db,world=OpenMapAPI,OpenMapDB,WorldMapFrame
    local parent=world:GetParent()
    world.ScrollContainer.currentScale=3
    stub.worldMapID=1429
    world:Show()
    PolestarPlanner.LiveDashboard.Show(); PolestarPlanner.LiveMiniMap.Show()
    PolestarPlanner.LiveMiniMap.GetFrame().Map:ZoomIn()
    PolestarPlanner.LiveDashboard.GetFrame().Map:ZoomOut()
    emit({sameAPI=OpenMapAPI==api,sameDB=OpenMapDB==db,sameWorld=WorldMapFrame==world,
      sameParent=world:GetParent()==parent,worldScale=world.ScrollContainer.currentScale,
      worldShown=world:IsShown(),worldMap=world:GetMapID(),openMapPreference=OpenMapDB.detail})
  `,{before:WORLD+'OpenMapAPI={version=1}; OpenMapDB={detail="keep me"}'});
  assert.deepEqual(out,{sameAPI:true,sameDB:true,sameWorld:true,sameParent:true,worldScale:3,worldShown:true,worldMap:1429,openMapPreference:'keep me'});
});
