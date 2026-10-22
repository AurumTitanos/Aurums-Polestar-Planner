'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

const fixture = `
uistub.install()
stub.login()
local reads = { quests = 0, items = 0 }
local secret = {}
Polestar.Compat.IsSecret = function(v) return v == secret end
local quests = {
  { isHeader = true, title = "Teldrassil" },
  { isHeader = false, questID = 488, title = "Zenn's Bidding" },
  { isHeader = false, questID = 929, title = "Crown of the Earth" },
}
local cur = 1
C_QuestLog = {
  GetNumQuestLogEntries = function() reads.quests = reads.quests + 1; return #quests, 2 end,
  GetMaxNumQuestsCanAccept = function() return 20 end,
  GetInfo = function(i) return quests[i] end,
  ReadyForTurnIn = function(id) return id == 929 end,
  GetQuestObjectives = function(id) return {{ text = "Nightsaber Fang", numFulfilled = cur, numRequired = 3, finished = cur == 3 }} end,
}
local bags = { { itemID = 3409, stackCount = 2 }, { itemID = 3409, stackCount = 1 }, { itemID = 117, stackCount = 4 } }
C_Container = {
  GetContainerNumSlots = function(bag) reads.items = reads.items + 1; return bag == 0 and #bags or 0 end,
  GetContainerItemInfo = function(_, slot) return bags[slot] end,
}
C_Item = {
  GetItemInfoInstant = function(id) return id, "Type", "Subtype", "", 1, id == 3409 and 12 or 0 end,
  GetItemNameByID = function(id) return "Nightsaber Fang" end,
}
local remaining = 90
Polestar.QoL = { GetHearth = function() return { have = true, ready = remaining == 0, remaining = remaining, bind = "Dolanaar" } end }
UnitOnTaxi = function() return false end
IsFlying = function() return false end
IsMounted = function() return false end
IsSwimming = function() return false end
local LC = PolestarPlanner.LiveCharacter
`;
function run(script) {
  return runAddon({ stubs: ['stub_ui.lua'], addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'UI/LiveCharacter.lua'] }], script: fixture + script }).emitted;
}

test('character panel reads actual quest objectives, ready state, quest-item stacks and hearth cooldown', () => {
  const [s] = run('emit(LC.GetSnapshot())');
  assert.equal(s.questCount, 2);
  assert.equal(s.questMax, 20);
  assert.equal(s.questLogAvailable, true);
  assert.equal(s.quests.length, 2);
  assert.equal(s.quests[0].title, "Zenn's Bidding");
  assert.equal(s.quests[0].ready, false);
  assert.equal(s.quests[1].ready, true);
  assert.deepEqual(s.quests[0].objectives[0], { text: 'Nightsaber Fang', cur: 1, max: 3, finished: false });
  assert.deepEqual(s.items, [{ id: 3409, name: 'Nightsaber Fang', count: 3 }]);
  assert.equal(s.itemsAvailable, true);
  assert.deepEqual(s.hearth, { have: true, ready: false, remaining: 90, bind: 'Dolanaar' });
  assert.equal(s.travel, 'On foot');
  assert.equal(s.flightPaths, undefined, 'unknown flight paths are not invented');
});

test('quest and inventory scans are lazy, cached, and event-invalidated without background reads', () => {
  const [a, b, c, d] = run(`
    emit({q=reads.quests,i=reads.items})
    LC.GetSnapshot(); LC.GetSnapshot()
    emit({q=reads.quests,i=reads.items})
    cur=3; stub.fire("QUEST_LOG_UPDATE"); stub.fire("BAG_UPDATE_DELAYED"); stub.advance(5)
    emit({q=reads.quests,i=reads.items})
    local s=LC.GetSnapshot()
    emit({q=reads.quests,i=reads.items,cur=s.quests[1].objectives[1].cur})
  `);
  assert.deepEqual(a, { q: 0, i: 0 });
  assert.equal(b.q, 1);
  assert.equal(b.i, 5);
  assert.deepEqual(c, b, 'events alone do not scan while the viewer is closed');
  assert.deepEqual(d, { q: 2, i: 10, cur: 3 });
});

test('missing APIs show unknown rather than an empty log, empty bags or a ready hearthstone', () => {
  const [s] = run('C_QuestLog=nil; GetNumQuestLogEntries=nil; C_Container=nil; Polestar.QoL=nil; GetBindLocation=nil; IsMounted=nil; emit(LC.GetSnapshot())');
  assert.equal(s.questLogAvailable, false);
  assert.equal(s.questCount, undefined);
  assert.equal(s.itemsAvailable, false);
  assert.equal(s.hearth.ready, undefined);
  assert.equal(s.travel, 'Unavailable');
});

test('restricted API results are not compared or interpreted as empty data', () => {
  const [s] = run(`
    C_QuestLog.GetNumQuestLogEntries=function() return secret end
    C_Container.GetContainerItemInfo=function() return secret end
    Polestar.QoL.GetHearth=function() return {remaining=secret,ready=secret,bind=secret} end
    IsMounted=function() return secret end
    emit(LC.GetSnapshot())
  `);
  assert.equal(s.questLogAvailable, false);
  assert.equal(s.itemsAvailable, false);
  assert.equal(s.hearth.remaining, undefined);
  assert.equal(s.hearth.ready, undefined);
  assert.equal(s.travel, 'Unavailable');
});

test('travel and hearth refresh live while expensive quest scans stay cached', () => {
  const [s] = run(`
    LC.GetSnapshot(); remaining=0; IsMounted=function() return true end
    local s=LC.GetSnapshot(); emit({travel=s.travel,hearth=s.hearth,reads=reads.quests})
  `);
  assert.equal(s.travel, 'Mounted');
  assert.equal(s.hearth.ready, true);
  assert.equal(s.reads, 1);
});
