'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {runAddon}=require('./helpers/lua');
function run(script,setup=''){
 return runAddon({stubs:['stub_ui.lua','live-dashboard.lua'],script:`uistub.install();livestub.install();${setup};stub.login();uistub.setGuide(uistub.elwynn,3);local Mini,S=PolestarPlanner.LiveMiniMap,livestub;local function showMini()Mini.Show();local m=Mini.GetFrame().Map;m.Viewport:SetSize(420,354);m:Refresh(true);end;${script}`}).emitted;
}
const party=`
local members={party1={x=.4,y=.4,name='Tank',class='WARRIOR'},party2={x=.5,y=.45,name='Mage',class='MAGE'}}
local partyReads=0
IsInRaid=function()return false end
GetNumSubgroupMembers=function()return 2 end
UnitExists=function(u)return members[u]~=nil end
UnitIsConnected=function()return true end
UnitIsUnit=function(a,b)return a==b end
UnitName=function(u)return members[u] and members[u].name or 'Player' end
UnitClass=function(u)return 'Class',members[u] and members[u].class or 'DRUID' end
RAID_CLASS_COLORS={WARRIOR={r=.78,g=.61,b=.43},MAGE={r=.25,g=.78,b=.92}}
local basePos=C_Map.GetPlayerMapPosition
C_Map.GetPlayerMapPosition=function(map,u)
 if members[u] then partyReads=partyReads+1;return {x=members[u].x,y=members[u].y} end
 return basePos(map,u)
end
`;
test('party members appear with class colors and hover names, update positions, and disappear when leaving',()=>{
 const [out]=run(`showMini();local m=Mini.GetFrame().Map;local p=m.PartyMarkers[1]
 local initial={shown=p:IsShown(),name=p.unitName,count=#m.PartyMarkers,x=p.mapX,y=p.mapY,color={p.Icon:GetVertexColor()}}
 members.party1.x=.45;m:Refresh(false);local moved=p.mapX
 GetNumSubgroupMembers=function()return 0 end;m:Refresh(false)
 emit({initial=initial,moved=moved,removed=not p:IsShown() and not m.PartyMarkers[2]:IsShown()})`,party);
 assert.deepEqual(out.initial,{shown:true,name:'Tank',count:2,x:40,y:40,color:[.78,.61,.43,1]});assert.equal(out.moved,45);assert.equal(out.removed,true);
});
test('unavailable, zero and secret party coordinates never become map pins; hidden viewers stop sampling',()=>{
 const [out]=run(`members.party1.x=S.secret;members.party2.x=0;members.party2.y=0
 showMini();local m=Mini.GetFrame().Map;local empty=#m.PartyMarkers==0
 members.party1.x=.4;members.party2.x=.5;members.party2.y=.45;m:Refresh(false)
 Mini.Hide();local before=partyReads;stub.advance(2)
 emit({empty=empty,stopped=partyReads==before})`,party);
 assert.deepEqual(out,{empty:true,stopped:true});
});
const instance=`
local inInstance=true
IsInInstance=function()return inInstance,'party' end
GetInstanceInfo=function()return 'Ruins of Lordaeron','party',1,'Normal',5,0,false,2999 end
UnitPosition=function()return nil end
`;
test('entering Ruins opens actual client terrain without a C_Map instance definition or readable positions, then restores outdoor terrain',()=>{
 const [out]=run(`showMini();local m=Mini.GetFrame().Map
 local ids={};for _,tile in ipairs(m.Tiles)do if tile:IsShown()then ids[#ids+1]=tile:GetTexture() end end
 local inside={map=m:GetMapID(),name=m.Zone:GetText(),tiles=#ids,expected=#PolestarPlanner.LiveInstanceMaps[2999].tiles,player=m.PlayerMarker:IsShown(),empty=m.Empty:IsShown(),art=m.art.instance,bounds=m.bounds.c}
 inInstance=false;m:Refresh(true)
 emit({inside=inside,outside={map=m:GetMapID(),native=m.art.instance or false}})`,instance);
 assert.equal(out.inside.map,-2999);assert.equal(out.inside.name,'Ruins of Lordaeron');assert.equal(out.inside.tiles,out.inside.expected);assert.equal(out.inside.empty,false);assert.equal(out.inside.player,false);assert.equal(out.inside.art,true);assert.equal(out.inside.bounds,2999);assert.deepEqual(out.outside,{map:1429,native:false});
});
test('readable instance coordinates project against its own terrain and never use an outdoor position',()=>{
 const [out]=run(`local e=PolestarPlanner.LiveInstanceMaps[2999]
 UnitPosition=function()return e.top+(e.bottom-e.top)*.25,e.left+(e.right-e.left)*.75,0,2999 end
 showMini();local m=Mini.GetFrame().Map
 emit({map=m:GetMapID(),x=m.playerX,y=m.playerY,shown=m.PlayerMarker:IsShown()})`,instance);
 assert.equal(out.map,-2999);assert.ok(Math.abs(out.x-75)<.0001);assert.ok(Math.abs(out.y-25)<.0001);assert.equal(out.shown,true);
});
test('native dungeon art renders partial tiles and follows the reported floor with no outdoor projection',()=>{
 const [out]=run(`showMini();local m=Mini.GetFrame().Map
 emit({map=m:GetMapID(),native=m.art.native,tiles=m.tileCount,worldBounds=m.bounds or false,empty=m.Empty:IsShown(),lastUV=m.Tiles[4].texCoord})`,`
 livestub.maps[9990]={name='Dungeon floor',mapID=9990,mapType=4,parentMapID=0};livestub.player={map=9990,x=50,y=50}
 C_Map.GetMapArtLayers=function()return {{layerWidth=300,layerHeight=300,tileWidth=256,tileHeight=256}}end
 C_Map.GetMapArtLayerTextures=function()return {101,102,103,104}end
 `);
 assert.equal(out.map,9990);assert.equal(out.native,true);assert.equal(out.tiles,4);assert.equal(out.worldBounds,false);assert.equal(out.empty,false);assert.ok(out.lastUV.includes(44/256));
});
test('Dungeon Scout interior reference opens automatically and exposes floor selection without guessed player dots',()=>{
 const [out]=run(`showMini();local m=Mini.GetFrame().Map
 local first={map=m:GetMapID(),reference=m.art.reference,player=m.PlayerMarker:IsShown(),floors=#m.instanceFloors,tiles=m.tileCount}
 m:ShowLayers();local menu=PolestarPlanner.Widgets.GetMenu and PolestarPlanner.Widgets.GetMenu()
 m.instanceFloor=2;m.artDirty=true;m:Refresh(true)
 emit({first=first,second=m.art.tiles[1],source=PolestarPlanner.LiveInstanceMaps[349].floors[2].tiles[1]})`,`
 IsInInstance=function()return true,'party' end
 GetInstanceInfo=function()return 'Maraudon','party',1,'Normal',5,0,false,349 end
 C_AddOns=C_AddOns or {};C_AddOns.IsAddOnLoaded=function(name)return name=='ForeverDungeonScout' end
 UnitPosition=function()return 100,100,0,349 end
 `);
 assert.equal(out.first.map,-349);assert.equal(out.first.reference,true);assert.equal(out.first.player,false);assert.ok(out.first.floors>1);assert.equal(out.first.tiles,12);assert.equal(out.second,out.source);
});

test('raid dots exclude the player and preserve the other member identity',()=>{
 const [out]=run(`members.raid1=members.party1;members.raid2=members.party2
 IsInRaid=function()return true end;GetNumGroupMembers=function()return 2 end
 UnitIsUnit=function(a,b)return a=='raid1' and b=='player' end
 showMini();local m=Mini.GetFrame().Map;emit({count=#m.PartyMarkers,name=m.PartyMarkers[1].unitName,shown=m.PartyMarkers[1]:IsShown()})`,party);
 assert.deepEqual(out,{count:1,name:'Mage',shown:true});
});
test('an unsupported instance shows an explicit unavailable view rather than a stale outdoor map',()=>{
 const [out]=run(`showMini();local m=Mini.GetFrame().Map;emit({map=m:GetMapID(),art=m.art or false,empty=m.Empty:IsShown(),text=m.Empty:GetText(),player=m.PlayerMarker:IsShown()})`,`
 IsInInstance=function()return true,'party' end
 GetInstanceInfo=function()return 'Unknown instance','party',1,'Normal',5,0,false,99999 end
 `);
 assert.equal(out.map,-99999);assert.equal(out.art,false);assert.equal(out.empty,true);assert.match(out.text,/Dungeon map unavailable/);assert.equal(out.player,false);
});
