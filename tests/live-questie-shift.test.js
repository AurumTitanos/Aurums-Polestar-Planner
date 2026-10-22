'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');
const setup = `
uistub.install(); stub.login()
local L=PolestarPlanner.LiveQuestie
local shifted=false
IsShiftKeyDown=function() return shifted end
local tip, paints, queries=nil,0,{}
GameTooltip.GetOwner=function(self) return self.owner end
PolestarPlanner.Widgets={Tooltip=function(owner,anchor,title,lines)
  paints=paints+1;tip={title=title,lines=lines}
  GameTooltip:SetOwner(owner,anchor);GameTooltip:SetText(title);GameTooltip:Show()
end,HideTip=function(owner) if GameTooltip:GetOwner()==owner then GameTooltip:Hide() end end}
local quests={
 [38]={Id=38,name='Westfall Stew',level=13,Description='Bring the stew ingredients to Salma.'},
 [22]={Id=22,name='Goretusk Liver Pie',level=12,Description='Bring eight Goretusk Livers.'}}
local texts={[38]='0/3 Goretusk Snout',[22]='0/8 Goretusk Liver'}
Questie={db={profile={enableTooltipsQuestLevel=true,showQuestXpAtMaxLevel=true}}}
QuestieLoader={_modules={QuestieMap={questIdFrames={}},
 QuestLogCache={TryGetQuest=function(id) return {title=quests[id].name,objectives={{text=texts[id]}}} end},
 QuestieDB={GetQuest=function(id) return quests[id] end,
   GetCreatureLevels=function(self,q) assert(q==quests[q.Id]);return {Goretusk={14,15,0}} end},
 QuestXP={GetQuestLogRewardXP=function(self,id,ignore)
   queries[#queries+1]={id=id,ignore=ignore};return 900 end},
 QuestieLib={GetColoredQuestName=function(self,id,showLevel,showState)
   return '|cffffff00'..(showLevel and '['..quests[id].level..'] ' or '')..quests[id].name..'|r' end}}}
local registry=QuestieLoader._modules.QuestieMap.questIdFrames
Polestar.Compat.MapToWorld=function(map,x,y) return 0,1000-y*10,1000-x*10 end
local parent=CreateFrame('Frame');parent:SetSize(1000,1000);parent:Show()
local layer=L.Create(parent)
local map={art=true,bounds={c=0,left=1000,top=1000,kx=-.001,ky=-.001},
 View={width=1000,height=1000,offsetX=0,offsetY=0,drawWidth=1000,drawHeight=1000,scale=1}}
local function pin(id)
 local name='QuestieShiftTest'..id
 local frame=CreateFrame('Button',name)
 frame.UiMapID,frame.x,frame.y,frame.miniMapIcon=1436,50,50,true
 frame.data={Id=id,Type='item',Icon=7,Name='Goretusk',ObjectiveIndex=1,QuestData=quests[id],
   ObjectiveData={Description=id==38 and 'Goretusk Snout' or 'Goretusk Liver',Collected=0,Needed=id==38 and 3 or 8}}
 frame.data.ObjectiveData.Update=function() error('must not update Questie source objectives') end
 frame.texture=frame:CreateTexture();frame.texture:SetTexture('questie-loot');frame.texture:SetVertexColor(1,1,1,1)
 frame:SetScript('OnEnter',function() error('must not invoke Questie source hover handlers') end)
 registry[id]={[name]=name};return frame
end
`;
function run(script) {
  return runAddon({stubs:['stub_ui.lua'],addons:[{name:'Polestar',files:['Core/Core.xml','UI/LiveQuestie.lua']}],script:setup+script}).emitted;
}
const words = value => JSON.stringify(value);

test('Questie spawn hover groups quests and Shift expands in place to quest XP and creature levels', () => {
  const [out] = run(`
    local a,b=pin(38),pin(22);layer:Refresh(map)
    local marker=layer.Markers[1];marker:GetScript('OnEnter')(marker)
    local normal=tip
    shifted=true;stub.fire('MODIFIER_STATE_CHANGED','LSHIFT',1)
    local expanded=tip
    shifted=false;stub.fire('MODIFIER_STATE_CHANGED','LSHIFT',0)
    emit({normal=normal,expanded=expanded,collapsed=tip,paints=paints,queries=queries,
      sourceUntouched=a.data.touchedPins==nil and b.data.touchedPins==nil,
      sameOwner=GameTooltip:GetOwner()==marker})`);
  for (const text of ['Westfall Stew', 'Goretusk Liver Pie', '0/3 Goretusk Snout', '0/8 Goretusk Liver']) {
    assert.match(words(out.normal), new RegExp(text));
    assert.match(words(out.expanded), new RegExp(text));
  }
  assert.doesNotMatch(words(out.normal), /900|14-15/);
  assert.match(words(out.expanded), /900.*xp/);
  assert.match(words(out.expanded), /Goretusk.*14-15/);
  assert.doesNotMatch(words(out.collapsed), /900|14-15/);
  assert.ok(out.paints >= 3);
  assert.ok(out.queries.every(q => [22,38].includes(q.id) && q.ignore === true));
  assert.equal(out.sourceUntouched, true);
  assert.equal(out.sameOwner, true);
});

test('guide giver pins expand quest rewards and descriptions while stationary, with no stale tooltip after hiding', () => {
  const [out] = run(`
    local marker=CreateFrame('Button',nil,parent)
    local goal={t='accept',quest=38,title='Westfall Stew',npcName='Salma Saldean',qlvl=13}
    L.ShowGuideTooltip(marker,goal)
    local normal=tip
    shifted=true;stub.fire('MODIFIER_STATE_CHANGED','RSHIFT',1)
    local expanded=tip;local before=paints
    marker:Hide();GameTooltip:Hide()
    shifted=false;stub.fire('MODIFIER_STATE_CHANGED','RSHIFT',0)
    emit({normal=normal,expanded=expanded,paintedAfterHide=paints~=before})`);
  assert.match(words(out.normal), /Salma Saldean|Westfall Stew/);
  assert.doesNotMatch(words(out.normal), /900/);
  assert.match(words(out.expanded), /900.*xp/);
  assert.match(words(out.expanded), /Bring the stew ingredients to Salma/);
  assert.equal(out.paintedAfterHide, false);
  assert.match(out.normal.title, /Hold Shift/, 'the giver advertises its expanded hover detail');
  assert.doesNotMatch(out.expanded.title, /Hold Shift/);
});

test('missing or incompatible Questie detail APIs retain useful progress without invented XP or errors', () => {
  const [out] = run(`
    pin(38);QuestieLoader._modules.QuestXP.GetQuestLogRewardXP=function() error('not ready') end
    QuestieLoader._modules.QuestieDB.GetCreatureLevels=function() error('not ready') end
    shifted=true;layer:Refresh(map)
    local marker=layer.Markers[1];marker:GetScript('OnEnter')(marker)
    emit(tip)`);
  assert.match(words(out), /Westfall Stew/);
  assert.match(words(out), /0\/3 Goretusk Snout/);
  assert.doesNotMatch(words(out), /900|14-15/);
});

test('a removed spawn cannot reopen its tooltip on a modifier event', () => {
  const [out] = run(`
    local source=pin(38);layer:Refresh(map)
    local marker=layer.Markers[1];marker:GetScript('OnEnter')(marker)
    source.hidden=true;stub.fire('QUEST_LOG_UPDATE');stub.advance(.51);layer:Refresh(map)
    local before=paints
    shifted=true;stub.fire('MODIFIER_STATE_CHANGED','LSHIFT',1)
    emit({shown=GameTooltip:IsShown(),paintedAfterRemoval=paints~=before})`);
  assert.equal(out.shown, false);
  assert.equal(out.paintedAfterRemoval, false);
});

test('Shift giver descriptions accept Questie string tables and retain merged quest rewards', () => {
  const [out] = run(`
    quests[38].Description={'Bring the stew ingredients to Salma.','Keep the supplies for the next visit.',false,123}
    shifted=true
    local title,lines=L.GuideTooltip({npcName='Salma Saldean',entries={{t='accept',quest=38}},
      questieEntries={{kind='turnin',quest=22}}})
    emit({title=title,lines=lines})`);
  for (const expected of ['Bring the stew ingredients to Salma.', 'Keep the supplies for the next visit.', 'Bring eight Goretusk Livers.', 'Westfall Stew', 'Goretusk Liver Pie']) {
    assert.ok(words(out).includes(expected), expected);
  }
  assert.equal(out.lines.filter(line => typeof line === 'object' && /900.*xp/.test(line.right)).length, 2);
  assert.doesNotMatch(words(out), /123|Hold Shift/);
});

test('spawn quest headings appear once, with first Shift XP in the title and grouped progress underneath', () => {
  const [out] = run(`
    pin(38);layer:Refresh(map)
    local marker=layer.Markers[1];marker:GetScript('OnEnter')(marker)
    local normal=tip
    shifted=true;stub.fire('MODIFIER_STATE_CHANGED','LSHIFT',1)
    local single=tip
    pin(22);stub.fire('QUEST_LOG_UPDATE');stub.advance(.51);layer:Refresh(map)
    emit({normal=normal,single=single,multi=tip})`);
  assert.match(out.normal.title, /Westfall Stew.*Hold Shift/);
  assert.match(out.single.title, /Westfall Stew.*\|cffffff00\(900xp\)\|r/);
  for (const mode of ['single', 'multi']) {
    assert.equal((words(out[mode]).match(/Westfall Stew/g) || []).length, 1);
    assert.doesNotMatch(words(out[mode]), /Quest objectives/);
    assert.match(words(out[mode]), /0\/3 Goretusk Snout/);
  }
  assert.equal((words(out.multi).match(/Goretusk Liver Pie/g) || []).length, 1);
  assert.match(words(out.multi), /0\/8 Goretusk Liver/);
});

test('repooling a guide marker prevents a modifier event from repainting its old quest', () => {
  const [out] = run(`
    local marker=CreateFrame('Button',nil,parent)
    local first={t='accept',quest=38,npcName='Salma Saldean'}
    marker.objective=first;L.ShowGuideTooltip(marker,first)
    marker.objective={t='accept',quest=22,npcName='Salma Saldean'}
    local before=paints
    shifted=true;stub.fire('MODIFIER_STATE_CHANGED','LSHIFT',1)
    emit({changed=paints~=before,queries=#queries})`);
  assert.equal(out.changed, false);
  assert.equal(out.queries, 0);
});
