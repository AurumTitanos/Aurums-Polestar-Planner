'use strict';
const {singleTarget}=require('./helpers/target-macro');
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {runAddon}=require('./helpers/lua');
const path=require('node:path');
const {STOCK}=require('./helpers/lua');
const {luaValue}=require(path.join(STOCK,'tools/lib/playtest'));
// Model only the two visibility states used here. The driver may change
// visibility in combat; insecure companion writes to protected methods may not.
const secure=`
local drivers={}
function RegisterStateDriver(b,state,condition)
 assert(not InCombatLockdown(),'registering a driver in combat')
 assert(state=='visibility')
 local d=drivers[b]
 if not d then
  d={show=b.Show,hide=b.Hide};drivers[b]=d
  for _,method in ipairs({'SetAttribute','Show','Hide','SetPoint','ClearAllPoints','SetScale'})do
   local original=b[method]
   b[method]=function(self,...)assert(not InCombatLockdown(),'protected '..method..' in combat');return original(self,...)end
  end
 end
 d.condition=condition
 if condition=='hide' or stub.inCombat then d.hide(b) else d.show(b) end
end
function npcCombat(value)
 stub.inCombat=value
 for b,d in pairs(drivers)do
  if value or d.condition=='hide' then d.hide(b) else d.show(b) end
 end
 stub.fire(value and 'PLAYER_REGEN_DISABLED' or 'PLAYER_REGEN_ENABLED')
 stub.advance(.4)
end
`;
const setup=`
local w=stub.world;w.race='NightElf';w.class='DRUID';w.level=9
w.addMap(1438,{name='Teldrassil',c=1,left=1000,right=-3000,top=1000,bottom=-1800})
w.moveTo(1438,55,57)
`;
function run(goals,script='',before=''){
 return runAddon({fullCore:true,stubs:['stub_world.lua'],before:secure+setup+before,between:`
 Polestar.RegisterPack({addon='NpcTest',id='npc-test',format=2,title='Test',author='Test',version='1',license='MIT'})
 assert(Polestar.RegisterGuide({id='npc-test/actions',pack='npc-test',title='NPC actions',steps={
 {goals={${goals}}},{goals={{t='level',level=60}}}
 }}))
 `,script:`
 stub.login();Polestar.Engine.SetGuide('npc-test/actions');Polestar.Engine.Goto(1);stub.advance(.4)
 local P=PolestarPlanner
 local function snapshot()
  local b=P.NpcAction.GetFrame()
  return {exists=b~=nil,shown=b and b:IsShown(),macro=b and b:GetAttribute('macrotext'),
   name=b and b.npcName,label=b and b.Label:GetText(),targetShown=PolestarTargetButton:IsShown(),
   stepMacro=PolestarStepButton:GetAttribute('macrotext'),stepType=PolestarStepButton:GetAttribute('type'),
   stepItem=PolestarStepButton:GetAttribute('item'),scale=b and b:GetScale(),
   anchor=b and select(2,b:GetPoint(1)) and select(2,b:GetPoint(1)):GetName()}
 end
 ${script}
 `}).emitted;
}
const amara="{t='accept',quest=487,title='The Road to Darnassus',npc=2151,npcName='Moon Priestess Amara',map=1438,x=52.91,y=57.2}";
test('Amara gets a clickable companion macro in the unused stock slot; no target or guide writes occur',()=>{
 const [out]=run(amara,`
 local before=stub.json(PolestarCharDB);P.NpcAction.Refresh()
 local s=snapshot();s.unchanged=before==stub.json(PolestarCharDB);s.calls=#stub.world.calls;emit(s)
 `);
 assert.equal(out.shown,true);assert.equal(out.targetShown,false);
 assert.equal(out.macro,'/targetexact [nocombat] Moon Priestess Amara');
 assert.equal(out.stepMacro,singleTarget('Moon Priestess Amara'));
 assert.equal(out.label,'Moon Priestess Amara');assert.equal(out.anchor,'PolestarTargetButton');
 assert.equal(out.unchanged,true);assert.equal(out.calls,0);
});
test('acceptance removes the companion button and macro',()=>{
 const [out]=run(amara,`stub.world.accept(487,{},'The Road to Darnassus');stub.advance(.4);emit(snapshot())`);
 assert.equal(out.shown,false);assert.equal(out.macro,undefined);
});
test('the companion follows stock NPC verbs and never displays for a visible combat-target button',()=>{
 for(const goal of [
  "{t='turnin',quest=476,title='Gnarlpine Corruption',npc=2078,npcName='Athridas Bearmantle'}",
  "{t='talk',npc=2151,npcName='Moon Priestess Amara'}",
  "{t='train',npc=3602,npcName='Kal'}",
  "{t='vendor',npc=3609,npcName='Shalomon'}",
  "{t='buy',item=159,itemName='Refreshing Spring Water',count=5,npc=6736,npcName='Innkeeper Keldamyr'}"
 ]){
  const [out]=run(goal,'emit(snapshot())',"stub.world.onQuest(476,{},'Gnarlpine Corruption');stub.world.finish(476)");assert.equal(out.shown,true,goal);assert.ok(out.name);
 }
 const [out]=run(amara+",{t='kill',npc=2152,target='Gnarlpine Ambusher',count=6}",'emit(snapshot())');
 assert.equal(out.targetShown,true);assert.equal(out.shown,false);assert.equal(out.macro,undefined);
});
test('target-button setting and scale changes are read from stock without changing its settings',()=>{
 const [disabled,enabled]=run(amara,`
 Polestar.Set('qol.targetButton',false);stub.advance(.4);emit(snapshot())
 Polestar.Set('qol.targetButton',true);Polestar.Set('qol.buttonScale',1.3);stub.advance(.4);emit(snapshot())
 `);
 assert.equal(disabled.shown,false);assert.equal(disabled.macro,undefined);
 assert.equal(enabled.shown,true);assert.equal(enabled.scale,1.3);
});
test('combat hides via the secure driver, defers protected writes and clears a finished action on leaving combat',()=>{
 const [during,after]=run(amara,`
 npcCombat(true);stub.world.accept(487,{},'The Road to Darnassus');stub.advance(.4)
 P.NpcAction.Refresh();emit(snapshot());npcCombat(false);emit(snapshot())
 `);
 assert.equal(during.shown,false);assert.equal(during.macro,'/targetexact [nocombat] Moon Priestess Amara');
 assert.equal(after.shown,false);assert.equal(after.macro,undefined);
});
test('reload during combat waits to create the secure button',()=>{
 const [during,after]=run(amara,'emit(snapshot());npcCombat(false);emit(snapshot())','stub.inCombat=true\n');
 assert.equal(during.exists,false);assert.equal(after.exists,true);assert.equal(after.shown,true);
});
test('unsafe NPC names never become an actionable companion macro',()=>{
 const [out]=run("{t='talk',npc=2151,npcName='Amara\\n/run print(1)'}",'emit(snapshot())');
 assert.equal(out.shown,false);assert.equal(out.macro,undefined);
});

// Upgrade regression: target data can be ready before the coalesced frame shows.
test('stock mob-target intent reserves the slot before its frame becomes visible',()=>{
 const [held,recovered]=run(amara,`
 local before=stub.json(PolestarCharDB)
 local old=Polestar.QoL.Buttons.TargetNames
 PolestarTargetButton:Hide()
 Polestar.QoL.Buttons.TargetNames=function() return {'Gnarlpine Ambusher'} end
 P.NpcAction.Refresh()
 local held=snapshot();held.unchanged=before==stub.json(PolestarCharDB);emit(held)
 Polestar.QoL.Buttons.TargetNames=old;P.NpcAction.Refresh();emit(snapshot())
 `);
 assert.equal(held.targetShown,false);assert.equal(held.shown,false);assert.equal(held.macro,undefined);assert.equal(held.unchanged,true);
 assert.equal(recovered.shown,true);assert.equal(recovered.name,'Moon Priestess Amara');
});
