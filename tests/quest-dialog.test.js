'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {runAddon,STOCK}=require('./helpers/lua');
const {TEST_PACK,TEST_SOURCE}=require(path.join(STOCK,'tests/helpers/packs'));
const fixture=`
${TEST_PACK}
${TEST_SOURCE}
local w=stub.world
w.level=12
Polestar.RegisterGuide({id='test/dialog',pack='test',title='Dialog',steps={
 {goals={{t='accept',quest=109,title='Report to Gryan Stoutmantle',npc=240,minLevel=9},
         {t='accept',quest=59,title='Cloth and Leather Armor',npc=240}}},
 {goals={{t='level',level=60}}}
}})
stub.login();Polestar.Engine.SetGuide('test/dialog');stub.advance(.3)
stub.messages={}
local D=PolestarPlanner.QuestDialog
local function announcements()
 local lines={};for _,s in ipairs(stub.messages)do if s:find('Guide quest accepted:',1,true)then lines[#lines+1]=s end end;return lines
end
`;
function run(script){return runAddon({stubs:['stub_world.lua'],script:fixture+script}).emitted;}

test('records the caller of the unwanted second selection without selecting or accepting it',()=>{
 const [out]=run(`
  debugstack=function()return [[Interface/AddOns/Polestar_Planner/UI/QuestDialog.lua:1
Interface/AddOns/Polestar/Core/Automation.lua:120]] end
  w.greeting(240,{available={{questID=62,title='The Fargodeep Mine'},{questID=109,title='Report to Gryan Stoutmantle'}}})
  debugstack=function()return 'Interface/AddOns/Blizzard_UIPanels_Game/Mainline/QuestFrame.lua:405' end
  w.greeting(240,{available={{questID=62,title='The Fargodeep Mine'}}})
  SelectAvailableQuest(1)
  local selected={};for _,r in ipairs(D.GetTrace())do if r.kind=='SelectAvailableQuest' then selected[#selected+1]=r end end
  emit({accepted=w.log[109]~=nil,unrelated=w.log[62]~=nil,open=w.frame.questID,
   calls=selected,messages=announcements()})
 `);
 assert.equal(out.accepted,true);assert.equal(out.unrelated,false);assert.equal(out.open,62);
 assert.equal(out.calls.length,2);
 assert.match(out.calls[0].extra,/Polestar\/Core\/Automation.lua/);
 assert.equal(out.calls[1].quest,62);assert.match(out.calls[1].extra,/Blizzard_UIPanels_Game/);
 assert.equal(out.messages.length,1);assert.match(out.messages[0],/Report to Gryan Stoutmantle/);
});

test('announces only confirmed guide acceptances, not selection attempts or unrelated quests',()=>{
 const [out]=run(`
  stub.fire('QUEST_ACCEPTED',109)
  local attempted=#announcements()
  w.accept(62,{},'The Fargodeep Mine')
  local unrelated=#announcements()
  w.accept(109,{},'Report to Gryan Stoutmantle')
  stub.fire('QUEST_ACCEPTED',3,109)
  emit({attempted=attempted,unrelated=unrelated,messages=announcements()})
 `);
 assert.equal(out.attempted,0);assert.equal(out.unrelated,0);assert.equal(out.messages.length,1);
});

test('remaining guide pickups are accepted normally and each gets a confirmation',()=>{
 const [out]=run(`
  w.greeting(240,{available={{questID=109,title='Report to Gryan Stoutmantle'}}})
  w.greeting(240,{available={{questID=59,title='Cloth and Leather Armor'}}})
  emit({first=w.log[109]~=nil,second=w.log[59]~=nil,messages=announcements()})
 `);
 assert.equal(out.first,true);assert.equal(out.second,true);assert.equal(out.messages.length,2);
});

test('gossip trace uses quest IDs and repeated hook installation cannot double-log selections',()=>{
 const [out]=run(`
  debugstack=function()return 'Interface/AddOns/Questie/Modules/Auto/AutoQuesting.lua:144' end
  for i=1,3 do w.gossip(240,{available={{questID=62,title='The Fargodeep Mine'}}}) end
  C_GossipInfo.SelectAvailableQuest(62)
  local selected={};for _,r in ipairs(D.GetTrace())do if r.kind=='GossipSelectAvailableQuest' then selected[#selected+1]=r end end
  emit({calls=selected,unrelated=w.log[62]~=nil})
 `);
 assert.equal(out.calls.length,1);assert.equal(out.calls[0].quest,62);
 assert.match(out.calls[0].extra,/Questie\/Modules\/Auto/);assert.equal(out.unrelated,false);
});

test('trace is bounded and can be disabled or cleared without affecting manual quest browsing',()=>{
 const [out]=run(`
  for i=1,100 do w.questDetail(240,62,{title='The Fargodeep Mine'}) end
  local bounded=#D.GetTrace()
  PolestarPlanner.Commands.questtrace.run('off')
  w.questDetail(240,62,{title='The Fargodeep Mine'})
  local disabled=#D.GetTrace()
  PolestarPlanner.Commands.questtrace.run('clear')
  emit({bounded=bounded,disabled=disabled,cleared=#D.GetTrace(),open=w.frame.questID,unrelated=w.log[62]~=nil})
 `);
 assert.deepEqual(out,{bounded:24,disabled:24,cleared:0,open:62,unrelated:false});
});

test('Shift still suppresses stock automation and produces no false success message',()=>{
 const [out]=run(`
  stub.keys.shift=true;w.questDetail(240,109,{title='Report to Gryan Stoutmantle'})
  emit({accepted=w.log[109]~=nil,open=w.frame.questID,messages=announcements()})
 `);
 assert.equal(out.accepted,false);assert.equal(out.open,109);assert.deepEqual(out.messages,{});
});
