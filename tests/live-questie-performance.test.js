'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {runAddon} = require('./helpers/lua');

const fixture = `
uistub.install(); stub.login()
local L = PolestarPlanner.LiveQuestie
local reads={art=0,quest=0,xp=0,world=0}
Polestar.Compat.MapToWorld=function(map,x,y)
 reads.world=reads.world+1; return 1,1000-y*10,1000-x*10
end
local shift=false
function IsShiftKeyDown() return shift end
local registry,records,frames={},{},{}
QuestieLoader={_modules={
 QuestieMap={questIdFrames=registry},
 QuestieDB={GetQuest=function(id) reads.quest=reads.quest+1; return records[id] end},
 QuestXP={GetQuestLogRewardXP=function(_,id) reads.xp=reads.xp+1; return 900 end},
}}
Questie={db={profile={}}}
C_QuestLog={ReadyForTurnIn=function() return true end}
local function pin(i)
 local name='PerfGiver'..i
 local source=CreateFrame('Button',name)
 records[i]={name='Quest '..i,level=13,Description='Details '..i}
 source.data={Id=i,Type='complete',Name='Giver '..i,QuestData=records[i]}
 source.UiMapID,source.x,source.y=1438,10+i*.1,50
 source.texture={GetTexture=function() reads.art=reads.art+1; return 'quest-art' end}
 source:Hide()
 registry[i]={[name]=name}; frames[i]=source
end
for i=1,600 do pin(i) end
local a=CreateFrame('Frame');a:Show()
local b=CreateFrame('Frame');b:Show()
local one,two=L.Create(a),L.Create(b)
local function settle() for i=1,1000 do if not L.GetPerformance().pending then return end;stub.advance(.001) end;error('pin scan did not settle') end
local map={art=true,bounds={c=1,left=1000,top=1000,kx=-.001,ky=-.001},
 View={width=1000,height=1000,offsetX=0,offsetY=0,drawWidth=1000,drawHeight=1000,scale=1}}
`;
function run(script) {
 return runAddon({stubs:['stub_ui.lua'],script:fixture+script}).emitted;
}

test('600 giver pins build details only for the hovered pin, even while Shift is held',()=>{
 const [out] = run(`
  shift=true
  local started=os.clock();one:Refresh(map);settle();one:Refresh(map);two:Refresh(map)
  local idle={quest=reads.quest,xp=reads.xp,art=reads.art,seconds=os.clock()-started}
  local title,lines=L.SpawnTooltip(one.Markers[1].spawn)
  emit({idle=idle,hover={quest=reads.quest,xp=reads.xp,title=title,lines=lines},counts={one.markerCount,two.markerCount}})
 `);
 if(process.env.PLANNER_PROFILE) console.log(JSON.stringify(out));
 assert.deepEqual(out.counts,[600,600]);
 assert.equal(out.idle.quest,0,'drawing unhovered giver pins must not fetch rich quest details');
 assert.equal(out.idle.xp,0,'Shift alone must not request rewards for every pin');
 assert.ok(out.hover.quest>0 && out.hover.quest<=3);
 assert.equal(out.hover.xp,1);
 assert.ok(out.hover.lines.some(line=>typeof line==='object' && /900xp/.test(line.right)));
 assert.ok(out.hover.lines.some(line=>typeof line==='string' && /Details/.test(line)));
});

test('two maps share one bounded Questie scan and both receive refreshed source data',()=>{
 const [out] = run(`
  one:Refresh(map);settle();one:Refresh(map);two:Refresh(map)
  local first=reads.art
  map.View.offsetX=1;one:Refresh(map);settle();one:Refresh(map);two:Refresh(map)
  local pan=reads.art
  frames[1].x=80
  stub.fire('QUEST_LOG_UPDATE');stub.advance(.51);one:Refresh(map);settle();one:Refresh(map);two:Refresh(map)
  local refreshed=reads.art
  local x1,x2
  for _,p in ipairs(one.scene) do if p.entries[1].questID==1 then x1=p.x end end
  for _,p in ipairs(two.scene) do if p.entries[1].questID==1 then x2=p.x end end
  a:Hide();b:Hide();stub.advance(1);one:Refresh(map);settle();one:Refresh(map);two:Refresh(map)
  emit({first=first,pan=pan,refreshed=refreshed,hidden=reads.art,x1=x1,x2=x2})
 `);
 if(process.env.PLANNER_PROFILE) console.log(JSON.stringify(out));
 assert.equal(out.first,600);
 assert.equal(out.pan,600,'camera movement only projects the copied pins');
 assert.equal(out.refreshed,1200);
 assert.equal(out.hidden,1200);
 assert.equal(out.x1,80);assert.equal(out.x2,80);
});

test('a changed Questie registry never reuses another maps old pin snapshot',()=>{
 const [out] = run(`
  one:Refresh(map);settle();one:Refresh(map)
  QuestieLoader._modules.QuestieMap.questIdFrames={}
  two:Refresh(map)
  emit({first=one.markerCount,second=two.markerCount,status=two:GetStatus()})
 `);
 assert.equal(out.first,600);assert.equal(out.second,0);
 assert.equal(out.status,'No active Questie spawn pins');
});

test('stationary safety scans preserve pin frames and each scan slice reads only a bounded batch',()=>{
 const [out]=run(`
  one:Refresh(map);local firstSlice=reads.art;settle();one:Refresh(map)
  local scene,paints,scans=one.scene,one.paints,one.scanCount
  stub.advance(5.1);local before=reads.art;one:Refresh(map);local fallbackSlice=reads.art-before
  settle();one:Refresh(map)
  local stable=scene==one.scene and paints==one.paints
  frames[1].data.Name='Updated giver';stub.fire('QUEST_LOG_UPDATE');one:Refresh(map);settle();one:Refresh(map)
  emit({firstSlice=firstSlice,fallbackSlice=fallbackSlice,stable=stable,scans=one.scanCount-scans,updated=one.scene~=scene})
 `);
 assert.ok(out.firstSlice>0&&out.firstSlice<=16);
 assert.ok(out.fallbackSlice>0&&out.fallbackSlice<=16);
 assert.equal(out.stable,true,'idle scans must not retexture/reposition unchanged pins');
 assert.equal(out.scans,2);assert.equal(out.updated,true);
});

test('hiding the only consumer cancels an unfinished scan and reopening recovers',()=>{
 const [out]=run(`
  b:Hide();one:Refresh(map);a:Hide();local before=reads.art;stub.advance(1)
  local stopped=not L.GetPerformance().pending and reads.art==before
  a:Show();one:Refresh(map);settle();one:Refresh(map)
  emit({stopped=stopped,pins=one.markerCount})
 `);
 assert.equal(out.stopped,true);assert.equal(out.pins,600);
});

test('replacement registries interrupt an unfinished scan without publishing the old pins',()=>{
 const [out]=run(`
  one:Refresh(map);QuestieLoader._modules.QuestieMap.questIdFrames={};two:Refresh(map)
  settle();one:Refresh(map);two:Refresh(map)
  emit({first=one.markerCount,second=two.markerCount,pending=L.GetPerformance().pending})
 `);
 assert.deepEqual(out,{first:0,second:0,pending:false});
});

test('guide scene and marker toggles refresh giver deduplication without rescanning Questie',()=>{
 const [out]=run(`
  one:Refresh(map);settle();one:Refresh(map)
  local scene,art=one.scene,reads.art
  local function authored(id)
   local source=frames[id]
   return {c=1,wx=1000-source.y*10,wy=1000-source.x*10,
    quest=id,kind='turnin',npcName='Giver '..id}
  end
  local function state(guide)
   local shown={}
   for i=1,one.markerCount do
    for _,entry in ipairs(one.Markers[i].spawn.entries) do shown[entry.questID]=true end
   end
   return {count=one.markerCount,first=shown[1] or false,second=shown[2] or false,
    merged=guide.questieEntries and guide.questieEntries[1].quest or false}
  end
  local first,second=authored(1),authored(2)
  map.Objectives={enabled=true,showMarkers=true,scene={markers={first}}}
  one:Refresh(map);local initial=state(first)
  map.Objectives.scene={markers={second}}
  one:Refresh(map);local advanced=state(second)
  map.Objectives.showMarkers=false
  one:Refresh(map);local markersOff=state(second)
  map.Objectives.showMarkers=true
  one:Refresh(map);local markersOn=state(second)
  map.Objectives.enabled=false
  one:Refresh(map);local objectivesOff=state(second)
  map.Objectives.enabled=true
  one:Refresh(map);local objectivesOn=state(second)
  emit({initial=initial,advanced=advanced,markersOff=markersOff,markersOn=markersOn,
   objectivesOff=objectivesOff,objectivesOn=objectivesOn,sceneStable=scene==one.scene,artReads=reads.art-art})
 `);
 const secondMerged={count:599,first:true,second:false,merged:2};
 const allShown={count:600,first:true,second:true,merged:false};
 assert.deepEqual(out.initial,{count:599,first:false,second:true,merged:1});
 assert.deepEqual(out.advanced,secondMerged,'a new guide step must merge the current giver');
 assert.deepEqual(out.markersOff,allShown);
 assert.deepEqual(out.markersOn,secondMerged);
 assert.deepEqual(out.objectivesOff,allShown);
 assert.deepEqual(out.objectivesOn,secondMerged);
 assert.equal(out.sceneStable,true);
 assert.equal(out.artReads,0,'guide changes must reuse the existing Questie snapshot');
});

test('a nonempty replacement registry clears settled pins while its scan is pending',()=>{
 const [out]=run(`
  one:Refresh(map);settle();one:Refresh(map);two:Refresh(map)
  local initial={one.markerCount,two.markerCount}
  local replacement={}
  for id=201,240 do replacement[id]=registry[id] end
  QuestieLoader._modules.QuestieMap.questIdFrames=replacement
  one:Refresh(map);two:Refresh(map)
  local pending={job=L.GetPerformance().pending,first=one.markerCount,second=two.markerCount,
   firstScene=#one.scene,secondScene=#two.scene,available=one.available}
  settle();one:Refresh(map);two:Refresh(map)
  local onlyReplacement=true
  for _,layer in ipairs({one,two}) do
   for _,p in ipairs(layer.scene) do
    for _,entry in ipairs(p.entries) do
     if entry.questID<201 or entry.questID>240 then onlyReplacement=false end
    end
   end
  end
  emit({initial=initial,pending=pending,final={one.markerCount,two.markerCount},
   available=one.available and two.available,shared=one.scene==two.scene,onlyReplacement=onlyReplacement})
 `);
 assert.deepEqual(out.initial,[600,600]);
 assert.deepEqual(out.pending,{job:true,first:0,second:0,firstScene:0,secondScene:0,available:false});
 assert.deepEqual(out.final,[40,40]);
 assert.equal(out.available,true);assert.equal(out.shared,true);assert.equal(out.onlyReplacement,true);
});

test('a registry replaced between scan slices cannot publish before the next map refresh',()=>{
 const [out]=run(`
  one:Refresh(map);settle();one:Refresh(map);two:Refresh(map)
  local replacement,nextRegistry={},{}
  for id=201,240 do replacement[id]=registry[id] end
  for id=401,448 do nextRegistry[id]=registry[id] end
  QuestieLoader._modules.QuestieMap.questIdFrames=replacement
  one:Refresh(map)
  local started=L.GetPerformance().pending
  local published=L.GetPerformance().scans
  -- Advance only the worker: neither map has observed the second replacement.
  QuestieLoader._modules.QuestieMap.questIdFrames=nextRegistry
  settle()
  local rejected={scene=#one.scene,pins=one.markerCount,available=one.available,
   published=L.GetPerformance().scans-published,pending=L.GetPerformance().pending}
  one:Refresh(map);two:Refresh(map)
  local loading={one.markerCount,two.markerCount}
  settle();one:Refresh(map);two:Refresh(map)
  local onlyCurrent=true
  for _,layer in ipairs({one,two}) do
   for _,p in ipairs(layer.scene) do
    for _,entry in ipairs(p.entries) do
     if entry.questID<401 or entry.questID>448 then onlyCurrent=false end
    end
   end
  end
  emit({started=started,rejected=rejected,loading=loading,final={one.markerCount,two.markerCount},onlyCurrent=onlyCurrent})
 `);
 assert.equal(out.started,true);
 assert.deepEqual(out.rejected,{scene:0,pins:0,available:false,published:0,pending:false},
  'the worker must reject the captured registry without relying on Refresh to cancel it');
 assert.deepEqual(out.loading,[0,0]);
 assert.deepEqual(out.final,[48,48]);
 assert.equal(out.onlyCurrent,true);
});
