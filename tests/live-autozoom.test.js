'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

function run(script) {
	return runAddon({
		stubs: ['stub_ui.lua', 'live-dashboard.lua'],
		addons: [{ name: 'Polestar', files: ['Core/Core.xml', 'Theme/Theme.xml', 'Maps/RouteStrokes.lua', 'UI/UI.xml'] }],
		script: `uistub.install(); livestub.install(); stub.login(); uistub.setGuide(uistub.elwynn, 3)
			local M, Mini, D, S = PolestarPlanner.LiveMap, PolestarPlanner.LiveMiniMap, PolestarPlanner.LiveDashboard, livestub
			local C=Polestar.Compat
			local function point(x,y,map) local c,wx,wy=C.MapToWorld(map or 1429,x,y); return {c,wx,wy} end
			local function walk(points,current) local pts={}; for _,p in ipairs(points) do pts[#pts+1]=point(p[1],p[2]) end; return {kind="walk",current=current,pts=pts} end
			local b={c=0,left=1000,top=1000,kx=-1/1000,ky=-1/500}
			${script}`,
	}).emitted;
}

test('remaining bounds omit completed bends, include adjoining split walks, and stop before transport', () => {
	const [out] = run(`
		local geometry={legs={
			walk({{2,2},{20,20},{60,20},{60,70}},true),
			walk({{60,70},{90,80}},false),
			{kind="boat",pts={point(90,80),point(98,98)}},
			walk({{98,98},{99,99}},false),
		}}
		emit(M.RemainingWalkBounds(geometry,3,b,30,20))
	`);
	assert.deepEqual(out, { x0: 30, x1: 90, y0: 20, y1: 80 });
});

test('auto framing stops at zone edge, disconnected legs, and cross-continent or non-walking travel', () => {
	const [out] = run(`
		local edge={legs={walk({{80,40},{120,80},{30,10}},true)}}
		local gap={legs={walk({{30,40},{40,40}},true),walk({{80,80},{95,95}},false)}}
		local continent={legs={{kind="walk",current=true,pts={point(30,40),{1,600,500}}}}}
		local transport={legs={{kind="boat",current=true,pts={point(30,40),point(99,99)}},walk({{99,99},{50,50}},false)}}
		emit({edge=M.RemainingWalkBounds(edge,2,b,80,40),gap=M.RemainingWalkBounds(gap,2,b,30,40),
			continent=M.RemainingWalkBounds(continent,2,b,30,40),transport=M.RemainingWalkBounds(transport,nil,b,30,40),
			missing=M.RemainingWalkBounds(nil,nil,b,30,40)})
	`);
	assert.deepEqual(out.edge, { x0: 80, x1: 100, y0: 40, y1: 60 });
	assert.deepEqual(out.gap, { x0: 30, x1: 40, y0: 40, y1: 40 });
	assert.equal(out.continent, undefined);
	assert.equal(out.transport, undefined);
	assert.equal(out.missing, undefined);
});

test('automatic framing includes route bends and fits both wide and shallow compact viewports', () => {
	const [out] = run(`
		local results={}
		for _,size in ipairs({{420,354},{320,154},{900,180}}) do
			local bounds={x0=40,x1=70,y0=20,y1=80}
			local z=M.AutoZoomLevel(size[1],size[2],1000,500,40,20,bounds)
			local view=M.ComputeView(size[1],size[2],1000,500,z,40,20)
			local visible=true
			for _,p in ipairs({{40,20},{70,20},{70,80}}) do
				local x,y=M.Project(view,p[1],p[2]); visible=visible and x>=0 and y>=0 and x<=size[1] and y<=size[2]
			end
			results[#results+1]={visible=visible,zoom=z}
		end
		local far=M.AutoZoomLevel(420,354,1000,500,20,40,{x0=20,x1=80,y0=40,y1=40})
		local near=M.AutoZoomLevel(420,354,1000,500,75,40,{x0=75,x1=80,y0=40,y1=40})
		emit({results=results,far=far,near=near})
	`);
	assert.ok(out.results.every(r => r.visible && r.zoom >= 1));
	assert.ok(out.near > out.far);
	assert.ok(out.near < 10, 'arrival keeps useful nearby terrain context');
});

test('camera easing is monotonic, elapsed-time driven, and widens faster than it narrows', () => {
	const [out] = run(`
		local z=1; local rising={}
		for i=1,5 do z=M.EaseAutoZoom(z,5,0.2); rising[#rising+1]=z end
		emit({still=M.EaseAutoZoom(2,5,0),rising=rising,
			one=M.EaseAutoZoom(1,5,0.4),two=M.EaseAutoZoom(M.EaseAutoZoom(1,5,0.2),5,0.2),
			out=M.EaseAutoZoom(5,1,0.2),inside=M.EaseAutoZoom(1,5,0.2)})
	`);
	assert.equal(out.still, 2);
	assert.ok(out.rising.every((v, i, values) => v < 5 && (i === 0 ? v > 1 : v > values[i - 1])));
	assert.ok(Math.abs(out.one - out.two) < 1e-8);
	assert.ok(5 - out.out > out.inside - 1);
});

test('compact camera progressively zooms into the remaining cached route and holds small position jitter', () => {
	const [out] = run(`
		S.player.x,S.player.y=20,40
		S.geometry={legs={walk({{20,40},{50,40},{80,40}},true)}}
		Mini.Show(); local m=Mini.GetFrame().Map; m.Viewport:SetSize(420,354); m:SetAutoZoom(true)
		local far=m.zoom
		S.player.x=60; stub.advance(0.21)
		local first=m.zoom; local desired=m.autoZoomTarget; local index=m.liveIndex
		stub.advance(2); local closer=m.zoom
		S.player.x=60.1; stub.advance(0.21)
		emit({far=far,first=first,desired=desired,closer=closer,index=index,held=m.autoZoomTarget==desired,
			map=m:GetMapID(),follow=m:GetFollow()})
	`);
	assert.equal(out.far, 1);
	assert.ok(out.first > out.far && out.first < out.desired);
	assert.ok(out.closer > out.first && out.closer <= out.desired);
	assert.equal(out.index, 3);
	assert.equal(out.held, true);
	assert.equal(out.map, 1429);
	assert.equal(out.follow, true);
});

test('Follow off pauses auto zoom; manual zoom temporarily pauses it without changing preferences or full Planner', () => {
	const [out] = run(`
		D.Show(); local full=D.GetFrame().Map; full:ApplyViewState({zoom=4,follow=true})
		S.player.x,S.player.y=20,40; S.geometry={legs={walk({{20,40},{80,40}},true)}}
		Mini.Show(); local F=Mini.GetFrame(); local m=F.Map; m.Viewport:SetSize(420,354); m:SetAutoZoom(true)
		local target=Polestar.Nav.GetTarget(); uistub.calls={}
		m:SetFollow(false); local paused=m.zoom
		S.player.x=75; stub.advance(1)
		local held=m.zoom==paused and m:GetAutoZoom()
		m:SetFollow(true); stub.advance(1); local resumed=m.zoom>paused
		stub.RunScript(m.Viewport,"OnMouseWheel",1); local manual=m.zoom
		stub.advance(1)
		local override=m:GetAutoZoom() and Mini.GetAutoZoom() and m.zoom==manual
		Mini.Hide(); Mini.Show(); local persisted=m:GetAutoZoom()
		stub.advance(5); local automatic=m.zoom~=manual
		F.OptionsButton:Click()
		for _,row in ipairs(PolestarPlannerMenu.rows) do if row:IsShown() and row.Text:GetText()=="Auto zoom" then row:Click(); break end end
		Mini.Hide(); Mini.Show()
		emit({held=held,resumed=resumed,override=override,persisted=persisted,automatic=automatic,
			explicitOff=not m:GetAutoZoom() and not Mini.GetAutoZoom(),
			fullZoom=full.zoom,fullAuto=full:GetAutoZoom(),step=Polestar.Engine.GetStepIndex(),
			target=target,afterTarget=Polestar.Nav.GetTarget(),calls=uistub.calls})
	`);
	assert.equal(out.held, true);
	assert.equal(out.resumed, true);
	assert.equal(out.override, true);
	assert.equal(out.persisted, true);
	assert.equal(out.automatic, true);
	assert.equal(out.explicitOff, true);
	assert.equal(out.fullZoom, 4);
	assert.equal(out.fullAuto, false);
	assert.equal(out.step, 3);
	assert.deepEqual(out.target, out.afterTarget);
	assert.deepEqual(out.calls, {});
});

test('wheel and both zoom buttons preserve Auto zoom; Player and Follow resume framing immediately', () => {
	const [out] = run(`
		S.player.x,S.player.y=75,40; S.geometry={legs={walk({{20,40},{80,40}},true)}}
		Mini.Show(); local m=Mini.GetFrame().Map; m.Viewport:SetSize(420,354); m:SetAutoZoom(true)
		local automatic=m.zoom
		m.ZoomInButton:Click(); local plus=m.zoom
		stub.advance(1); local plusHeld=m.zoom==plus
		m.PlayerButton:Click(); local player=m.zoom==automatic
		m.ZoomOutButton:Click(); local minus=m.zoom
		stub.advance(1); local minusHeld=m.zoom==minus
		m:SetFollow(false); m.FollowButton:Click(); local follow=m.zoom==automatic
		stub.RunScript(m.Viewport,"OnMouseWheel",1); Mini.SaveState()
		emit({plusHeld=plusHeld,minusHeld=minusHeld,player=player,follow=follow,
			saved=PolestarPlanner.Get("liveMiniMap.autoZoom"),enabled=m:GetAutoZoom(),
			view=PolestarPlanner.Get("liveMiniMap.view")})
	`);
	assert.equal(out.plusHeld, true);
	assert.equal(out.minusHeld, true);
	assert.equal(out.player, true);
	assert.equal(out.follow, true);
	assert.equal(out.saved, true);
	assert.equal(out.enabled, true);
	assert.equal(out.view.follow, true);
});

test('compact map resumes enabled Follow after teleport through unavailable position, including while hidden', () => {
	const [out] = run(`
		S.maps[1439]={name="Darkshore",mapID=1439,mapType=3,parentMapID=1415}
		S.maps[1450]={name="Moonglade",mapID=1450,mapType=3,parentMapID=1415}
		S.player.map=1439
		D.Show(); local full=D.GetFrame().Map; full:SetMapID(1439)
		Mini.Show(); local m=Mini.GetFrame().Map
		m.Viewport:SetSize(420,354); m:Refresh(true)
		stub.RunScript(m.Viewport,"OnDragStart"); stub.RunScript(m.Viewport,"OnDragStop")
		Mini.SaveState(); local savedFollow=PolestarPlanner.Get("liveMiniMap.view").follow
		stub.fire("ZONE_CHANGED"); stub.advance(0.21)
		local held=m:GetMapID()==1439 and not m:GetFollow()
		S.player=nil; stub.fire("PLAYER_ENTERING_WORLD"); stub.advance(0.21)
		S.player={map=1450,x=53,y=34}; stub.fire("ZONE_CHANGED_NEW_AREA"); stub.advance(0.21)
		local teleported={map=m:GetMapID(),follow=m:GetFollow(),x=m.focusX,y=m.focusY,auto=m:GetAutoZoom()}
		m.ParentButton:Click(); Mini.Hide(); D.Hide()
		S.player={map=1439,x=36,y=45}; stub.fire("PLAYER_ENTERING_WORLD")
		S.clearReads(); stub.advance(0.21); local hiddenReads=S.reads.position
		Mini.Show()
		local restored=M.Create(UIParent,{compact=true,autoZoom=Mini.GetAutoZoom()})
		restored.Viewport:SetSize(420,354); restored:ApplyViewState(PolestarPlanner.Get("liveMiniMap.view"))
		emit({savedFollow=savedFollow,held=held,teleported=teleported,hiddenReads=hiddenReads,
			reopened={map=m:GetMapID(),follow=m:GetFollow()},full={map=full:GetMapID(),follow=full:GetFollow()},
			restored={map=restored:GetMapID(),follow=restored:GetFollow(),auto=restored:GetAutoZoom()}})
	`);
	assert.equal(out.savedFollow, true, 'a transient pan must not save Follow as disabled');
	assert.equal(out.held, true, 'ordinary same-zone refresh must not interrupt panning');
	assert.deepEqual(out.teleported, { map: 1450, follow: true, x: 53, y: 34, auto: true });
	assert.equal(out.hiddenReads, 0, 'hidden viewers must not poll through the teleport');
	assert.deepEqual(out.reopened, { map: 1439, follow: true });
	assert.deepEqual(out.full, { map: 1439, follow: false });
	assert.deepEqual(out.restored, { map: 1439, follow: true, auto: true });
});

test('explicit Follow and Auto zoom OFF choices survive zones, missing position, reopening and saved-state restore', () => {
	const [out] = run(`
		Mini.Show(); local m=Mini.GetFrame().Map
		m:SetFollow(false); Mini.SetAutoZoom(false); Mini.SaveState()
		local saved=PolestarPlanner.Get("liveMiniMap.view")
		S.player=nil; stub.advance(0.21)
		S.player={map=1436,x=30,y=40}; stub.fire("PLAYER_ENTERING_WORLD"); stub.advance(0.21)
		Mini.Hide(); Mini.Show()
		local restored=M.Create(UIParent,{compact=true,autoZoom=Mini.GetAutoZoom()}); restored:ApplyViewState(saved)
		emit({map=m:GetMapID(),follow=m:GetFollow(),auto=m:GetAutoZoom(),saved=saved.follow,
			restored={map=restored:GetMapID(),follow=restored:GetFollow(),auto=restored:GetAutoZoom()}})
	`);
	assert.deepEqual(out, { map: 1429, follow: false, auto: false, saved: false,
		restored: { map: 1429, follow: false, auto: false } });
});

test('zone changes reset framing, transports hold the current zoom, and absent player position is harmless', () => {
	const [out] = run(`
		S.player.x,S.player.y=45,40; S.geometry={legs={walk({{45,40},{50,40}},true)}}
		Mini.Show(); local m=Mini.GetFrame().Map; m.Viewport:SetSize(420,354); m:SetAutoZoom(true)
		local near=m.zoom
		S.player.map,S.player.x=1436,10; S.geometry={legs={walk({{10,40},{90,40}},true)}}
		stub.advance(0.21); local changed={map=m:GetMapID(),zoom=m.zoom}
		S.geometry={legs={{kind="boat",current=true,pts={point(10,40),point(90,40)}}}}
		stub.advance(1); local transport=m.zoom
		S.player=nil; stub.advance(1)
		emit({near=near,changed=changed,transport=transport,missing=m.zoom,playerShown=m.PlayerMarker:IsShown()})
	`);
	assert.ok(out.near > 1);
	assert.deepEqual(out.changed, { map: 1436, zoom: 1 });
	assert.equal(out.transport, 1);
	assert.equal(out.missing, 1);
	assert.equal(out.playerShown, false);
});
