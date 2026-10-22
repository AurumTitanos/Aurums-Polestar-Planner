'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

const fixture = `
uistub.install(); stub.login()
local L = PolestarPlanner.LiveQuestie
local calls = { world = 0, tooltip = 0 }
Polestar.Compat.MapToWorld = function(map, x, y)
  calls.world = calls.world + 1
  return map == 1438 and 1 or 0, 1000-y*10, 1000-x*10
end
local tip
PolestarPlanner.Widgets = {
  Tooltip = function(_, _, title, lines) calls.tooltip=calls.tooltip+1; tip={title=title,lines=lines} end,
  HideTip = function() end,
}
local parent=CreateFrame('Frame'); parent:SetSize(1000,1000); parent:Show()
local layer=L.Create(parent)
local map={art=true,bounds={c=1,left=1000,top=1000,kx=-.001,ky=-.001},
  View={width=1000,height=1000,offsetX=0,offsetY=0,drawWidth=1000,drawHeight=1000,scale=1}}
local frames={}
local quest={name="Zenn's Bidding"}
local objective={Description='Nightsaber Fang',Collected=1,Needed=3,Completed=false}
QuestieLoader={_modules={QuestieMap={questIdFrames={}}, QuestLogCache={TryGetQuest=function(id)
  return {title="Zenn's Bidding",objectives={{text='1/3 Nightsaber Fang'}}}
end}}}
local registry=QuestieLoader._modules.QuestieMap.questIdFrames
local function pin(name, x, y, mini, obj, id)
  local frame=CreateFrame('Button',name)
  frame.data={Id=id or 488,Type='item',Icon=7,Name='Nightsaber',ObjectiveIndex=1,
    QuestData=quest,ObjectiveData=obj or objective}
  frame.UiMapID,frame.x,frame.y,frame.miniMapIcon=1438,x,y,mini
  frame.texture=frame:CreateTexture(); frame.texture:SetTexture('Interface/Questie/loot.blp')
  frame.texture:SetVertexColor(mini and .2 or .7,.8,.3,mini and .2 or 1)
  frame.texture.GetTexCoord=function() return 0,0,0,1,1,0,1,1 end
  frame:Hide() -- world-map visibility must not decide whether our copy appears
  frame.ShouldBeHidden=function() error('adapter must not invoke Questie behaviour') end
  frame.SetPoint=function() error('adapter must not move Questie frames') end
  frame.Show=function() error('adapter must not show Questie frames') end
  local qid=frame.data.Id
  registry[qid]=registry[qid] or {}; registry[qid][name]=name
  frames[#frames+1]=frame
  return frame
end
`;
function run(script) {
  return runAddon({ stubs: ['stub_ui.lua'], addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'UI/LiveQuestie.lua'] }], script: fixture + script }).emitted;
}

test('Questie world and minimap copies become one correctly projected spawn with original icon and hover details', () => {
  const [s] = run(`
    local a=pin('QuestieTest1',60,40,false)
    local b=pin('QuestieTest2',60,40,true)
    layer:Refresh(map)
    local m=layer.Markers[1]; m:GetScript('OnEnter')(m)
    emit({count=layer.markerCount,scene=#layer.scene,position={point=m.points[1].relPoint,x=m.points[1].x,y=m.points[1].y},icon=m.Icon:GetTexture(),
      color=m.Icon.vertexColor,uv=m.Icon.texCoord,tip=tip,sourceShown=a:IsShown(),sourceHidden=b:IsShown()})
  `);
  assert.equal(s.count, 1);
  assert.equal(s.scene, 1);
  assert.equal(s.position.point, 'TOPLEFT');
  assert.equal(s.position.x, 600);
  assert.equal(s.position.y, -400);
  assert.equal(s.icon, 'Interface/Questie/loot.blp');
  assert.deepEqual(s.color, [.2, .8, .3, 1]);
  assert.deepEqual(s.uv, [0, 0, 0, 1, 1, 0, 1, 1]);
  assert.equal(s.tip.title, 'Nightsaber');
  assert.ok(s.tip.lines.includes("Zenn's Bidding"));
  assert.ok(s.tip.lines.includes('1/3 Nightsaber Fang'));
  assert.equal(s.sourceShown, false);
  assert.equal(s.sourceHidden, false);
});

test('minimap objective halo survives a closed world map and uses live objective color independently of icon tint', () => {
  const [a, b, c, d] = run(`
    Questie={db={profile={alwaysGlowMinimap=true,alwaysGlowMap=false,questMinimapObjectiveColors=false}},
      icons={glow='Interface/AddOns/Questie/Icons/glow.blp'}}
    local source=pin('coloredWorldOnly',60,40,false)
    source.data.IconColor={.1,.2,.3}; objective.Color={.8,.3,.1}
    source.glowTexture=source:CreateTexture(); source.glowTexture:SetTexture(Questie.icons.glow)
    source.glowTexture:SetVertexColor(.9,.9,.9,0); source.glowTexture:Hide()
    layer:Refresh(map)
    local m=layer.Markers[1]
    emit({glow=m.Glow:IsShown(),color=m.Glow.vertexColor,icon=m.Icon.vertexColor,
      texture=m.Glow:GetTexture(),width=m.Glow:GetWidth(),sourceGlow=source.glowTexture:IsShown(),sourceColor=source.glowTexture.vertexColor})
    objective.Color={.2,.7,.4}; Questie.db.profile.questMinimapObjectiveColors=true
    stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({glow=m.Glow:IsShown(),color=m.Glow.vertexColor,icon=m.Icon.vertexColor})
    Questie.db.profile.alwaysGlowMinimap=false
    stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({glow=m.Glow:IsShown(),icon=m.Icon.vertexColor})
    Questie.db.profile.alwaysGlowMinimap=true; objective.Color=nil
    stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({glow=m.Glow:IsShown(),count=layer.markerCount})
  `);
  assert.equal(a.glow, true);
  assert.deepEqual(a.color, [.8, .3, .1, 1]);
  assert.deepEqual(a.icon, [1, 1, 1, 1]);
  assert.equal(a.texture, 'Interface/AddOns/Questie/Icons/glow.blp');
  assert.ok(Math.abs(a.width - 18 * 1.13) < 1e-9);
  assert.equal(a.sourceGlow, false);
  assert.deepEqual(a.sourceColor, [.9, .9, .9, 0]);
  assert.deepEqual(b, { glow: true, color: [.2, .7, .4, 1], icon: [.1, .2, .3, 1] });
  assert.deepEqual(c, { glow: false, icon: [.1, .2, .3, 1] });
  assert.deepEqual(d, { glow: false, count: 1 });
});

test('coincident objective colors have a stable source and prefer the minimap style without distance fading', () => {
  const [s] = run(`
    Questie={db={profile={alwaysGlowMinimap=true}},icons={glow='Interface/AddOns/Questie/Icons/glow.blp'}}
    objective.Color={.2,.8,.4}
    local first=pin('firstColor',60,40,false)
    pin('firstMiniColor',60,40,true)
    local second=pin('secondColor',60,40,true,{Description='Feather',Color={.9,.1,.4}})
    second.data.ObjectiveIndex=2
    layer:Refresh(map)
    local m=layer.Markers[1]
    emit({count=layer.markerCount,color=m.Glow.vertexColor,icon=m.Icon.vertexColor,entries=#m.spawn.entries})
  `);
  assert.deepEqual(s, {count: 1, color: [.2, .8, .4, 1], icon: [.2, .8, .3, 1], entries: 2});
});

test('logical Questie hiding, completed objectives and removed pins are excluded while quest giver pins remain visible', () => {
  const [a, b] = run(`
    pin('active',60,40,false)
    local hidden=pin('hidden',61,40,false); hidden.hidden=true
    local done=pin('done',62,40,false,{Description='Owl Feather',Collected=3,Needed=3,Completed=true})
    local hiddenObjective=pin('hiddenObjective',63,40,false,{HideIcons=true})
    local available=pin('available',64,40,false); available.data.Type='available'
    local recycled=pin('recycled',65,40,false); recycled.data=nil
    layer:Refresh(map); emit({count=layer.markerCount,scene=#layer.scene})
    objective.Completed=true; stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({count=layer.markerCount,shown=layer.Markers[1]:IsShown(),status=layer:GetStatus()})
  `);
  assert.deepEqual(a, { count: 2, scene: 2 });
  assert.equal(b.count, 1);
  assert.equal(b.shown, true);
  assert.equal(b.status, 'Questie quest and objective pins');
});

test('refresh is throttled, coordinate cache follows recycled frames, and disabled or hidden layer does no scanning', () => {
  const [a, b, c, d] = run(`
    local pin=pin('active',60,40,false)
    layer:Refresh(map); layer:Refresh(map)
    emit({scans=layer.scanCount,world=calls.world})
    stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({scans=layer.scanCount,world=calls.world})
    pin.x=70; stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({scans=layer.scanCount,world=calls.world,x=layer.Markers[1].points[1].x})
    layer:SetEnabled(false); stub.advance(2); layer:Refresh(map)
    layer:SetEnabled(true); parent:Hide(); layer:Refresh(map)
    emit({scans=layer.scanCount,world=calls.world,shown=layer.Markers[1]:IsShown()})
  `);
  assert.deepEqual(a, { scans: 1, world: 1 });
  assert.deepEqual(b, { scans: 2, world: 1 });
  assert.deepEqual(c, { scans: 3, world: 2, x: 700 });
  assert.deepEqual(d, { scans: 3, world: 2, shown: false });
});

test('coincident spawns merge distinct mobs and objective tooltips without duplicate world/minimap entries', () => {
  const [s] = run(`
    pin('first',60,40,false)
    pin('firstMini',60,40,true)
    local second=pin('second',60,40,false,{Description='Strigid Owl Feather',Collected=2,Needed=3})
    second.data.Name='Strigid Owl'; second.data.ObjectiveIndex=2
    layer:Refresh(map)
    local m=layer.Markers[1]; m:GetScript('OnEnter')(m)
    emit({count=layer.markerCount,entries=#layer.scene[1].entries,tip=tip})
  `);
  assert.equal(s.count, 1);
  assert.equal(s.entries, 2);
  assert.equal(s.tip.title, 'Questie spawns');
  assert.ok(s.tip.lines.includes('Nightsaber'));
  assert.ok(s.tip.lines.includes('Strigid Owl'));
  assert.ok(s.tip.lines.includes('Strigid Owl Feather  2/3'));
});

test('absent or not-yet-ready Questie remains optional and recovers once its pins appear', () => {
  const [a, b, c] = run(`
    local original=QuestieLoader; QuestieLoader=nil
    layer:Refresh(map); emit({status=layer:GetStatus(),count=layer.markerCount})
    QuestieLoader={_modules={}}; stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({status=layer:GetStatus(),count=layer.markerCount})
    QuestieLoader=original; pin('ready',60,40,false); stub.fire('QUEST_LOG_UPDATE');stub.advance(.51); layer:Refresh(map)
    emit({available=layer.available,status=layer:GetStatus(),count=layer.markerCount})
  `);
  assert.equal(a.status, 'Questie not loaded');
  assert.equal(a.count, 0);
  assert.equal(b.status, 'Questie pins not ready');
  assert.equal(c.available, true);
  assert.equal(c.count, 1);
});

test('invalid coordinates, other continents and edge-spilling icons are clipped and frame pooling stays bounded', () => {
  const [s] = run(`
    pin('bad',0/0,40,false)
    pin('edge',0,40,false)
    local elsewhere=pin('elsewhere',50,50,false); elsewhere.UiMapID=1429
    for i=1,700 do pin('many'..i,10+i*.1,50,false) end
    layer:Refresh(map);for i=1,400 do if not L.GetPerformance().pending then break end;stub.advance(.001) end;layer:Refresh(map)
    emit({count=layer.markerCount,pool=#layer.Markers,truncated=layer.displayTruncated})
  `);
  assert.equal(s.count, 600);
  assert.equal(s.pool, 600);
  assert.equal(s.truncated, true);
});

test('guide quest markers use Questie art and NPC-first live completion details without invoking source scripts', () => {
  const [ready, incomplete, available] = run(`
    Questie={ICON_TYPE_AVAILABLE=6,ICON_TYPE_COMPLETE=8,ICON_TYPE_INCOMPLETE=12,
      usedIcons={[6]='available-art',[8]='complete-art',[12]='incomplete-art'}}
    local done=true
    C_QuestLog={ReadyForTurnIn=function() return false end, IsComplete=function() return done end,
      GetTitleForQuestID=function() return 'A Bundle of Trouble' end,
      GetQuestObjectives=function() return {{text='6/8 Bundle of Wood',numFulfilled=6,numRequired=8}} end}
    QuestieLoader._modules.QuestLogCache.TryGetQuest=function() return nil end
    local goal={t='turnin',quest=5545,qlvl=9,title='A Bundle of Trouble',npcName='Supervisor Raelen'}
    local source=pin('giverNoMutations',60,40,true); source.data.Type='complete';source.data.ObjectiveData=nil
    source:GetScript('OnEnter') -- no handler is ever called
    source.data.touchedPins=nil
    local marker=CreateFrame('Button');marker.Icon=marker:CreateTexture()
    L.PaintGuideMarker(marker,goal);L.ShowGuideTooltip(marker,goal)
    emit({icon=marker.Icon:GetTexture(),tip=tip,touched=source.data.touchedPins,objectiveIndex=source.data.ObjectiveIndex})
    done=false;L.PaintGuideMarker(marker,goal);L.ShowGuideTooltip(marker,goal)
    emit({icon=marker.Icon:GetTexture(),tip=tip})
    goal.t='accept';L.PaintGuideMarker(marker,goal);L.ShowGuideTooltip(marker,goal)
    emit({icon=marker.Icon:GetTexture(),tip=tip})
  `);
  assert.equal(ready.icon, 'complete-art');
  assert.match(ready.tip.title, /Supervisor Raelen/);
  assert.match(ready.tip.lines[0], /\[9\] A Bundle of Trouble \(Complete\)/);
  assert.equal(ready.touched, undefined);
  assert.equal(ready.objectiveIndex, 1);
  assert.equal(incomplete.icon, 'incomplete-art');
  assert.match(incomplete.tip.lines[0], /\(Incomplete\)/);
  assert.ok(incomplete.tip.lines.includes('6/8 Bundle of Wood'));
  assert.equal(available.icon, 'available-art');
  assert.match(available.tip.lines[0], /\(Available\)/);
});

test('native fallback quest art and object hover stay useful without Questie and reject secret metadata', () => {
  const [ready, secret] = run(`
    Questie,QuestieLoader=nil,nil
    C_QuestLog={ReadyForTurnIn=function() return true end}
    local goal={t='turnin',quest=37,title='Find the Lost Guards',qlvl=10,objName='A half-eaten body'}
    local a=L.GuideAppearance(goal);local title,lines=L.GuideTooltip(goal)
    emit({icon=a.icon,title=title,lines=lines})
    local secret={};Polestar.Compat.IsSecret=function(v) return v==secret end
    goal.objName=secret;goal.title=secret;goal.qlvl=secret
    C_QuestLog={ReadyForTurnIn=function() return secret end,GetTitleForQuestID=function() return secret end,
      GetQuestObjectives=function() return {{text=secret}} end}
    a=L.GuideAppearance(goal);title,lines=L.GuideTooltip(goal,'Quest target')
    emit({icon=a.icon,title=title,lines=lines})
  `);
  assert.match(ready.icon, /GossipFrame\\ActiveQuestIcon$/);
  assert.match(ready.title, /A half-eaten body/);
  assert.match(ready.lines[0], /\[10\] Find the Lost Guards \(Complete\)/);
  assert.match(secret.title, /Quest target/);
  assert.equal(secret.lines.length, 1);
  assert.doesNotMatch(secret.lines.join('\n'), /table:|secret/);
});

test('co-located guide and Questie quest givers share one pin and retain every quest in its hover', () => {
  const [out] = run(`
    QuestieLoader._modules.QuestLogCache.TryGetQuest=function() return nil end
    C_QuestLog={ReadyForTurnIn=function(id) return id==5545 end}
    local first=pin('firstGiver',60,40,false,nil,5545)
    first.data={Id=5545,Type='complete',Name='Supervisor Raelen',QuestData={name='A Bundle of Trouble',level=9}}
    local second=pin('secondGiver',60,40,true,nil,123)
    second.data={Id=123,Type='available',Name='Supervisor Raelen',QuestData={name='Next quest',level=10}}
    local authored={c=1,wx=600,wy=400,quest=5545,kind='turnin',npcName='Supervisor Raelen',title='A Bundle of Trouble'}
    map.Objectives={enabled=true,showMarkers=true,scene={markers={authored}}}
    layer:Refresh(map)
    local title,lines=L.GuideTooltip(authored)
    emit({count=layer.markerCount,title=title,lines=lines,sourceFirst=first:IsShown(),sourceSecond=second:IsShown()})
  `);
  assert.equal(out.count, 0);
  assert.match(out.title, /Supervisor Raelen/);
  assert.equal(out.lines.length, 2);
  assert.match(out.lines[0], /A Bundle of Trouble \(Complete\)/);
  assert.match(out.lines[1], /\[10\] Next quest \(Available\)/);
  assert.equal(out.sourceFirst, false);
  assert.equal(out.sourceSecond, false);
});

test('available quest hovers do not request objectives and plain navigation never requests quest data', () => {
  const [out] = run(`
    local reads=0
    C_QuestLog={GetQuestObjectives=function() reads=reads+1;error('not on this quest') end}
    QuestieLoader._modules.QuestLogCache.TryGetQuest=function() return nil end
    local title,lines=L.GuideTooltip({t='accept',quest=123,title='Next quest',npcName='Quest giver'})
    for i=1,30 do L.QuestReady({t='goto'});L.GuideAppearance({t='goto'}) end
    emit({reads=reads,title=title,lines=lines})
  `);
  assert.equal(out.reads,0);
  assert.match(out.title,/Quest giver/);
  assert.equal(out.lines.length,1);
  assert.match(out.lines[0],/Next quest \(Available\)/);
});

test('a stale Questie completion cache cannot override live incomplete state', () => {
  const [out] = run(`
    QuestieLoader._modules.QuestLogCache.TryGetQuest=function() return {title='A Bundle of Trouble',isComplete=1} end
    C_QuestLog={ReadyForTurnIn=function() return false end,IsComplete=function() return false end}
    local a=L.GuideAppearance({t='turnin',quest=5545})
    local title,lines=L.GuideTooltip({t='turnin',quest=5545,npcName='Supervisor Raelen'})
    emit({ready=a.ready,lines=lines})
  `);
  assert.equal(out.ready,false);
  assert.match(out.lines[0],/\(Incomplete\)/);
});

test('a held Questie hover stays visible and refreshes progress across scans, then clears on removal', () => {
  const [updated, removed] = run(`
    GameTooltip.GetOwner=function(self) return self.owner end
    PolestarPlanner.Widgets.Tooltip=function(owner,anchor,title,lines)
      GameTooltip:SetOwner(owner,anchor);GameTooltip:SetText(title)
      for _,line in ipairs(lines) do GameTooltip:AddLine(line) end
      GameTooltip:Show()
    end
    PolestarPlanner.Widgets.HideTip=function(owner) if GameTooltip:GetOwner()==owner then GameTooltip:Hide() end end
    local cur=1
    QuestieLoader._modules.QuestLogCache.TryGetQuest=function()
      return {title="Zenn's Bidding",objectives={{text=cur..'/3 Nightsaber Fang'}}}
    end
    pin('heldHover',60,40,false);layer:Refresh(map)
    local marker=layer.Markers[1];marker:GetScript('OnEnter')(marker)
    cur=2;stub.fire('QUEST_LOG_UPDATE');stub.advance(.51);layer:Refresh(map)
    emit({shown=GameTooltip:IsShown(),owner=GameTooltip:GetOwner()==marker,lines=GameTooltip.lines})
    registry[488]={};stub.fire('QUEST_LOG_UPDATE');stub.advance(.51);layer:Refresh(map)
    emit({shown=GameTooltip:IsShown(),spawn=marker.spawn})
  `);
  assert.equal(updated.shown,true);assert.equal(updated.owner,true);
  assert.ok(updated.lines.includes('2/3 Nightsaber Fang'));
  assert.equal(removed.shown,false);assert.equal(removed.spawn,undefined);
});

test('authored complete objectives keep their own art while external Questie complete means hand-in', () => {
  const [out] = run(`
    C_QuestLog={ReadyForTurnIn=function() return true end}
    local marker=CreateFrame('Button');marker.Icon=marker:CreateTexture();marker.Icon:SetTexture('objective-art')
    local authored=L.PaintGuideMarker(marker,{t='complete',quest=5545,title='A Bundle of Trouble'})
    local icon=marker.Icon:GetTexture()
    local markerKind=L.GuideAppearance({kind='complete',quest=5545})
    local external=L.GuideAppearance({Type='complete',Id=5545})
    emit({authored=authored,icon=icon,markerKind=markerKind,external=external.icon})
  `);
  assert.equal(out.authored,false);
  assert.equal(out.icon,'objective-art');
  assert.equal(out.markerKind,undefined);
  assert.match(out.external,/GossipFrame\\ActiveQuestIcon$/);
});

test('unknown quest levels fall back to positive guide metadata and never render zero or negative levels', () => {
  const [zero, negative, absent, indexed] = run(`
    QuestieLoader._modules.QuestLogCache.TryGetQuest=function() return nil end
    local level=0
    C_QuestLog={GetQuestDifficultyLevel=function() return level end}
    local goal={t='accept',quest=5545,title='A Bundle of Trouble',qlvl=9,npcName='Supervisor Raelen'}
    local _,lines=L.GuideTooltip(goal);emit(lines)
    level=-1;_,lines=L.GuideTooltip(goal);emit(lines)
    goal.qlvl=0;_,lines=L.GuideTooltip(goal);emit(lines)
    Polestar.Engine={GetGuide=function() return {steps={{goals={{quest=5545,qlvl=0},{quest=5545,qlvl=9}}}}} end}
    _,lines=L.GuideTooltip(goal);emit(lines)
  `);
  assert.match(zero[0],/\[9\]/);
  assert.match(negative[0],/\[9\]/);
  assert.doesNotMatch(absent[0],/\[-?\d+\]/);
  assert.match(indexed[0],/\[9\]/);
});
