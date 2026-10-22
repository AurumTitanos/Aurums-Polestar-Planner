'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {runAddon}=require('./helpers/lua');
function run(script){return runAddon({stubs:['stub_ui.lua','live-dashboard.lua'],script:`
uistub.install();livestub.install();stub.login();uistub.setGuide(uistub.elwynn,3)
local P=PolestarPlanner
local source=CreateFrame('Button','VisibilityQuestiePin')
source.UiMapID,source.x,source.y=1429,46,40
source.data={Id=999,Type='item',Name='Quest mob',QuestData={name='Quest'},ObjectiveData={Description='Drop',Collected=0,Needed=3}}
source.texture=source:CreateTexture();source.texture:SetTexture('questie-loot');source:Hide()
QuestieLoader={_modules={QuestieMap={questIdFrames={[999]={VisibilityQuestiePin=true}}}}}
${script}`}).emitted;}
test('actual Questie child pins stay below both map routes and the original player arrow stays above them',()=>{
 const [out]=run(`local results={}
 for _,compact in ipairs({false,true}) do
  local m=P.LiveMap.Create(UIParent,{compact=compact});m.Viewport:SetSize(500,400);m:Show();m:Refresh(true)
  local pin=assert(m.Questie.Markers[1],'expected a real Questie overlay marker')
  results[#results+1]={below=pin:GetFrameLevel()<m.RouteLayer:GetFrameLevel(),playerAbove=m.PlayerMarker:GetFrameLevel()>m.RouteLayer:GetFrameLevel(),
   halo=type(m.PlayerMarker.Halo)=="table",shadow=type(m.PlayerMarker.Shadow)=="table",color=m:GetRouteColor(),pulse=m:GetRoutePulse(),lines=m.strokes.n}
 end emit(results)`);
 for(const r of out){assert.equal(r.below,true);assert.equal(r.playerAbove,true);assert.equal(r.halo,false);assert.equal(r.shadow,false);assert.equal(r.color,'cyan');assert.equal(r.pulse,false);assert.ok(r.lines>0);}
});
test('route appearance settings persist across views and pulse uses no separate hidden-map update loop',()=>{
 const [out]=run(`local a=P.LiveMap.Create(UIParent);local b=P.LiveMap.Create(UIParent,{compact=true})
 a:SetRouteColor('pink');a:SetRoutePulse(true);b:Refresh(true)
 local first=b:GetRouteColor();b:SetRouteColor('invalid');b:Hide()
 emit({first=first,kept=b:GetRouteColor(),pulse=b:GetRoutePulse(),saved=P.Get('liveMap.routeColor'),hidden=b:GetScript('OnUpdate')==nil,
  independent=a~=b,coreSetting=Polestar.Get('liveMap.routeColor')})`);
 assert.equal(out.first,'pink');assert.equal(out.kept,'pink');assert.equal(out.pulse,true);assert.equal(out.saved,'pink');assert.equal(out.hidden,true);assert.equal(out.independent,true);assert.equal(out.coreSetting,undefined);
});
