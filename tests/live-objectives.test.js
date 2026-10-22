'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {runAddon}=require('./helpers/lua');
function run(script) {
 return runAddon({stubs:['stub_ui.lua','live-dashboard.lua'],
 addons:[{name:'Polestar',files:['Core/Core.xml','Theme/Theme.xml','Nav/Regions.lua', 'Maps/RouteStrokes.lua','UI/UI.xml']}],
 script:`uistub.install(); livestub.install(); stub.login(); uistub.setGuide(uistub.elwynn,3)
 local E, M, S = Polestar.Engine, PolestarPlanner.LiveMap, livestub
 local guide = E.GetGuide()
 local goals = {}
 for i,count in ipairs({39,34,38}) do
   local spots={}
   for j=1,count do spots[j]={x=35+j*.35,y=30+i*5,r=45+j%35} end
   goals[i]={t="collect",quest=488,verb="Collect",subject=({"Nightsaber Fang","Strigid Owl Feather","Webwood Spider Silk"})[i],item=3408+i,
     map=1429,x=40+i,y=40,spots=spots,status="active",progress={cur=0,max=3}}
 end
 goals[4]={t="collect",verb="Collect",subject="Filled Jade Phial",map=1429,x=63.4,y=58.1,status="pending"}
 goals[5]={t="turnin",quest=488,verb="Turn in",subject="Zenn's Bidding",map=1429,x=60.35,y=56.16,status="pending"}
 guide.steps[3].goals=goals
 -- Engine views deliberately expose only the spot COUNT, as the real Engine does.
 local realView=E.GetStepView
 E.GetStepView=function(i)
   local view=realView(i)
   if view then for _,v in ipairs(view.goals) do if type(v.spots)=="table" then v.spots=#v.spots end end end
   return view
 end
 uistub.target={map=1429,x=41,y=40,label="Collect Nightsaber Fang",stepIndex=3,goalIndex=1}
 local map=M.Create(UIParent)
 map.View=false; map.Viewport:SetSize(1000,500); map:Refresh(true)
 local O=map.Objectives
 ${script}`}).emitted[0];
}
test('all three mob populations, moonwell, and delayed turn-in appear together from compiled spots',()=>{
 const out=run(`emit({areas=#O.scene.areas,markers=O.scene.markers,shown=S.shown(O.Markers),activeLabel=map.GoalMarker.targetLabel})`);
 assert.equal(out.areas,111);assert.equal(out.markers.length,5);assert.equal(out.shown,5);
 assert.equal(out.markers[0].active,true);
 assert.equal(out.markers[0].label,'Collect Nightsaber Fang');
 assert.equal(out.markers[3].label,'Collect Filled Jade Phial');
 assert.equal(out.markers[4].delayed,true);
 assert.equal(out.activeLabel,'Collect Nightsaber Fang');
});
test('objective completion removes its own areas and progress refreshes marker data without moving navigation',()=>{
 const out=run(`local oldTarget=Polestar.Nav.GetTarget(); uistub.calls={}
 goals[1].status="done"; goals[2].progress.cur=2; map:Refresh(false)
 local partial={areas=#O.scene.areas,markers=#O.scene.markers,progress=O.scene.markers[1].progress.cur}
 goals[2].status="done";goals[3].status="done";goals[4].status="done";map:Refresh(false)
 emit({partial=partial,areas=#O.scene.areas,markers=#O.scene.markers,delayed=O.scene.markers[1].delayed,
   target=Polestar.Nav.GetTarget(),oldTarget=oldTarget,step=E.GetStepIndex(),calls=uistub.calls})`);
 assert.deepEqual(out.partial,{areas:72,markers:4,progress:2});
 assert.equal(out.areas,0);assert.equal(out.markers,1);assert.equal(out.delayed,false);
 assert.deepEqual(out.target,out.oldTarget);assert.equal(out.step,3);assert.deepEqual(out.calls,{});
});
test('objective switch hides areas and markers, preserves live arrow, and survives map recreation',()=>{
 const out=run(`map:SetAreaStyle("off"); map:SetObjectives(false)
 local disabled={saved=PolestarPlanner.Get("liveMap.objectives"),enabled=O:GetEnabled(),visible=O:IsShown(),markers=S.shown(O.Markers),arrow=map.GoalMarker:IsShown()}
 local second=M.Create(UIParent); local restored=second.Objectives:GetEnabled()
 map:SetAreaStyle("circles"); map:SetObjectives(true)
 emit({disabled=disabled,restored=restored,enabled=O:GetEnabled(),areas=S.shown(O.Areas),markers=S.shown(O.Markers)})`);
 assert.deepEqual(out.disabled,{saved:false,enabled:false,visible:false,markers:0,arrow:true});
 assert.equal(out.restored,false);assert.equal(out.enabled,true);assert.equal(out.areas,111);assert.equal(out.markers,5);
});
test('future step inspection uses that step and live follow restores current objectives without guide writes',()=>{
 const out=run(`guide.steps[5].goals={{t="collect",verb="Collect",subject="Future item",map=1436,x=50,y=50,
   status="pending",spots={{x=50,y=50,r=50}}}}
 uistub.calls={};map:ShowStep(E.GetStepView(5),5)
 local future={index=O.scene.stepIndex,areas=#O.scene.areas,label=O.scene.markers[1].label}
 map:ShowPlayer()
 emit({future=future,current=O.scene.stepIndex,areas=#O.scene.areas,step=E.GetStepIndex(),calls=uistub.calls})`);
 assert.deepEqual(out.future,{index:5,areas:1,label:'Collect Future item'});
 assert.equal(out.current,3);assert.equal(out.areas,111);assert.equal(out.step,3);assert.deepEqual(out.calls,{});
});
test('spawn circles keep world-yard scale, clip UVs, and reuse geometry on unchanged refresh',()=>{
 const out=run(`goals[1].spots={{x=1,y=50,r=60}};guide.steps[3].goals={goals[1]}
 map:SetAreaStyle("circles"); map:Refresh(true)
 local t=O.Areas[1];local before=O.paints;local builds=O.sceneBuilds
 for i=1,10 do map:Refresh(false) end
 emit({width=t:GetWidth(),height=t:GetHeight(),uv=t.texCoord,paints=O.paints,before=before,builds=O.sceneBuilds,oldBuilds=builds})`);
 assert.ok(Math.abs(out.height-120*64/59)<.001);
 assert.ok(out.width<out.height,'left edge circle is clipped rather than resized');
 assert.ok(out.uv[0]>0 && out.uv[1]<=1);
 assert.equal(out.paints,out.before);assert.equal(out.builds,out.oldBuilds);
});
test('folded, skipped, inapplicable, and secret coordinates never leak into current overlay',()=>{
 const out=run(`goals[1].status="skipped";goals[2].status="na";goals[3].folded=true
 goals[4].x=S.secret;goals[5].status="done";map:Refresh(false)
 emit({areas=#O.scene.areas,markers=#O.scene.markers,shown=S.shown(O.Markers)})`);
 assert.deepEqual(out,{areas:0,markers:0,shown:0});
});

test('grouped regions are the default and the Layers menu keeps Questie and guide markers independent',()=>{
 const out=run(`local before={style=map:GetAreaStyle(),regions=#O.scene.regions,circles=S.shown(O.Areas),questie=map:GetQuestie()}
 map.LayersButton:Click();local items={}
 for _,row in ipairs(PolestarPlannerMenu.rows) do
  if row:IsShown() then items[#items+1]=row.Text:GetText() end
  if row:IsShown() and row.Text:GetText()=="Questie spawn icons" then row:Click();break end
 end
 local toggled={questie=map:GetQuestie(),style=map:GetAreaStyle(),markers=map:GetObjectives()}
 map:SetObjectives(false);map:Refresh(true)
 emit({before=before,toggled=toggled,items=items,regionsAfterMarkersOff=#O.scene.regions,markersShown=S.shown(O.Markers)})`);
 assert.equal(out.before.style,'regions');assert.equal(out.before.circles,0);
 assert.ok(out.before.regions>0&&out.before.regions<111);assert.equal(out.before.questie,true);
 assert.deepEqual(out.toggled,{questie:false,style:'regions',markers:true});
 assert.ok(out.items.includes('Polestar regions'));assert.ok(out.items.includes('Questie spawn icons'));
 assert.equal(out.regionsAfterMarkersOff,out.before.regions);assert.equal(out.markersShown,0);
});

test('hover identifies overlapping objectives and never steals a marker tooltip',()=>{
 const out=run(`map:SetQuestie(false)
 map.Viewport.GetLeft=function() return 0 end; map.Viewport.GetTop=function() return 500 end
 GetCursorPosition=function() return 450,300 end; GetMouseFoci=function() return {map.Viewport} end
 GameTooltip.GetOwner=function(self) return self.owner end
 stub.RunScript(map.Viewport,"OnEnter")
 local regionLines={};for _,line in ipairs(GameTooltip.lines) do regionLines[#regionLines+1]=line end
 local pin=O.Markers[1];stub.RunScript(pin,"OnEnter");map:Refresh(true)
 local preserved=GameTooltip:GetOwner()==pin and GameTooltip:IsShown()
 stub.RunScript(map.Viewport,"OnLeave")
 emit({lines=regionLines,preserved=preserved,stillOwned=GameTooltip:GetOwner()==pin and GameTooltip:IsShown()})`);
 assert.ok(out.lines.some(x=>x.includes('Nightsaber Fang')));
 assert.ok(out.lines.some(x=>x.includes('Strigid Owl Feather')));
 assert.ok(out.lines.some(x=>x.includes('Webwood Spider Silk')));
 assert.equal(out.preserved,true);assert.equal(out.stillOwned,true);
});

test('a ready hand-in is not delayed by unrelated collection goals and hover uses the actual NPC',()=>{
 const out=run(`
 goals[5].quest=37;goals[5].title='Find the Lost Guards';goals[5].subject='Find the Lost Guards';goals[5].objName='A half-eaten body'
 Polestar.Compat.IsQuestReadyForTurnIn=function(id) return id==37 end
 map:SetQuestie(false);map:Refresh(false)
 local marker
 for _,m in ipairs(O.Markers) do if m.objective and m.objective.kind=='turnin' then marker=m end end
 stub.RunScript(marker,'OnEnter')
 emit({delayed=marker.objective.delayed,tip=GameTooltip.lines,icon=marker.Icon:GetTexture(),ring=marker.Ring:IsShown(),back=marker.Back:IsShown()})`);
 assert.equal(out.delayed,false);
 assert.match(out.tip[0],/A half-eaten body/);
 assert.match(out.tip[1],/Find the Lost Guards \(Complete\)/);
 assert.ok(!out.tip.some(x=>x.includes('collection objectives')));
 assert.match(out.icon,/GossipFrame\\ActiveQuestIcon$/);
 assert.equal(out.ring,false);assert.equal(out.back,false);
});

test('one NPC with multiple authored quest actions has one vanilla pin and every quest in the hover',()=>{
 const out=run(`
 guide.steps[3].goals={
 {t='turnin',quest=5545,title='A Bundle of Trouble',qlvl=9,npcName='Supervisor Raelen',map=1429,x=50,y=50,status='active'},
 {t='accept',quest=123,title='Next quest',qlvl=10,npcName='Supervisor Raelen',map=1429,x=50,y=50,status='pending'}}
 Polestar.Compat.IsQuestReadyForTurnIn=function(id) return id==5545 end
 uistub.target={map=1429,x=50,y=50,stepIndex=3,goalIndex=1}
 map:SetQuestie(false);map:Refresh(false)
 local marker=O.Markers[1];stub.RunScript(marker,'OnEnter')
 emit({count=#O.scene.markers,shown=S.shown(O.Markers),entries=#marker.objective.entries,tip=GameTooltip.lines})`);
 assert.equal(out.count,1);assert.equal(out.shown,1);assert.equal(out.entries,2);
 assert.match(out.tip[0],/Supervisor Raelen/);
 assert.match(out.tip[1],/\[9\] A Bundle of Trouble \(Complete\)/);
 assert.match(out.tip[2],/\[10\] Next quest \(Available\)/);
});

test('recycling and hiding authored markers clears their owned hover rather than leaving stale quest text',()=>{
 const out=run(`
 GameTooltip.GetOwner=function(self) return self.owner end
 local pin=O.Markers[1];stub.RunScript(pin,'OnEnter')
 local before=GameTooltip:IsShown()
 guide.steps[3].goals={};map:Refresh(false)
 emit({before=before,after=GameTooltip:IsShown(),objective=pin.objective,shown=pin:IsShown()})`);
 assert.equal(out.before,true);assert.equal(out.after,false);assert.equal(out.shown,false);assert.equal(out.objective,undefined);
});

test('different NPCs at the same coordinates retain distinct authored markers',()=>{
 const out=run(`
 guide.steps[3].goals={
 {t='accept',quest=123,title='First quest',npc=1,npcName='First giver',map=1429,x=50,y=50,status='active'},
 {t='accept',quest=456,title='Second quest',npc=2,npcName='Second giver',map=1429,x=50,y=50,status='pending'}}
 map:Refresh(false);emit({count=#O.scene.markers,shown=S.shown(O.Markers)})`);
 assert.equal(out.count,2);assert.equal(out.shown,2);
});

test('quest collection hover names its source and refreshes live objective progress while held without repaint',()=>{
 const out=run(`
 GameTooltip.GetOwner=function(self) return self.owner end
 goals[1].title="Zenn's Bidding";goals[1].from='Nightsaber';goals[1].oi=1
 local count=1
 C_QuestLog={ReadyForTurnIn=function() return false end,
 GetQuestObjectives=function() return {{text='Nightsaber Fang',numFulfilled=count,numRequired=3},{text='Other objective 0/9'}} end}
 map:Refresh(false)
 local pin=O.Markers[1];stub.RunScript(pin,'OnEnter')
 local before=O.paints
 count=2;map:Refresh(false)
 emit({shown=GameTooltip:IsShown(),owner=GameTooltip:GetOwner()==pin,lines=GameTooltip.lines,paints=O.paints,before=before})`);
 assert.equal(out.shown,true);assert.equal(out.owner,true);
 assert.match(out.lines[0],/Nightsaber/);assert.match(out.lines[1],/Zenn's Bidding/);
 assert.ok(out.lines.includes('Nightsaber Fang  2/3'));
 assert.ok(!out.lines.some(x=>x.includes('Other objective')));
 assert.equal(out.paints,out.before);
});

test('held quest hand-in hover stays visible and updates when readiness rebuilds its scene',()=>{
 const out=run(`
 GameTooltip.GetOwner=function(self) return self.owner end
 goals[5].title="Zenn's Bidding";goals[5].npcName='Zenn Foulhoof'
 local ready=false;Polestar.Compat.IsQuestReadyForTurnIn=function() return ready end
 map:Refresh(false)
 local pin
 for _,m in ipairs(O.Markers) do if m.objective and m.objective.kind=='turnin' then pin=m end end
 stub.RunScript(pin,'OnEnter');ready=true;map:Refresh(false)
 emit({shown=GameTooltip:IsShown(),owner=GameTooltip:GetOwner()==pin,lines=GameTooltip.lines,delayed=pin.objective.delayed})`);
 assert.equal(out.shown,true);assert.equal(out.owner,true);assert.equal(out.delayed,false);
 assert.match(out.lines[1],/\(Complete\)/);
});
