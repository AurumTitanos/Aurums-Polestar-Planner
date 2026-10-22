'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {runAddon}=require('./helpers/lua');
const native=require('./fixtures/openmap/native-maps.json');
function lua(v){if(v==null)return'nil';if(typeof v!=='object')return JSON.stringify(v);return`{${Object.entries(v).map(([k,x])=>`[${Array.isArray(v)?+k+1:/^\d+$/.test(k)?k:JSON.stringify(k)}]=${lua(x)}`).join(',')}}`;}
function run(script){return runAddon({stubs:['stub_ui.lua','live-dashboard.lua'],script:`
 uistub.install();livestub.install();stub.login();uistub.setGuide(uistub.elwynn,3)
 local M,Mini,D,S=PolestarPlanner.LiveMap,PolestarPlanner.LiveMiniMap,PolestarPlanner.LiveDashboard,livestub
 local maps=${lua(Object.fromEntries([1414,1438,1439,1457,1415,1429].map(id=>[id,native.maps[id]])))}
 for id,m in pairs(maps) do S.maps[id]=m.info end
 local C=Polestar.Compat
 C.MapToWorld=function(id,x,y) local b=maps[id] and maps[id].bounds;if b then return b.c,b.top+y/100/b.ky,b.left+x/100/b.kx end end
 C.WorldToMap=function(c,wx,wy,id) local b=maps[id] and maps[id].bounds;if b and b.c==c then return (wy-b.left)*b.kx*100,(wx-b.top)*b.ky*100 end end
 PolestarPlanner.LiveTerrain.continents[1]=PolestarPlanner.LiveTerrain.continents[0]
 local airborne=true;C.IsOnTaxi=function()return airborne end
 local function destination(id,x,y) local c,wx,wy=C.MapToWorld(id,x,y);return{c=c,wx=wx,wy=wy}end
 local dest=destination(1438,58.4,93.93)
 Polestar.Maps={GetFlight=function()return "Rut'theran Village" end,TaxiNodeByName=function()return 27 end,Faction=function()return "Alliance" end}
 Polestar.Nav.GetTravelData=function()return{taxiById={[27]=dest}}end
 S.player={map=1439,x=36.77,y=44.28};S.geometry=nil
 local function visible(m,point) local b=m.bounds;local x,y=M.Project(m.View,(point.wy-b.left)*b.kx*100,(point.wx-b.top)*b.ky*100);return x>=12 and y>=12 and x<=m.View.width-12 and y<=m.View.height-12 end
 ${script}`}).emitted;}

test('airborne compact map fits player and actual destination on Kalimdor at different viewport sizes',()=>{
 const [out]=run(`
  local results={};local target=Polestar.Nav.GetTarget();uistub.calls={}
  Mini.Show();local m=Mini.GetFrame().Map
  for _,size in ipairs({{320,154},{420,354},{900,180}})do
   m.Viewport:SetSize(size[1],size[2]);m:SetAutoZoom(true);m:ShowPlayer()
   results[#results+1]={map=m:GetMapID(),player=visible(m,destination(1439,36.77,44.28)),dest=visible(m,dest),marker=m.FlightMarker:IsShown(),follow=m:GetFollow(),zoom=m.zoom}
  end
  emit({results=results,step=Polestar.Engine.GetStepIndex(),beforeTarget=target,afterTarget=Polestar.Nav.GetTarget(),calls=uistub.calls})
 `);
 for(const x of out.results){assert.equal(x.map,1414);assert.equal(x.player,true);assert.equal(x.dest,true);assert.equal(x.marker,true);assert.equal(x.follow,true);assert.ok(x.zoom>1);}
 assert.equal(out.step,3);assert.deepEqual(out.beforeTarget,out.afterTarget);assert.deepEqual(out.calls,{});
});

test('flight camera survives zone changes and returns to local walking view after landing',()=>{
 const [out]=run(`
  Mini.Show();local m=Mini.GetFrame().Map;m.Viewport:SetSize(420,354);m:Refresh(true)
  S.player={map=1438,x=58,y=98};stub.advance(.21)
  local airborneView={map=m:GetMapID(),player=visible(m,destination(1438,58,98)),dest=visible(m,dest)}
  airborne=false;S.player={map=1438,x=58.4,y=93.93};stub.advance(.21)
  emit({airborne=airborneView,landed={map=m:GetMapID(),marker=m.FlightMarker:IsShown(),follow=m:GetFollow()}})
 `);
 assert.equal(out.airborne.player,true);assert.equal(out.airborne.dest,true);
 assert.deepEqual(out.landed,{map:1438,marker:false,follow:true});
});

test('manual zoom pause, explicit settings, hidden maps and full Planner remain independent',()=>{
 const [out]=run(`
  D.Show();local full=D.GetFrame().Map;full:ApplyViewState({zoom=4,follow=true});local fullMap=full:GetMapID()
  Mini.Show();local m=Mini.GetFrame().Map;m.Viewport:SetSize(420,354);m:Refresh(true)
  local fullHeld=full.zoom==4 and full:GetMapID()==1439
  m.ZoomOutButton:Click();local widened=visible(m,dest);m:ShowPlayer()
  m.ZoomInButton:Click();local manual=m.zoom;stub.advance(1)
  local paused=m.zoom==manual and m:GetMapID()==1414
  m:ShowPlayer();local resumed=visible(m,dest)
  m:SetFollow(false);local heldMap=m:GetMapID();S.player={map=1438,x=58,y=98};stub.advance(.21);local off=m:GetMapID()==heldMap and not m:GetFollow()
  m:SetFollow(true);m:SetAutoZoom(false);local autoOff=m:GetMapID()==1438 and not m:GetAutoZoom()
  Mini.Hide();D.Hide();S.clearReads();stub.advance(1)
  emit({paused=paused,widened=widened,resumed=resumed,off=off,autoOff=autoOff,hidden=S.reads.position,fullHeld=fullHeld,full={map=fullMap,zoom=full.zoom,auto=full:GetAutoZoom()}})
 `);
 assert.equal(out.paused,true);assert.equal(out.widened,true);assert.equal(out.resumed,true);assert.equal(out.off,true);assert.equal(out.autoOff,true);assert.equal(out.hidden,0);assert.equal(out.fullHeld,true);
 assert.deepEqual(out.full,{map:1439,zoom:1,auto:false}); // following a zone change retains the full map's existing behavior
});

test('same-zone flight fits locally; missing position or unknown destination never fabricates a remote camera',()=>{
 const [out]=run(`
  dest=destination(1439,45,55);Mini.Show();local m=Mini.GetFrame().Map;m.Viewport:SetSize(420,354);m:Refresh(true)
  local localFit=m:GetMapID()==1439 and visible(m,dest)
  Polestar.Maps.GetFlight=function()return nil end;local before=m.zoom;stub.advance(.21);local unknown=m.zoom==before
  S.player=nil;stub.advance(.21)
  emit({localFit=localFit,unknown=unknown,missing=m:GetMapID(),marker=m.FlightMarker:IsShown(),foreign=M.FlightFrame(1439,36,44,destination(1429,40,40))})
 `);
 assert.equal(out.localFit,true);assert.equal(out.unknown,true);assert.equal(out.missing,1439);assert.equal(out.marker,false);assert.equal(out.foreign,undefined);
});
