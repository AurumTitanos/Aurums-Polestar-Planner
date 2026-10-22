'use strict';

// Run the native compact frame and map, not a browser reconstruction. These
// checks cover persistence, HUD controls, and isolation from guide progress.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

function run(script, { setup = '' } = {}) {
	return runAddon({
		stubs: ['stub_ui.lua', 'live-dashboard.lua'],
		addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'Theme/Theme.xml', 'Maps/RouteStrokes.lua', 'UI/UI.xml'] }],
		script: `uistub.install(); livestub.install()
			${setup}
			stub.login(); uistub.setGuide(uistub.elwynn, 3)
			local Mini, D, S = PolestarPlanner.LiveMiniMap, PolestarPlanner.LiveDashboard, livestub
			${script}`,
	}).emitted;
}

test('compact map is lazy, slash-toggle reuses its frame, and hidden viewers stop all sampling', () => {
	const [out] = run(`
		local lazy=Mini.GetFrame()==nil
		SlashCmdList.POLESTARPLANNER("minimap")
		local F=Mini.GetFrame()
		local opened={shown=F:IsShown(),title=F.Title:GetText(),w=F:GetWidth(),h=F:GetHeight(),
			mapWidth=F.Map:GetWidth(),mapHeight=F.Map:GetHeight(),hasList=rawget(F,"List")~=nil,
			mapUpdating=F.Map:GetScript("OnUpdate")~=nil}
		F.CloseButton:Click()
		S.clearReads(); stub.advance(2)
		-- Supply the event snapshot so the unrelated compact guide does not
		-- fetch its own XP sample in response to this synthetic notification.
		PolestarPlanner.Fire("QOL_XP_UPDATED",{rate=S.rate})
		local stopped={xp=S.reads.xp,position=S.reads.position,geometry=S.reads.geometry,
			window=F:GetScript("OnUpdate")==nil,map=F.Map:GetScript("OnUpdate")==nil}
		Mini.Toggle()
		emit({lazy=lazy,opened=opened,stopped=stopped,same=F==Mini.GetFrame(),
			shown=F:IsShown(),saved=PolestarPlanner.Get("liveMiniMap.shown")})
	`);
	assert.equal(out.lazy, true);
	assert.deepEqual(out.opened, { shown: true, title: 'Polestar map', w: 420, h: 380,
		mapWidth: 420, mapHeight: 354, hasList: false, mapUpdating: true });
	assert.deepEqual(out.stopped, { xp: 0, position: 0, geometry: 0, window: true, map: true });
	assert.equal(out.same, true);
	assert.equal(out.shown, true);
	assert.equal(out.saved, true);
});

test('lock prevents outer movement and resizing while preserving map pan, zoom, and layers', () => {
	const [out] = run(`
		Mini.Show(); local F=Mini.GetFrame(); local m=F.Map
		stub.RunScript(F.Header,"OnDragStart")
		local moving=F.moving==true
		stub.RunScript(F.Header,"OnDragStop")
		stub.RunScript(F.Grip,"OnMouseDown","LeftButton")
		local sizing=F.sizing==true
		Mini.SetLocked(true)
		stub.RunScript(F.Header,"OnDragStart")
		stub.RunScript(F.Grip,"OnMouseDown","LeftButton")
		local locked={moving=F.moving==true,sizing=F.sizing==true,movable=F:IsMovable(),resizable=F:IsResizable(),grip=F.Grip:IsShown()}
		local old=m:GetViewState().zoom
		stub.RunScript(m.Viewport,"OnMouseWheel",1)
		m:SetFollow(false)
		local camera={zoom=m:GetViewState().zoom,follow=m:GetFollow(),mouse=m.Viewport:IsMouseEnabled(),layers=m.LayersButton:IsShown()}
		Mini.SetLocked(false)
		emit({moving=moving,sizing=sizing,locked=locked,camera=camera,old=old,
			unlocked=F:IsMovable() and F:IsResizable() and F.Grip:IsShown()})
	`);
	assert.equal(out.moving, true);
	assert.equal(out.sizing, true);
	assert.deepEqual(out.locked, { moving: false, sizing: false, movable: false, resizable: false, grip: false });
	assert.ok(out.camera.zoom > out.old);
	assert.equal(out.camera.follow, false);
	assert.equal(out.camera.mouse, true);
	assert.equal(out.camera.layers, true);
	assert.equal(out.unlocked, true);
});

test('Alt+Z parent hiding pauses the map without clearing its reopen preference', () => {
	const [out] = run(`
		Mini.Show(); local F=Mini.GetFrame()
		-- The general stub does not dispatch ancestor visibility callbacks.
		-- Model the client: parent becomes invisible, but F:IsShown stays true.
		UIParent:Hide(); stub.RunScript(F,"OnHide")
		S.clearReads(); stub.advance(2)
		PolestarPlanner.Fire("QOL_XP_UPDATED",{rate=S.rate}); Mini.Refresh(true)
		local hidden={shown=F:IsShown(),visible=F:IsVisible(),saved=PolestarPlanner.Get("liveMiniMap.shown"),
			windowStopped=F:GetScript("OnUpdate")==nil,mapStopped=F.Map:GetScript("OnUpdate")==nil,
			position=S.reads.position,xp=S.reads.xp}
		UIParent:Show(); stub.RunScript(F,"OnShow")
		local restored={visible=F:IsVisible(),mapVisible=F.Map:IsVisible(),saved=PolestarPlanner.Get("liveMiniMap.shown"),
			windowRunning=F:GetScript("OnUpdate")~=nil,mapRunning=F.Map:GetScript("OnUpdate")~=nil}
		Mini.Hide()
		emit({hidden=hidden,restored=restored,explicitClose=PolestarPlanner.Get("liveMiniMap.shown")})
	`);
	assert.deepEqual(out.hidden, { shown: true, visible: false, saved: true, windowStopped: true,
		mapStopped: true, position: 0, xp: 0 });
	assert.deepEqual(out.restored, { visible: true, mapVisible: true, saved: true, windowRunning: false, mapRunning: true });
	assert.equal(out.explicitClose, false);
});

test('settings menu changes persisted opacity and lock without affecting the full planner', () => {
	const [out] = run(`
		D.Show(); Mini.Show(); local F=Mini.GetFrame()
		local function pick(text)
			F.OptionsButton:Click()
			for _,row in ipairs(PolestarPlannerMenu.rows) do if row:IsShown() and row.Text:GetText()==text then row:Click(); return true end end
		end
		local opacity=pick("Opacity 50%")
		local lock=pick("Lock window")
		local half=F:GetAlpha()
		Mini.Hide(); Mini.Show()
		local restored=F:GetAlpha()
		Mini.SetOpacity(0); local floor=F:GetAlpha()
		Mini.SetOpacity(2); local ceiling=F:GetAlpha()
		Mini.SetOpacity(0/0)
		emit({opacity=opacity,lock=lock,half=half,restored=restored,floor=floor,ceiling=ceiling,
			invalid=F:GetAlpha(),savedLock=PolestarPlanner.Get("liveMiniMap.locked"),
			fullAlpha=D.GetFrame():GetAlpha() or 1,fullShown=D.GetFrame():IsShown()})
	`);
	assert.equal(out.opacity, true);
	assert.equal(out.lock, true);
	assert.equal(out.half, 0.5);
	assert.equal(out.restored, 0.5);
	assert.equal(out.floor, 0.25);
	assert.equal(out.ceiling, 1);
	assert.equal(out.invalid, 1);
	assert.equal(out.savedLock, true);
	assert.equal(out.fullAlpha, 1);
	assert.equal(out.fullShown, true);
});

test('resize persists both dimensions; logout saves the independent camera without hiding the HUD', () => {
	const [out] = run(`
		Mini.Show(); local F=Mini.GetFrame()
		local corner
		F.StartSizing=function(_,value) corner=value end
		stub.RunScript(F.Grip,"OnMouseDown","LeftButton")
		F:SetSize(580,440); F.x,F.y=180,230
		stub.RunScript(F,"OnSizeChanged",580,440)
		stub.RunScript(F.Grip,"OnMouseUp","LeftButton")
		F.Map:ApplyViewState({mapID=1436,zoom=8,focusX=36,focusY=60,follow=false})
		stub.fire("PLAYER_LOGOUT")
		emit({corner=corner,w=PolestarPlanner.Get("liveMiniMap.width"),h=PolestarPlanner.Get("liveMiniMap.height"),
			mapWidth=F.Map:GetWidth(),mapHeight=F.Map:GetHeight(),
			pos=PolestarPlanner.Get("liveMiniMap.pos"),view=PolestarPlanner.Get("liveMiniMap.view"),
			shown=PolestarPlanner.Get("liveMiniMap.shown")})
	`);
	assert.equal(out.corner, 'BOTTOMRIGHT');
	assert.equal(out.w, 580);
	assert.equal(out.h, 440);
	assert.equal(out.mapWidth, 580);
	assert.equal(out.mapHeight, 414);
	assert.deepEqual(out.pos, [180, 670]);
	assert.deepEqual(out.view, { mapID: 1436, zoom: 8, focusX: 36, focusY: 60, follow: false });
	assert.equal(out.shown, true);
});

test('saved visible state restores at login and clamps offscreen geometry on display changes', () => {
	const [out] = run(`
		local F=Mini.GetFrame()
		local _,_,_,x,y=F:GetPoint(1)
		local loaded={shown=F:IsShown(),w=F:GetWidth(),h=F:GetHeight(),x=x,y=y,
			alpha=F:GetAlpha(),locked=Mini.GetLocked(),view=F.Map:GetViewState()}
		UIParent:SetSize(700,400); stub.fire("DISPLAY_SIZE_CHANGED")
		local _,_,_,sx,sy=F:GetPoint(1)
		emit({loaded=loaded,smaller={w=F:GetWidth(),h=F:GetHeight(),x=sx,y=sy}})
	`, { setup: `UIParent:SetSize(1920,1080)
		PolestarPlanner.Set("liveMiniMap.shown",true)
		PolestarPlanner.Set("liveMiniMap.width",99999); PolestarPlanner.Set("liveMiniMap.height",-9)
		PolestarPlanner.Set("liveMiniMap.pos",{-5000,99999})
		PolestarPlanner.Set("liveMiniMap.opacity",0.75); PolestarPlanner.Set("liveMiniMap.locked",true)
		PolestarPlanner.Set("liveMiniMap.view",{mapID=1436,zoom=9,follow=false,focusX=42,focusY=33})` });
	assert.equal(out.loaded.shown, true);
	assert.equal(out.loaded.w, 1904);
	assert.equal(out.loaded.h, 180);
	assert.equal(out.loaded.x, 0);
	assert.equal(out.loaded.y, 1080);
	assert.equal(out.loaded.alpha, 0.75);
	assert.equal(out.loaded.locked, true);
	assert.deepEqual(out.loaded.view, { mapID: 1436, zoom: 9, follow: false, focusX: 42, focusY: 33 });
	assert.deepEqual(out.smaller, { w: 684, h: 180, x: 0, y: 400 });
});

test('one shallow toolbar leaves edge-to-edge terrain and a drag handle at minimum width', () => {
	const [out] = run(`
		PolestarPlanner.Set("liveMiniMap.width",320); PolestarPlanner.Set("liveMiniMap.height",180)
		Mini.Show(); local F=Mini.GetFrame(); local m=F.Map
		-- In the client anchors resolve this size; the contract stub needs it explicitly.
		m.Viewport:SetSize(320,154); m:Refresh(true)
		local buttons, previous, width = true, F.Header, 0
		for _,button in ipairs({F.CloseButton,F.OptionsButton,m.LayersButton,m.ZoomInButton,
			m.ZoomOutButton,m.ParentButton,m.PlayerButton,m.FollowButton}) do
			local point,relative,relativePoint,x,y=button:GetPoint(1)
			buttons=buttons and button:GetParent()==F.Header and button:GetHeight()==22
				and relative==previous and point=="RIGHT" and y==0 and button.psTip~=nil
			width=width+button:GetWidth()+2; previous=button
		end
		local point,relative,relativePoint,x,y=m:GetPoint(1)
		local _,viewportParent,_,vx,vy=m.Viewport:GetPoint(1)
		local _,viewportBottom,_,bx,by=m.Viewport:GetPoint(2)
		m.FollowButton:Click(); local followOff=not m:GetFollow()
		m.PlayerButton:Click(); local followOn=m:GetFollow()
		local old=m:GetViewState().zoom; m.ZoomInButton:Click(); local zoomed=m:GetViewState().zoom>old
		m.ZoomOutButton:Click(); local zoomBack=m:GetViewState().zoom==old
		m.ParentButton:Click()
		emit({headerHeight=F.Header:GetHeight(),titleWidth=F.Title:GetWidth(),buttons=buttons,
			fit=width+F.Title:GetWidth()<=F:GetWidth(),noWindowSkin=rawget(F,"psSkin")==nil,
			mapWidth=m:GetWidth(),mapHeight=m:GetHeight(),edgeToEdge=relative==F and x==0 and y==-26
				and viewportParent==m and viewportBottom==m and vx==0 and vy==0 and bx==0 and by==0,
			infoHidden=not m.Info:IsShown(),followOff=followOff,followOn=followOn,zoomed=zoomed,
			zoomBack=zoomBack,parentMap=m:GetMapID(),title=F.Title:GetText()})
	`);
	assert.deepEqual(out, { headerHeight: 26, titleWidth: 50, buttons: true, fit: true, noWindowSkin: true,
		mapWidth: 320, mapHeight: 154, edgeToEdge: true, infoHidden: true,
		followOff: true, followOn: true, zoomed: true, zoomBack: true, parentMap: 1415, title: 'Eastern Kingdoms' });
});

test('compact map no longer creates an XP footer or polls session XP', () => {
	const [out] = run(`
		Mini.Show(); local F=Mini.GetFrame()
		S.clearReads(); Mini.Refresh(true); stub.advance(1.1)
		PolestarPlanner.Fire("QOL_XP_UPDATED",{rate=S.rate})
		emit({footer=rawget(F,"PaceText")~=nil,windowTimer=F:GetScript("OnUpdate")~=nil,
			xpReads=S.reads.xp,mapStillUpdating=F.Map:GetScript("OnUpdate")~=nil})
	`);
	assert.deepEqual(out, { footer: false, windowTimer: false, xpReads: 0, mapStillUpdating: true });
});

test('compact map follows current goals independently while full planner inspects another step', () => {
	const [out] = run(`
		D.Show(); Mini.Show(); local F=Mini.GetFrame(); local full=D.GetFrame().Map
		local target=Polestar.Nav.GetTarget()
		uistub.calls={}
		D.SelectStep(5)
		F.Map:ShowPlayer()
		local current={compactFollow=F.Map:GetFollow(),fullFollow=full:GetFollow(),fullInspection=full.inspectionIndex,
			compactInspection=F.Map.inspectionIndex}
		F.Map:SetMapID(1436); F.Map:ZoomIn()
		local fullView=full:GetViewState()
		Mini.Hide(); Mini.Show()
		emit({current=current,fullView=fullView,afterFull=full:GetViewState(),mini=F.Map:GetViewState(),
			step=Polestar.Engine.GetStepIndex(),target=target,afterTarget=Polestar.Nav.GetTarget(),calls=uistub.calls})
	`);
	assert.equal(out.current.compactFollow, true);
	assert.equal(out.current.fullFollow, false);
	assert.equal(out.current.fullInspection, 5);
	assert.equal(out.current.compactInspection, undefined);
	assert.deepEqual(out.afterFull, out.fullView);
	assert.equal(out.mini.mapID, 1436);
	assert.equal(out.mini.follow, true, 'temporary browsing preserves the saved Follow preference');
	assert.equal(out.step, 3);
	assert.deepEqual(out.afterTarget, out.target);
	assert.deepEqual(out.calls, {});
});
