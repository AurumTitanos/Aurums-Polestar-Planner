'use strict';

// Execute the actual addon modules against client APIs and a contract-faithful
// guide engine. These tests protect the dashboard's read-only relationship to
// guide progress; a browser simulation/checkpoint is deliberately absent.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

const FILES = ['Core/Core.xml', 'Theme/Theme.xml', 'Maps/RouteStrokes.lua', 'UI/UI.xml'];
function run(script, { before = '', setup = '' } = {}) {
	return runAddon({
		stubs: ['stub_ui.lua', 'live-dashboard.lua'],
		before,
		addons: [{ name: 'Polestar', files: FILES }],
		script: `uistub.install()\nlivestub.install()\n${setup}\nstub.login()\nuistub.setGuide(uistub.elwynn, 3)\nlocal D, M, S = PolestarPlanner.LiveDashboard, PolestarPlanner.LiveMap, livestub\n${script}`,
	}).emitted;
}

test('compact map paints a corpse target override and its supplied geometry without changing guide progress', () => {
	const [out] = runAddon({
		stubs: ['stub_ui.lua', 'live-dashboard.lua'],
		addons: [{ name: 'Polestar', files: [...FILES, 'Nav/Nav.lua'] }],
		script: `uistub.install({noNav=true}); livestub.install(); stub.login(); uistub.setGuide(uistub.elwynn,3)
			local Mini,N,C=PolestarPlanner.LiveMiniMap,Polestar.Nav,Polestar.Compat
			Mini.Show(); local m=Mini.GetFrame().Map; m.Viewport:SetSize(420,354)
			local c,wx,wy=C.MapToWorld(1429,60,45)
			local pc,px,py=C.GetPlayerWorldPosition()
			livestub.geometry={legs={{kind="walk",current=true,pts={{pc,px,py},{c,wx,wy}}}}}
			local accepted=N.SetTarget(1429,60,45,"Your corpse")
			m:Refresh(true)
			local active=0
			for _,marker in ipairs(m.Objectives.Markers) do if marker.objective and marker.objective.active then active=active+1 end end
			emit({accepted=accepted,override=N.IsOverride(),shown=m.GoalMarker:IsShown(),
				label=m.GoalMarker.targetLabel,strokes=m.strokes.n,activeGoals=active,
				step=Polestar.Engine.GetStepIndex(),map=m:GetMapID()})`,
	}).emitted;
	assert.equal(out.accepted, true);
	assert.equal(out.override, true);
	assert.equal(out.shown, true);
	assert.equal(out.label, 'Your corpse');
	assert.ok(out.strokes > 0);
	assert.equal(out.activeGoals, 0);
	assert.equal(out.step, 3);
	assert.equal(out.map, 1429);
});

test('compact and full maps have independent cameras with no close-in zoom cap', () => {
	const [out] = run(`
		local full, small = M.Create(UIParent), M.Create(UIParent, {compact=true})
		full.Viewport:SetSize(800,500); small.Viewport:SetSize(318,149)
		full:ApplyViewState({zoom=4,follow=true})
		small:ApplyViewState({zoom=90,follow=true}); small:ZoomIn()
		local zoomed=small:GetViewState().zoom
		small:ApplyViewState({mapID=1429,zoom=1,follow=false})
		small:ZoomOut()
		emit({zoomed=zoomed,fullZoom=full:GetViewState().zoom,fullMap=full:GetMapID(),
			parent=small:GetMapID(),statusHidden=not small.Status:IsShown(),hintHidden=not small.Hint:IsShown(),
			fullStatus=full.Status:IsShown()})
	`);
	assert.ok(out.zoomed > 100);
	assert.equal(out.fullZoom, 4);
	assert.equal(out.fullMap, 1429);
	assert.equal(out.parent, 1415);
	assert.equal(out.statusHidden, true);
	assert.equal(out.hintHidden, true);
	assert.equal(out.fullStatus, true);
});

test('corrupt camera magnification recovers instead of passing infinite geometry to frames', () => {
	const [out] = run(`
		local m=M.Create(UIParent, {compact=true}); m.Viewport:SetSize(400,300)
		m:ApplyViewState({zoom=1e308,follow=true})
		emit({zoom=m.zoom,width=m.View.drawWidth})
	`);
	assert.equal(out.zoom, 1);
	assert.ok(Number.isFinite(out.width));
});

test('small-map button, key binding and companion slash command reuse the compact window', () => {
	const [out] = run(`
		D.Show(); D.GetFrame().CompactButton:Click()
		local mini=PolestarPlanner.LiveMiniMap.GetFrame()
		local switched=mini:IsShown() and not D.GetFrame():IsShown()
		PolestarPlanner.Bindings.MiniMap()
		local toggled=not mini:IsShown()
		SlashCmdList.POLESTARPLANNER("minimap")
		emit({switched=switched,toggled=toggled,menu=mini:IsShown(),same=mini==PolestarPlanner.LiveMiniMap.GetFrame()})
	`);
	assert.deepEqual(out, {switched:true,toggled:true,menu:true,same:true});
});

test('Planner-style left column renders every upcoming action and count with variable-height rows', () => {
	const [out] = run(`
		local g = Polestar.Engine.GetGuide()
		g.steps[5].goals = {
			{t="accept",verb="Accept",subject="Future quest",subjectKind="quest",text="Accept Future quest"},
			{t="collect",verb="Collect",subject="Future item",subjectKind="item",progress={cur=0,max=8}},
			{t="turnin",verb="Turn in",subject="Future quest",subjectKind="quest"},
		}
		D.Show()
		local F, r = D.GetFrame(), D.GetFrame().Rows[5]
		local goals = {}
		for _, row in ipairs(r.Goals) do if row:IsShown() then goals[#goals+1]=row.Text:GetText() end end
		emit({goals=goals,state=r.State:GetText(),height=r:GetHeight(),nextTop=F.Rows[6].psTop,
			top=r.psTop,mapWidth=F.Map:GetWidth(),leftWidth=F.List:GetWidth(),rightWidth=F.Details:GetWidth(),width=F:GetWidth()})
	`);
	assert.equal(out.goals.length, 3);
	assert.match(out.goals[0], /Accept.*Future quest/);
	assert.match(out.goals[1], /Collect.*Future item.*0\/8/);
	assert.match(out.goals[2], /Turn in.*Future quest/);
	assert.notEqual(out.state, 'Upcoming');
	assert.ok(out.height > 46);
	assert.equal(out.nextTop, out.top + out.height, 'expanded rows never overlap the next step');
	assert.ok(out.mapWidth > out.leftWidth && out.mapWidth > out.rightWidth, 'terrain remains the largest column');
	assert.ok(out.leftWidth + out.mapWidth + out.rightWidth <= out.width);
});

test('native quest-log completion shows upcoming, missed and missing hand-ins without changing guide progress', () => {
	const [out] = run(`
		local g=Polestar.Engine.GetGuide()
		g.steps[2].goals={{t="turnin",quest=992,title="Earlier hand-in"}}
		g.steps[5].goals={{t="turnin",quest=991,title="Saved for later"}}
		g.next=nil; g.nextChoices=nil
		Polestar.Guides.Get=function(id) return id==g.id and g or nil end
		Polestar.Guides.List=function() return {g} end
		Polestar.Guides.Matches=uistub.realGuides.Matches
		Polestar.Guides.GuideMatches=uistub.realGuides.GuideMatches
		Polestar.RoutePlan.Invalidate()
		local quests={{questID=991,title="Saved for later",isHeader=false},
			{questID=992,title="Earlier hand-in",isHeader=false},{questID=993,title="Unplanned work",isHeader=false}}
		C_QuestLog=C_QuestLog or {}
		C_QuestLog.GetNumQuestLogEntries=function() return #quests,#quests end
		C_QuestLog.GetInfo=function(i) return quests[i] end
		C_QuestLog.ReadyForTurnIn=function() return true end
		C_QuestLog.GetQuestObjectives=function() return {} end
		C_QuestLog.GetMaxNumQuestsCanAccept=function() return 40 end
		stub.fire("QUEST_LOG_UPDATE")
		D.Show(); uistub.calls={}
		local initial=D.GetFrame().CharacterExtra:GetText()
		D.SelectStep(1)
		local preview=D.GetFrame().CharacterExtra:GetText()
		table.remove(quests,1); stub.fire("QUEST_TURNED_IN",991); D.Refresh(true)
		emit({initial=initial,preview=preview,removed=D.GetFrame().CharacterExtra:GetText(),
			step=Polestar.Engine.GetStepIndex(),calls=uistub.calls})
	`);
	assert.match(out.initial,/Saved for later.*Ready/);
	assert.match(out.initial,/Turn in at step 5/);
	assert.match(out.initial,/Earlier turn-in.*step 2/);
	assert.match(out.initial,/No turn-in in this route/);
	assert.equal(out.preview,out.initial, 'browsing another step does not change the live hand-in plan');
	assert.doesNotMatch(out.removed,/Saved for later|Turn in at step 5/);
	assert.equal(out.step,3);
	assert.deepEqual(out.calls,{});
});

test('inspecting a future step previews its objective pins and Follow current restores live map tracking', () => {
	const [out] = run(`
		local g = Polestar.Engine.GetGuide()
		g.steps[5].goals = {
			{t="accept",verb="Accept",subject="Future quest",map=1436,x=40,y=50},
			{t="turnin",verb="Turn in",subject="Earlier quest",map=1436,x=40,y=50},
			{t="collect",verb="Collect",subject="Future item",map=1436,x=45,y=55},
		}
		D.Show(); uistub.calls={}
		local target=Polestar.Nav.GetTarget()
		D.SelectStep(5)
		local m=D.GetFrame().Map
		local preview={map=m:GetMapID(),follow=m:GetFollow(),count=#m.inspection,label=m.inspection[1].label}
		D.FollowCurrent()
		emit({preview=preview,liveMap=m:GetMapID(),follow=m:GetFollow(),cleared=m.inspection==nil,
			step=Polestar.Engine.GetStepIndex(),oldTarget=target,newTarget=Polestar.Nav.GetTarget(),calls=uistub.calls})
	`);
	assert.equal(out.preview.map, 1436);
	assert.equal(out.preview.follow, false);
	assert.equal(out.preview.count, 2, 'goals at the same NPC share one pin and tooltip');
	assert.match(out.preview.label, /Future quest.*\n.*Earlier quest/);
	assert.equal(out.liveMap, 1429);
	assert.equal(out.follow, true);
	assert.equal(out.cleared, true);
	assert.equal(out.step, 3);
	assert.deepEqual(out.newTarget, out.oldTarget);
	assert.deepEqual(out.calls, {});
});

test('a rejected terrain texture retries on an explicit refresh, not every live-position tick', () => {
	const [out] = run(`
		S.failTerrain=true
		local m=M.Create(UIParent)
		m.View=false; m.Viewport:SetSize(1000,500); m:Refresh(true)
		local failed=m.missingTiles
		S.failTerrain=false
		m:Refresh(false)
		local held=m.missingTiles
		m:Refresh(true)
		emit({failed=failed,held=held,recovered=m.missingTiles,visible=m.Tiles[1]:IsShown()})
	`);
	assert.ok(out.failed > 0);
	assert.equal(out.held, out.failed);
	assert.equal(out.recovered, 0);
	assert.equal(out.visible, true);
});

test('dashboard is lazy, opens one reusable frame, and stops its own update driver when closed', () => {
	const [out] = run(`
		local initial = D.GetFrame()
		D.Show()
		local F = D.GetFrame()
		local shown = F:IsShown()
		local updating = F:GetScript("OnUpdate") ~= nil
		D.Hide()
		local hidden = not F:IsShown()
		local stopped = F:GetScript("OnUpdate") == nil
		D.Toggle()
		emit({ initial = initial ~= nil, shown = shown, updating = updating,
			hidden = hidden, stopped = stopped, same = D.GetFrame() == F,
			reopened = F:IsShown(), saved = PolestarPlanner.Get("liveDashboard.shown") })
	`);
	assert.equal(out.initial, false, 'login does not build an unused dashboard');
	assert.equal(out.shown, true);
	assert.equal(out.updating, true);
	assert.equal(out.hidden, true);
	assert.equal(out.stopped, true);
	assert.equal(out.same, true, 'reopening does not leak another tree of frames');
	assert.equal(out.reopened, true);
	assert.equal(out.saved, true);
});

test('slash command and registered companion key binding open the same dashboard', () => {
	const [out] = run(`
		SlashCmdList.POLESTARPLANNER("live")
		local F = D.GetFrame()
		local command = F and F:IsShown()
		PolestarPlanner.Bindings.Live()
		local binding = not F:IsShown()
		SlashCmdList.POLESTARPLANNER("")
		local found = SLASH_POLESTARPLANNER1 == "/polestarplanner"
		emit({ command = command, binding = binding, found = found,
			menu = F:IsShown(), same = D.GetFrame() == F })
	`);
	assert.deepEqual(out, { command: true, binding: true, found: true, menu: true, same: true });
});

test('browsing another step never advances the active guide or changes the arrow target', () => {
	const [out] = run(`
		D.Show()
		local old = Polestar.Nav.GetTarget()
		uistub.calls = {}
		D.GetFrame().Rows[7]:Click()
		D.Refresh(true)
		local browsed = D.GetSnapshot()
		local target = Polestar.Nav.GetTarget()
		local step = Polestar.Engine.GetStepIndex()
		D.FollowCurrent()
		D.Refresh(true)
		emit({ browsed = browsed, following = D.GetSnapshot(), calls = uistub.calls,
			step = step, old = old, target = target })
	`);
	assert.equal(out.step, 3, 'previewing the seventh step leaves the player on step three');
	assert.deepEqual(out.target, out.old, 'the live navigation target is unchanged');
	assert.equal(Object.keys(out.calls).length, 0, 'no Engine or Nav mutations are allowed when browsing');
	assert.equal(out.browsed.selectedIndex, 7);
	assert.equal(out.browsed.currentIndex, 3);
	assert.equal(out.following.selectedIndex, 3);
});

test('opening the Planner top-aligns the current step even when it already fits in the viewport', () => {
	const [out] = run(`
		local getHeight=stub.Methods.GetHeight
		stub.Methods.GetHeight=function(self)
			if self.kind=="ScrollFrame" then return 500 end
			return getHeight(self)
		end
		D.Show()
		local F=D.GetFrame()
		emit({offset=F.List:GetVerticalScroll(),top=F.Rows[3].psTop,
			selected=D.GetSnapshot().selectedIndex,current=Polestar.Engine.GetStepIndex()})
	`);
	assert.ok(out.top > 0);
	assert.equal(out.offset, out.top, 'no fragment of the previous step remains above the current heading');
	assert.equal(out.selected, 3);
	assert.equal(out.current, 3);
});

test('reopening after browsing and guide progress restores the live current step at the top', () => {
	const [out] = run(`
		D.Show(); stub.runTimers()
		local F=D.GetFrame()
		F.List:SetHeight(300)
		D.SelectStep(7)
		PolestarPlanner.Widgets.ScrollTo(F.List,0)
		uistub.setStep(4); D.Refresh(true)
		local browsing=D.GetSnapshot().selectedIndex
		D.Hide(); uistub.setStep(5); uistub.calls={}; D.Show(); stub.runTimers()
		emit({browsing=browsing,selected=D.GetSnapshot().selectedIndex,
			current=Polestar.Engine.GetStepIndex(),offset=F.List:GetVerticalScroll(),top=F.Rows[5].psTop,
			following=PolestarPlanner.Get("liveDashboard.followStep"),cleared=F.Map.inspection==nil,
			mapFollow=F.Map:GetFollow(),calls=uistub.calls})
	`);
	assert.equal(out.browsing, 7, 'while open, intentional browsing stays put as the guide advances');
	assert.equal(out.selected, 5);
	assert.equal(out.current, 5);
	assert.equal(out.offset, out.top);
	assert.equal(out.following, true);
	assert.equal(out.cleared, true);
	assert.equal(out.mapFollow, true);
	assert.deepEqual(out.calls, {}, 'resuming the Planner does not change engine or navigation state');
});

test('Follow current can top-align the final step with room below it and leaves manual scrolling alone', () => {
	const [out] = run(`
		D.Show(); stub.runTimers()
		local F=D.GetFrame()
		F.List:SetHeight(500)
		uistub.setStep(8); D.SelectStep(1); D.FollowCurrent()
		local aligned={offset=F.List:GetVerticalScroll(),top=F.Rows[8].psTop,
			range=F.List.psContent-F.List:GetHeight()}
		PolestarPlanner.Widgets.ScrollTo(F.List,0); D.Refresh(true); stub.advance(0.5)
		emit({aligned=aligned,manual=F.List:GetVerticalScroll(),selected=D.GetSnapshot().selectedIndex})
	`);
	assert.equal(out.aligned.offset, out.aligned.top);
	assert.equal(out.aligned.range, out.aligned.top, 'the scroll range allows the final step header to reach the top');
	assert.equal(out.manual, 0, 'ordinary live refreshes do not repeatedly snap scrolling back');
	assert.equal(out.selected, 8);
});

test('the one-time opening layout pass remeasures wrapped rows without overriding browsing or scrolling', () => {
	const [wrapped, manual, browsing] = run(`
		D.Show()
		local F=D.GetFrame()
		local oldTop=F.Rows[3].psTop
		local height=F.Rows[2].Title.GetStringHeight
		F.Rows[2].Title.GetStringHeight=function(self) return height(self)+48 end
		stub.runTimers()
		emit({offset=F.List:GetVerticalScroll(),top=F.Rows[3].psTop,oldTop=oldTop})
		D.Hide(); D.Show(); PolestarPlanner.Widgets.ScrollTo(F.List,0); stub.runTimers()
		emit({offset=F.List:GetVerticalScroll()})
		D.Hide(); D.Show(); D.SelectStep(7); stub.runTimers()
		emit({selected=D.GetSnapshot().selectedIndex,following=PolestarPlanner.Get("liveDashboard.followStep")})
	`);
	assert.ok(wrapped.top > wrapped.oldTop + 30, 'settled wrapping moves the current row farther down the list');
	assert.equal(wrapped.offset, wrapped.top);
	assert.equal(manual.offset, 0);
	assert.equal(browsing.selected, 7);
	assert.equal(browsing.following, false);
});

test('actual XP and session pace update without browser checkpoints, with no invented values when unavailable', () => {
	const [a, b, c] = run(`
		D.Show()
		local F = D.GetFrame()
		emit({ snapshot = D.GetSnapshot(), name = F.CharacterText:GetText(), xp = F.XPText:GetText(), pace = F.PaceText:GetText() })
		S.xp, S.level, S.rate = 710, 7, 9000
		PolestarPlanner.Fire("QOL_XP_UPDATED")
		stub.advance(0.25)
		emit({ snapshot = D.GetSnapshot(), name = F.CharacterText:GetText(), xp = F.XPText:GetText(), pace = F.PaceText:GetText() })
		S.xpDisabled = true
		Polestar.Set("qol.xpTracker", false)
		S.xp, S.xpMax = nil, nil
		D.Refresh(true)
		emit({ snapshot = D.GetSnapshot(), xp = F.XPText:GetText(), pace = F.PaceText:GetText() })
	`);
	assert.equal(a.snapshot.level, 6);
	assert.equal(a.snapshot.xp, 450);
	assert.equal(a.snapshot.xpMax, 2800);
	assert.equal(a.snapshot.rate, 7200);
	assert.equal(a.snapshot.health, 139);
	assert.equal(a.snapshot.healthMax, 180);
	assert.equal(a.snapshot.power, 220);
	assert.equal(a.snapshot.powerMax, 250);
	assert.match(a.name, /Testdruid.*Level 6/);
	assert.match(a.xp, /450.*2800/);
	assert.match(a.pace, /7200/);
	assert.equal(b.snapshot.level, 7);
	assert.equal(b.snapshot.xp, 710);
	assert.match(b.name, /Level 7/);
	assert.match(b.xp, /710/);
	assert.match(b.pace, /9000/);
	assert.equal(c.snapshot.xp, undefined);
	assert.equal(c.snapshot.xpMax, undefined);
	assert.match(c.xp, /Unavailable/);
	assert.match(c.pace, /tracker off/i);
});

test('protected player vitals go directly to the text renderer without being inspected, measured or exported', () => {
	const [out, changed] = run(`
		local formatText, measure = stub.Methods.SetFormattedText, stub.Methods.GetStringHeight
		setmetatable(S.secret, {__tostring=function() error("protected value converted in Lua") end})
		stub.Methods.SetFormattedText=function(self, fmt, current, maximum, ...)
			if current==S.secret or maximum==S.secret then
				self.protectedDraws=(self.protectedDraws or 0)+1
				self.protectedFormat=fmt
				self.text="client-rendered protected vitals"
				return
			end
			return formatText(self,fmt,current,maximum,...)
		end
		stub.Methods.GetStringHeight=function(self)
			if self.protectedDraws then error("protected text measured in Lua") end
			return measure(self)
		end
		S.health, S.power, S.powerMax=S.secret,S.secret,S.secret
		D.Show(); D.Refresh(true)
		local F=D.GetFrame()
		emit({healthDraws=F.HealthText.protectedDraws or 0,powerDraws=F.PowerText.protectedDraws or 0,
			healthFormat=F.HealthText.protectedFormat,powerFormat=F.PowerText.protectedFormat,
			snapshot=D.GetSnapshot(),tooltip=F.CharacterInfo.psTipLines})
		S.health,S.power,S.powerMax=0,37,100
		D.Refresh(true)
		emit({health=F.HealthText:GetText(),power=F.PowerText:GetText()})
	`);
	assert.ok(out.healthDraws > 0, 'current health reaches the game renderer');
	assert.ok(out.powerDraws > 0, 'current and maximum resource reach the game renderer');
	assert.match(out.healthFormat, /%d \/ %d/);
	assert.match(out.powerFormat, /%d \/ %d/);
	assert.equal(out.snapshot.health, undefined);
	assert.equal(out.snapshot.power, undefined);
	assert.equal(out.snapshot.powerMax, undefined);
	assert.doesNotMatch(JSON.stringify(out.tooltip), /Unavailable/);
	assert.match(changed.health, /Health.*0 \/ 180/);
	assert.match(changed.power, /Resource.*37 \/ 100/);
});

test('missing or failing vital APIs retain unknown values without preventing the rest of the dashboard', () => {
	const [out, rejected] = run(`
		UnitHealth=nil
		UnitPower=function() error("not available") end
		D.Show()
		local F=D.GetFrame()
		emit({health=F.HealthText:GetText(),power=F.PowerText:GetText(),xp=F.XPText:GetText()})
		UnitHealth=function() return S.secret end
		UnitPower=function() return S.secret end
		F.HealthText.SetFormattedText=function() error("renderer rejected value") end
		F.PowerText.SetFormattedText=false
		D.Refresh(true)
		emit({health=F.HealthText:GetText(),power=F.PowerText:GetText(),xp=F.XPText:GetText()})
	`);
	assert.match(out.health, /Health.*Unavailable \/ 180/);
	assert.match(out.power, /Resource.*Unavailable \/ 250/);
	assert.match(out.xp, /450.*2800/);
	assert.deepEqual(rejected,out, 'missing/rejecting renderers use sanitized fallback, never raw protected text');
});

test('guide changes track the current engine step, retain deliberate browsing, and label engine preview separately', () => {
	const [out] = run(`
		D.Show()
		uistub.setStep(4)
		stub.advance(0.25)
		local advancing = D.GetSnapshot()
		D.SelectStep(7)
		uistub.setStep(5)
		stub.advance(0.25)
		local browsing = D.GetSnapshot()
		uistub.live = 7
		D.FollowCurrent()
		local preview = { snapshot = D.GetSnapshot(), hint = D.GetFrame().CurrentHint:GetText() }
		uistub.setGuide(uistub.tailoring, 2)
		stub.advance(0.25)
		emit({ advancing = advancing, browsing = browsing, preview = preview, switched = D.GetSnapshot() })
	`);
	assert.equal(out.advancing.currentIndex, 4);
	assert.equal(out.advancing.selectedIndex, 4);
	assert.equal(out.browsing.currentIndex, 5);
	assert.equal(out.browsing.selectedIndex, 7, 'the row being inspected does not jump away');
	assert.equal(out.preview.snapshot.currentIndex, 5);
	assert.equal(out.preview.snapshot.liveIndex, 7);
	assert.match(out.preview.hint, /preview.*pending step 7/i);
	assert.equal(out.switched.currentIndex, 2);
	assert.equal(out.switched.selectedIndex, 2);
	assert.match(out.switched.guideID, /tailoring/);
});

test('resize and saved position stay on screen; closing persists the last size', () => {
	const [out] = run(`
		PolestarPlanner.Set("liveDashboard.width", 99999)
		PolestarPlanner.Set("liveDashboard.height", -5)
		PolestarPlanner.Set("liveDashboard.pos", { -5000, 99999 })
		D.Show()
		local F = D.GetFrame()
		local _, _, _, x, y = F:GetPoint(1)
		local a = { w = F:GetWidth(), h = F:GetHeight(), x = x, y = y }
		local sizing
		F.StartSizing = function(_, corner) sizing = corner end
		stub.RunScript(F.Grip, "OnMouseDown", "LeftButton")
		F:SetSize(900, 640)
		stub.RunScript(F, "OnSizeChanged", 900, 640)
		stub.RunScript(F.Grip, "OnMouseUp", "LeftButton")
		D.Refresh(true)
		D.Hide()
		emit({ initial = a, width = PolestarPlanner.Get("liveDashboard.width"), height = PolestarPlanner.Get("liveDashboard.height"),
			shown = PolestarPlanner.Get("liveDashboard.shown"), sizing = sizing, screen = { UIParent:GetWidth(), UIParent:GetHeight() } })
	`);
	assert.ok(out.initial.w <= out.screen[0] && out.initial.w >= 850);
	assert.ok(out.initial.h <= out.screen[1] && out.initial.h >= 600);
	assert.ok(out.initial.x >= 0);
	assert.ok(out.initial.y <= out.screen[1]);
	assert.equal(out.width, 900);
	assert.equal(out.height, 640);
	assert.equal(out.sizing, 'BOTTOMRIGHT', 'the grip requests native resizing in both dimensions');
	assert.equal(out.shown, false);
});

test('empty guide and all-completed guide remain usable without changing any progress', () => {
	const [none, complete] = run(`
		uistub.setGuide(nil)
		D.Show()
		emit({ snapshot = D.GetSnapshot(), text = S.texts(D.GetFrame()) })
		uistub.setGuide(uistub.elwynn, 8)
		uistub.complete()
		D.Refresh(true)
		emit({ snapshot = D.GetSnapshot(), text = S.texts(D.GetFrame()) })
	`);
	assert.equal(none.snapshot.stepCount, 0);
	assert.equal(none.snapshot.currentIndex, undefined);
	assert.match(none.text, /No active guide|No guide selected/);
	assert.equal(complete.snapshot.currentIndex, undefined);
	assert.equal(complete.snapshot.stepCount, 8);
});

test('map projection keeps percent coordinates aligned with terrain world bounds at fit and zoom', () => {
	const [out] = run(`
		local v = M.ComputeView(1000, 500, 1000, 500, 1, 50, 50)
		local x, y = M.Project(v, 25, 75)
		local z = M.ComputeView(1000, 500, 1000, 500, 2, 50, 50)
		local zx, zy = M.Project(z, 50, 50)
		local a = M.ComputeView(500, 500, 1000, 500, 1, 50, 50)
		local ax, ay = M.Project(a, 50, 50)
		emit({ fit = { x, y }, zoom = { zx, zy }, aspect = { ax, ay },
			fitView = v, zoomView = z, aspectView = a })
	`);
	assert.deepEqual(out.fit, [250, 375]);
	assert.deepEqual(out.zoom, [500, 250], 'zooming preserves the center under the cursor');
	assert.deepEqual(out.aspect, [250, 250], 'letterboxing centers the painting without stretching it');
	assert.equal(out.aspectView.drawWidth / out.aspectView.drawHeight, 2);
});

test('map projection clamps focus at map edges instead of leaving empty space while zoomed', () => {
	const [out] = run(`
		local a = M.ComputeView(1000, 500, 1000, 500, 2, 0, 0)
		local b = M.ComputeView(1000, 500, 1000, 500, 2, 100, 100)
		emit({ a = a, b = b })
	`);
	assert.equal(out.a.offsetX, 0);
	assert.equal(out.a.offsetY, 0);
	assert.equal(out.b.offsetX, -1000);
	assert.equal(out.b.offsetY, -500);
});

const MAP = `
local owner = CreateFrame("Frame", nil, UIParent)
owner:SetSize(1000, 603)
local map = M.Create(owner)
map.View = false -- unlike the client, the generic stub invents no-op methods for unset capitalized fields
map.Viewport:SetSize(1000, 500) -- the geometry-only stub does not resolve anchor sizes
map:Refresh(true)
local function marker(m)
	local _, _, _, x, y = m:GetPoint(1)
	return { shown = m:IsShown(), x = x, y = y }
end
`;

test('live terrain player and goal use percent coordinates; player moves without changing the route target', () => {
	const [out] = run(`${MAP}
		map:SetObjectives(false) -- isolate the fallback navigation pin from its item-icon replacement
		local first = marker(map.PlayerMarker)
		local goal = marker(map.GoalMarker)
		uistub.calls = {}
		S.player.x, S.player.y = 46, 40
		stub.advance(0.25)
		emit({ first = first, moved = marker(map.PlayerMarker), goal = goal, mapID = map:GetMapID(),
			calls = uistub.calls, lines = S.shown(map.Lines), tiles = S.shown(map.Tiles) })
	`);
	assert.deepEqual(out.first, { shown: true, x: 440, y: -195 });
	assert.deepEqual(out.moved, { shown: true, x: 460, y: -200 });
	assert.deepEqual(out.goal, { shown: true, x: 476, y: -175.5 });
	assert.equal(out.mapID, 1429);
	assert.ok(out.lines > 0, 'the actual RouteStrokes module draws navigation geometry');
	assert.ok(out.tiles > 0);
	assert.equal(Object.keys(out.calls).length, 0);
});

test('map uses native Planner terrain blocks with correct north-west UV cropping and no illustrated-art calls', () => {
	const [out] = run(`${MAP}
		local tiles = {}
		for _, tile in ipairs(map.Tiles) do
			if tile:IsShown() then
				local _, _, _, x, y = tile:GetPoint(1)
				tiles[#tiles + 1] = { file = tile:GetTexture(), uv = tile.texCoord,
					x = x, y = y, width = tile:GetWidth(), height = tile:GetHeight() }
			end
		end
		emit({ tiles = tiles, artCalls = S.reads.illustratedArt, label = map.Zone:GetText() })
	`);
	assert.equal(out.artCalls, 0, 'an illustrated-map request must not be hidden behind a protected call');
	assert.match(out.label, /Planner terrain/);
	assert.deepEqual(out.tiles.map((tile) => tile.file).sort(), [20003030, 20003031, 20003130, 20003131]);
	const northwest = out.tiles.find((tile) => tile.file === 20003030);
	const southeast = out.tiles.find((tile) => tile.file === 20003131);
	const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-6, `${actual} != ${expected}`);
	near(northwest.x, 0);
	near(northwest.y, 0);
	near(northwest.width, 1400 / 3);
	near(northwest.height, 1400 / 3);
	[1 / 8, 1, 1 / 8, 1].forEach((expected, i) => near(northwest.uv[i], expected));
	near(southeast.x, 1400 / 3);
	near(southeast.y, -1400 / 3);
	near(southeast.width, 1600 / 3);
	near(southeast.height, 100 / 3);
	[0, 1, 0, 1 / 16].forEach((expected, i) => near(southeast.uv[i], expected));
});

test('continent view includes all 961 native terrain blocks instead of silently truncating after 256', () => {
	const [out] = run(`${MAP}
		local seen, duplicate = {}, false
		for _, tile in ipairs(map.Tiles) do
			if tile:IsShown() then
				local file = tile:GetTexture()
				if seen[file] then duplicate = true end
				seen[file] = true
			end
		end
		emit({ count = S.shown(map.Tiles), pool = #map.Tiles, duplicate = duplicate,
			first = seen[21000000], last = seen[21003030], artCalls = S.reads.illustratedArt })
	`, { setup: `
		local adt = PolestarPlanner.LiveTerrain.adt
		local tiles = {}
		for row = 0, 30 do
			for col = 0, 30 do tiles[#tiles + 1] = { col, row, 21000000 + row * 100 + col } end
		end
		PolestarPlanner.LiveTerrain.continents[0].tiles = tiles
		PolestarPlanner.LiveTerrain.continents[0].bounds = { minCol = 0, maxCol = 30, minRow = 0, maxRow = 30 }
		Polestar.Compat.MapToWorld = function(map, x, y)
			if not livestub.maps[map] then return nil end
			return 0, adt * (32 - y * 31 / 100), adt * (32 - x * 31 / 100)
		end
	` });
	assert.equal(out.count, 961);
	assert.ok(out.pool <= 1024, `bounded native tile pool: ${out.pool}`);
	assert.equal(out.duplicate, false);
	assert.equal(out.first, true);
	assert.equal(out.last, true);
	assert.equal(out.artCalls, 0);
});

test('client rejection of native terrain textures is reported without an illustrated-map fallback', () => {
	const [out] = run(`${MAP}
		emit({ missing = map.missingTiles, status = map.Status:GetText(),
			artCalls = S.reads.illustratedArt })
	`, { setup: 'livestub.failTerrain = true' });
	assert.equal(out.missing, 4);
	assert.match(out.status, /Terrain textures unavailable \(4\)/);
	assert.equal(out.artCalls, 0);
});

test('crossing zone origins and zooming to their continent keep terrain, player and world route aligned', () => {
	const [out] = run(`${MAP}
		local C, oldToWorld, oldToMap = Polestar.Compat, Polestar.Compat.MapToWorld, Polestar.Compat.WorldToMap
		C.MapToWorld = function(id, x, y)
			if id == 1436 then return 0, 1000 - y * 5, -x * 10 end
			if id == 1415 then return 0, 1000 - y * 5, 1000 - x * 20 end
			return oldToWorld(id, x, y)
		end
		C.WorldToMap = function(c, wx, wy, id)
			if c == 0 and id == 1436 then return -wy / 10, (1000 - wx) / 5 end
			if c == 0 and id == 1415 then return (1000 - wy) / 20, (1000 - wx) / 5 end
			return oldToMap(c, wx, wy, id)
		end
		local tiles = PolestarPlanner.LiveTerrain.continents[0].tiles
		for row = 30, 31 do
			for col = 32, 33 do tiles[#tiles + 1] = { col, row, 20000000 + row * 100 + col } end
		end
		S.player.map = 1436
		S.geometry = { legs = { { kind = "walk", current = true, pts = {
			{ 0, 805, -440 }, { 0, 805, -500 }, { 0, 780, -500 },
		} } } }
		stub.advance(0.25)
		local zone = { player = marker(map.PlayerMarker), files = {} }
		for _, tile in ipairs(map.Tiles) do
			if tile:IsShown() then zone.files[#zone.files + 1] = tile:GetTexture() end
		end
		map:ZoomOutZone()
		local distance = math.huge
		for i = 1, map.strokes.n do
			distance = math.min(distance, math.sqrt((map.strokes.x1[i] - 720)^2 + (map.strokes.y1[i] + 222.5)^2))
		end
		emit({ zone = zone, continent = { map = map:GetMapID(), player = marker(map.PlayerMarker),
			lines = S.shown(map.Lines), nearPlayer = distance } })
	`);
	assert.deepEqual(out.zone.player, { shown: true, x: 440, y: -195 });
	assert.deepEqual(out.zone.files.sort(), [20003032, 20003033, 20003132, 20003133]);
	assert.equal(out.continent.map, 1415);
	assert.deepEqual(out.continent.player, { shown: true, x: 720, y: -222.5 });
	assert.ok(out.continent.lines > 0);
	assert.ok(out.continent.nearPlayer < 15, 'world-space route stays registered with the player on continent terrain');
});

test('unavailable and restricted position hides the marker, then recovers on the next live sample', () => {
	const [out] = run(`${MAP}
		S.player = nil
		stub.advance(0.25)
		local absent = { marker = marker(map.PlayerMarker), status = map.Status:GetText() }
		S.player = { map = 1429, x = S.secret, y = 40 }
		stub.advance(0.25)
		local restricted = marker(map.PlayerMarker)
		S.player = { map = 1429, x = 47, y = 41 }
		stub.advance(0.25)
		emit({ absent = absent, restricted = restricted, restored = marker(map.PlayerMarker) })
	`);
	assert.equal(out.absent.marker.shown, false);
	assert.match(out.absent.status, /location unavailable/i);
	assert.equal(out.restricted.shown, false);
	assert.deepEqual(out.restored, { shown: true, x: 470, y: -205 });
});

test('following crosses maps, browsing stays independent, and parent/player controls work without changing navigation', () => {
	const [out] = run(`${MAP}
		S.player.map = 1436
		stub.advance(0.25)
		local crossed = map:GetMapID()
		map:SetMapID(1429)
		stub.advance(0.25)
		local browse = { mapID = map:GetMapID(), follow = map:GetFollow() }
		map:ZoomOutZone()
		local parent = map:GetMapID()
		map:ShowPlayer()
		uistub.calls = {}
		stub.RunScript(map.Viewport, "OnDragStart")
		local dragging = map:GetFollow()
		stub.RunScript(map.Viewport, "OnDragStop")
		map:SetFollow(true)
		emit({ crossed = crossed, browse = browse, parent = parent,
			restored = map:GetMapID(), follow = map:GetFollow(), dragging = dragging, calls = uistub.calls })
	`);
	assert.equal(out.crossed, 1436);
	assert.deepEqual(out.browse, { mapID: 1429, follow: false });
	assert.equal(out.parent, 1415);
	assert.equal(out.restored, 1436);
	assert.equal(out.follow, true);
	assert.equal(out.dragging, false, 'dragging deliberately releases player follow');
	assert.equal(Object.keys(out.calls).length, 0);
});

test('hidden viewer performs no position or route polling and displayed viewer throttles samples to five per second', () => {
	const [out] = run(`${MAP}
		S.clearReads()
		stub.advance(1)
		local visible = { position = S.reads.position, geometry = S.reads.geometry }
		owner:Hide()
		S.clearReads()
		map:Refresh(true)
		stub.fire("MAP_EXPLORATION_UPDATED")
		stub.advance(2)
		emit({ visible = visible, hidden = S.reads })
	`);
	assert.ok(out.visible.position >= 4 && out.visible.position <= 6, `position samples: ${out.visible.position}`);
	assert.ok(out.visible.geometry <= 6);
	assert.equal(out.hidden.position, 0);
	assert.equal(out.hidden.geometry, 0);
});

test('hidden dashboard only records invalidation and does not sample the character until reopened', () => {
	const [out] = run(`
		D.Show()
		D.Hide()
		local snapshots, original = 0, D.GetSnapshot
		D.GetSnapshot = function() snapshots = snapshots + 1; return original() end
		D.Refresh(true)
		PolestarPlanner.Fire("STEP_UPDATED", 3)
		PolestarPlanner.Fire("QOL_XP_UPDATED")
		stub.advance(1)
		local hidden = snapshots
		D.Show()
		emit({ hidden = hidden, reopened = snapshots })
	`);
	assert.equal(out.hidden, 0);
	assert.ok(out.reopened > 0);
});

test('a client without the optional exploration event still creates a usable live map', () => {
	const [out] = run(`
		local original = stub.Methods.RegisterEvent
		stub.Methods.RegisterEvent = function(self, event)
			if event == "MAP_EXPLORATION_UPDATED" then error("Unknown event on this client") end
			return original(self, event)
		end
		${MAP}
		emit({ player = marker(map.PlayerMarker), mapID = map:GetMapID() })
	`);
	assert.equal(out.player.shown, true);
	assert.equal(out.mapID, 1429);
});

test('missing terrain clears old tiles, route strokes and both markers instead of showing a stale scene', () => {
	const [out] = run(`${MAP}
		map:SetMapID(999999)
		emit({ tiles = S.shown(map.Tiles), lines = S.shown(map.Lines), player = marker(map.PlayerMarker),
			goal = marker(map.GoalMarker), empty = map.Empty:IsShown(), message = map.Empty:GetText() })
	`);
	assert.equal(out.tiles, 0);
	assert.equal(out.lines, 0);
	assert.equal(out.player.shown, false);
	assert.equal(out.goal.shown, false);
	assert.equal(out.empty, true);
	assert.match(out.message, /Planner terrain unavailable/i);
});

test('route strokes keep their bends, omit teleport jumps, and cap the reusable line pool', () => {
	const [out] = run(`${MAP}
		S.geometry = { legs = {
			{ kind = "walk", current = true, pts = { { 0, 610, 560 }, { 0, 610, 500 }, { 0, 649, 524 } } },
			{ kind = "portal", pts = { { 0, 649, 524 }, { 0, 300, 400 } } },
		} }
		map:Refresh(true)
		local bend = { paths = #map.paths, points = map.paths[1].n, lines = S.shown(map.Lines) }
		local points = {}
		for i = 1, 1200 do points[i] = { 0, i % 2 == 0 and 200 or 800, 10 + i % 980 } end
		S.geometry = { legs = { { kind = "walk", current = true, pts = points } } }
		map:Refresh(true)
		local huge = { pool = #map.Lines, count = map.strokes.n }
		S.geometry = { legs = { { kind = "walk", current = true, pts = { { 0, 610, 560 }, { 0, 649, 524 } } } } }
		map:Refresh(true)
		emit({ bend = bend, huge = huge, direct = map.Status:GetText(), pool = #map.Lines, drawn = S.shown(map.Lines) })
	`);
	assert.equal(out.bend.paths, 1, 'a portal must not appear as a traversable line');
	assert.equal(out.bend.points, 3, 'bends supplied by Nav survive the viewer');
	assert.ok(out.bend.lines > 0);
	assert.ok(out.huge.pool > 0 && out.huge.pool <= 1600, `bounded line count: ${out.huge.pool}`);
	assert.ok(out.huge.count <= 1600);
	assert.match(out.direct, /direct segment.*unverified/i);
	assert.ok(out.drawn < out.pool, 'leftover pooled lines are hidden after a shorter route');
});

test('zoomed route projection and clipping remain aligned with the player instead of painting into the toolbar', () => {
	const [out] = run(`${MAP}
		S.player.x, S.player.y = 50, 50
		S.geometry = { legs = { { kind = "walk", current = true, pts = {
			{ 0, 1000, 1000 }, { 0, 750, 500 }, { 0, 500, 0 },
		} } } }
		map:ApplyViewState({ zoom = 4, follow = true })
		map:Refresh(true)
		local box = { minX = math.huge, maxX = -math.huge, minY = math.huge, maxY = -math.huge }
		local centerDistance = math.huge
		local b = map.strokes
		for i = 1, b.n do
			box.minX = math.min(box.minX, b.x1[i], b.x2[i]); box.maxX = math.max(box.maxX, b.x1[i], b.x2[i])
			box.minY = math.min(box.minY, b.y1[i], b.y2[i]); box.maxY = math.max(box.maxY, b.y1[i], b.y2[i])
			centerDistance = math.min(centerDistance, math.sqrt((b.x1[i] - 500)^2 + (b.y1[i] + 250)^2))
		end
		emit({ box = box, count = b.n, player = marker(map.PlayerMarker), centerDistance = centerDistance })
	`);
	assert.ok(out.count > 0);
	assert.deepEqual(out.player, { shown: true, x: 500, y: -250 });
	assert.ok(out.centerDistance < 15, 'the route through the player is at the same projected point');
	assert.ok(out.box.minX >= -5 && out.box.maxX <= 1005);
	assert.ok(out.box.minY >= -505 && out.box.maxY <= 5, 'strokes use y-up anchors within the viewport');
});
