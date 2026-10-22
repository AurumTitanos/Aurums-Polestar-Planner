'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

function run(script) {
  return runAddon({
    stubs: ['stub_ui.lua', 'live-dashboard.lua'],
    addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'Theme/Theme.xml', 'Maps/RouteStrokes.lua', 'UI/UI.xml'] }],
    script: `
      uistub.install(); livestub.install(); stub.login(); uistub.setGuide(uistub.elwynn, 3)
      GameTooltip.GetOwner = function(self) return self.owner end
      local ready = true
      Polestar.Compat.IsQuestReadyForTurnIn = function(id) return id == 5545 and ready end
      Polestar.Compat.IsOnQuest = function(id) return id == 5545 end
      Questie = { ICON_TYPE_AVAILABLE=6, ICON_TYPE_COMPLETE=8, ICON_TYPE_INCOMPLETE=12,
        usedIcons={ [6]='Questie-available', [8]='Questie-complete', [12]='Questie-incomplete' } }
      local goal = {t='turnin', quest=5545, title='A Bundle of Trouble', qlvl=9,
        npc=10616, npcName='Supervisor Raelen', map=1429, x=44, y=39, status='active'}
      Polestar.Engine.GetGuide().steps[3].goals = {goal}
      uistub.target = {map=1429, x=44, y=39, kind='turnin', stepIndex=3, goalIndex=1, label='Turn in A Bundle of Trouble'}
      local map = PolestarPlanner.LiveMap.Create(UIParent)
      map.Viewport:SetSize(1000, 500)
      map:SetAreaStyle('off'); map:SetObjectives(false); map:Refresh(true)
      local marker = map.GoalMarker
      ${script}
    `,
  }).emitted;
}

test('the destination retains quest art and NPC hover details with the guide-objective layer hidden', () => {
  const [out] = run(`
    stub.RunScript(marker, 'OnEnter')
    emit({shown=marker:IsShown(), icon=marker.Icon:GetTexture(), tip=GameTooltip.lines})
  `);
  assert.equal(out.shown, true);
  assert.equal(out.icon, 'Questie-complete');
  assert.match(out.tip.join('\n'), /Supervisor Raelen/);
  assert.match(out.tip.join('\n'), /A Bundle of Trouble/);
  assert.match(out.tip.join('\n'), /Complete/);
});

test('quest state repaints the destination and switching to manual navigation clears quest styling', () => {
  const [incomplete, manual] = run(`
    stub.RunScript(marker, 'OnEnter')
    ready=false; map:Refresh(false)
    emit({icon=marker.Icon:GetTexture(),tip=GameTooltip.lines})
    uistub.target={map=1429,x=45,y=40,kind='manual',stepIndex=3,label='My waypoint'}
    map:Refresh(false)
    local dismissed=not GameTooltip:IsShown()
    stub.RunScript(marker, 'OnEnter')
    emit({icon=marker.Icon:GetTexture(),goal=marker.guideGoal,tip=GameTooltip.lines,dismissed=dismissed})
  `);
  assert.equal(incomplete.icon, 'Questie-incomplete');
  assert.doesNotMatch(incomplete.tip.join('\n'), /\(Complete\)/);
  assert.match(manual.icon, /Media\\Nav\\pin-fill$/);
  assert.equal(manual.goal, undefined);
  assert.equal(manual.dismissed, true);
  assert.match(manual.tip.join('\n'), /My waypoint/);
  assert.doesNotMatch(manual.tip.join('\n'), /Supervisor Raelen|A Bundle of Trouble/);
});
