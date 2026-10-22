'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {runAddon} = require('./helpers/lua');

function run(script) {
 return runAddon({stubs:['stub_ui.lua'],script:`
  uistub.install(); stub.login()
  local A=PolestarPlanner.Adapter
  local taxi=true
  Polestar.Compat.IsOnTaxi=function() return taxi end
  local node={id=27,c=1,wx=8643.6,wy=841}
  local name="Rut'theran Village"
  Polestar.Maps={GetFlight=function() return name,64,'estimate' end,
   Faction=function() return 1 end,
   TaxiNodeByName=function(n,f) if n=="Rut'theran Village" and f==1 then return 27 end end}
  Polestar.Nav.GetTravelData=function() return {taxiById={[27]=node}} end
  local geometry={legs={{kind='flight',current=true,pts={{1,100,200},{1,300,400}}}}}
  Polestar.Nav.GetRouteGeometry=function() return geometry end
  ${script}
 `}).emitted[0];
}

test('selected taxi destination wins over planned flight and is returned without borrowed state',()=>{
 const out=run(`
  local found=A.FlightDestination(geometry)
  found.wx=999
  emit({destination=A.FlightDestination(geometry),nodeX=node.wx,routeX=geometry.legs[1].pts[2][2]})
 `);
 assert.deepEqual(out,{destination:{c:1,wx:8643.6,wy:841,label:"Rut'theran Village"},nodeX:8643.6,routeX:300});
});

test('only active taxi state allows the helper to read flight state, including immediately after landing',()=>{
 const out=run(`
  taxi=false
  local reads=0
  Polestar.Maps.GetFlight=function() reads=reads+1; return name end
  local waiting=A.FlightDestination(geometry)
  taxi=true; local airborne=A.FlightDestination(geometry)
  taxi=false; local landed=A.FlightDestination(geometry)
  emit({waiting=waiting~=nil,airborne=airborne~=nil,landed=landed~=nil,reads=reads})
 `);
 assert.deepEqual(out,{waiting:false,airborne:true,landed:false,reads:1});
});

test('unknown actual destination can use the current flight endpoint, never a later flight or arbitrary guide target',()=>{
 const out=run(`
  name=nil
  local found=A.FlightDestination()
  geometry.legs={{kind='walk',current=true,pts={{1,10,20},{1,30,40}}},geometry.legs[1]}
  geometry.legs[2].current=false
  Polestar.Nav.GetTarget=function() error('guide departure target must not be read') end
  local walking=A.FlightDestination(geometry)
  geometry.legs[1].kind='boat'
  local boat=A.FlightDestination(geometry)
  geometry.legs={geometry.legs[2]}
  local later=A.FlightDestination(geometry)
  emit({found=found,walking=walking~=nil,boat=boat~=nil,later=later~=nil})
 `);
 assert.deepEqual(out,{found:{c:1,wx:300,wy:400,label:'Flight destination'},walking:false,boat:false,later:false});
});

test('an observed but unresolved taxi destination never borrows another planned endpoint',()=>{
 const out=run(`
  name='Unmapped actual destination'
  local unresolved=A.FlightDestination(geometry)
  name="Rut'theran Village"
  node.wx=0/0
  local invalid=A.FlightDestination(geometry)
  emit({unresolved=unresolved~=nil,invalid=invalid~=nil})
 `);
 assert.deepEqual(out,{unresolved:false,invalid:false});
});

test('missing optional flight APIs and failed reads degrade to current geometry or unknown safely',()=>{
 const out=run(`
  Polestar.Maps.GetFlight=function() error('unavailable during load') end
  local failed=A.FlightDestination(geometry)
  Polestar.Maps=nil
  local missing=A.FlightDestination(geometry)
  Polestar.Nav.GetRouteGeometry=function() error('route unavailable') end
  local none=A.FlightDestination()
  Polestar.Compat.IsOnTaxi=nil
  local unsupported=A.FlightDestination(geometry)
  emit({failed=failed,missing=missing,none=none~=nil,unsupported=unsupported~=nil})
 `);
 assert.deepEqual(out,{failed:{c:1,wx:300,wy:400,label:'Flight destination'},missing:{c:1,wx:300,wy:400,label:'Flight destination'},none:false,unsupported:false});
});

test('nonfinite and restricted coordinates cannot become a camera destination',()=>{
 const out=run(`
  local secret={}
  Polestar.Compat.IsSecret=function(v) return v==secret end
  node.wx=math.huge
  geometry.legs[1].pts[2][2]=0/0
  local infinite=A.FlightDestination(geometry)
  node.wx=secret
  geometry.legs[1].pts[2][2]=secret
  local restricted=A.FlightDestination(geometry)
  node.wx=8643.6
  taxi=secret
  local hidden=A.FlightDestination(geometry)
  emit({infinite=infinite~=nil,restricted=restricted~=nil,hidden=hidden~=nil})
 `);
 assert.deepEqual(out,{infinite:false,restricted:false,hidden:false});
});

test('an unobserved special taxi is unknown rather than guessed from the route goal',()=>{
 const out=run(`
  name=nil; geometry=nil
  Polestar.Nav.GetTarget=function() return {kind='fly',map=1450,x=44,y=45,label="Fly to Rut'theran Village"} end
  emit({known=A.FlightDestination()~=nil})
 `);
 assert.deepEqual(out,{known:false});
});

test('actual untouched stock flight tracker resolves the chosen endpoint and stops on landing',()=>{
 const out=runAddon({
  stubs:['stub_world.lua','stub_maps.lua'],
  before:'stub.maps.useWorld(); stub.maps.place(0,800)',
  stockFiles:['Core/Core.xml','Theme/Theme.xml','Nav/Nav.xml','Maps/Maps.xml','UI/UI.lua'],
  login:true,
  script:`
   local m=stub.maps
   Polestar.Nav.RegisterTravelData(m.travel,true)
   m.openTaxi(1,{2,3}); TakeTaxiNode(2); m.board(); stub.advance(.4)
   local found=PolestarPlanner.Adapter.FlightDestination()
   m.land()
   emit({found=found,landed=PolestarPlanner.Adapter.FlightDestination()~=nil})
  `,
 }).emitted[0];
 assert.deepEqual(out,{found:{c:0,wx:0,wy:-800,label:'East Hold'},landed:false});
});
