'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {runAddon} = require('./helpers/lua');

const fixture = `
uistub.install(); stub.login()
local S = PolestarPlanner.TravelStatus
local taxi, ride, npc = false, nil, 11800
Polestar.Compat.IsOnTaxi=function() return taxi end
Polestar.Compat.GetNpcID=function() return npc end
Polestar.Compat.GetPlayerInfo=function() return {class='DRUID',faction='Alliance'} end
Polestar.Transit={Riding=function() return ride end}
local function shown() return S.frame and S.frame:IsShown() or false end
local function text() return S.frame and S.frame.Title:GetText() end
local function detail() return S.frame and S.frame.Detail:GetText() end
`;
function run(script, options={}) {
 const setup=options.fullCore ? fixture.replace('uistub.install(); stub.login()', 'stub.login()') : fixture;
 return runAddon({...options,stubs:[options.fullCore ? 'stub_world.lua' : 'stub_ui.lua'],script:setup+script}).emitted[0];
}

test('Silva gossip flight wakes when the taxi flag lags control loss, with honest elapsed time',()=>{
 const out=run(`
  stub.fire('GOSSIP_SHOW'); stub.fire('GOSSIP_CLOSED'); stub.fire('PLAYER_CONTROL_LOST')
  stub.advance(.5); local before=shown()
  taxi=true; stub.advance(.5)
  local title, first=text(),detail()
  stub.advance(3)
  local later=detail()
  taxi=false; stub.fire('PLAYER_CONTROL_GAINED'); stub.advance(.3)
  emit({before=before,title=title,first=first,later=later,landed=not shown(),idle=not S.driver:IsShown()})
 `);
 assert.deepEqual(out,{before:false,title:"Flight to Rut'theran Village",first:'Elapsed 0:00',later:'Elapsed 0:03',landed:true,idle:true});
});

test('control loss alone expires, and a later unrelated flight is never named Silva',()=>{
 const out=run(`
  stub.fire('GOSSIP_SHOW'); stub.fire('GOSSIP_CLOSED'); stub.fire('PLAYER_CONTROL_LOST')
  stub.advance(11); local expired=not S.driver:IsShown() and not shown()
  taxi=true; stub.fire('PLAYER_CONTROL_LOST'); stub.advance(.3)
  emit({expired=expired,title=text(),detail=detail()})
 `);
 assert.deepEqual(out,{expired:true,title:'In flight',detail:'Elapsed 0:00'});
});

test('stock flight timer wins, the fallback resumes if needed, and core-disabled timers stay hidden',()=>{
 const out=run(`
  local stock=CreateFrame('Frame','PolestarFlightTimer'); stock:Show()
  taxi=true; stub.fire('PLAYER_CONTROL_LOST'); stub.advance(.3)
  local stockWins=not shown()
  stock:Hide(); stub.advance(.3); local fallback=shown()
  Polestar.Set('maps.flightTimer',false); stub.advance(.3)
  emit({stockWins=stockWins,fallback=fallback,disabled=not shown()})
 `);
 assert.deepEqual(out,{stockWins:true,fallback:true,disabled:true});
});

test('only stock-identified boat travel displays an ETA, and the stock arrival banner wins',()=>{
 const out=run(`
  Polestar.Fire('NAV_TRANSIT'); local unknown=not shown()
  ride={kind='boat',route=10,dock='Stormwind Harbor',arriveIn=120}
  Polestar.Fire('NAV_TRANSIT'); local title,eta=text(),detail()
  local stock=CreateFrame('Frame','PolestarTransitAlert'); stock:Show()
  stub.advance(.3); local suppressed=not shown()
  stock:Hide(); ride.arriveIn=119; stub.advance(.3); local resumed=shown()
  ride=nil; stub.advance(.3)
  emit({unknown=unknown,title=title,eta=eta,suppressed=suppressed,resumed=resumed,cleared=not shown(),idle=not S.driver:IsShown()})
 `);
 assert.deepEqual(out,{unknown:true,title:'Boat to Stormwind Harbor',eta:'Arrives in 2:00',suppressed:true,resumed:true,cleared:true,idle:true});
});

test('a loop rolling to its next stop does not pretend the docked boat has departed',()=>{
 const out=run(`
  ride={kind='boat',route=10,dock='Stormwind Harbor',arriveIn=1}
  Polestar.Fire('NAV_TRANSIT'); stub.advance(1.2)
  ride.dock='Auberdine'; ride.arriveIn=180; stub.advance(.3)
  local docked=not shown()
  ride=nil; stub.advance(.3)
  ride={kind='boat',route=10,dock='Auberdine',arriveIn=100}; Polestar.Fire('NAV_TRANSIT')
  emit({docked=docked,nextRide=shown(),title=text()})
 `);
 assert.deepEqual(out,{docked:true,nextRide:true,title:'Boat to Auberdine'});
});

test('boat fallback respects existing alert preferences and rejects restricted values during combat',()=>{
 const out=run(`
  ride={kind='boat',route=10,dock='Stormwind Harbor',arriveIn=120}
  Polestar.Set('nav.alerts',false); Polestar.Fire('NAV_TRANSIT'); local disabled=not shown()
  Polestar.Set('nav.alerts',true); Polestar.Set('nav.alertBanner',false); stub.advance(.3)
  local bannerDisabled=not shown()
  Polestar.Set('nav.alertBanner',true); stub.advance(.3); local restored=shown()
  local secret={}; Polestar.Compat.IsSecret=function(v) return v==secret end
  stub.inCombat=true; ride.arriveIn=secret; stub.advance(.3)
  local restricted=not shown()
  ride.arriveIn=100; ride.dock=secret; Polestar.Fire('NAV_TRANSIT')
  emit({disabled=disabled,bannerDisabled=bannerDisabled,restored=restored,restricted=restricted,dockHidden=not shown()})
 `);
 assert.deepEqual(out,{disabled:true,bannerDisabled:true,restored:true,restricted:true,dockHidden:true});
});

test('missing optional contracts, invalid transport ETAs and disabled companion degrade safely',()=>{
 const out=run(`
  ride={kind='boat',route=10,dock='Stormwind',arriveIn=0/0}; Polestar.Fire('NAV_TRANSIT')
  local bad=not shown()
  Polestar.Transit=nil; Polestar.Compat.IsOnTaxi=nil; Polestar.Compat.GetNpcID=nil
  stub.fire('GOSSIP_SHOW'); stub.fire('PLAYER_CONTROL_LOST'); stub.advance(11)
  local missing=not shown() and not S.driver:IsShown()
  Polestar.Compat.IsOnTaxi=function() return true end
  stub.fire('PLAYER_CONTROL_LOST'); PolestarPlanner.Set('travelStatus.enabled',false)
  emit({bad=bad,missing=missing,disabled=not shown() and not S.driver:IsShown()})
 `);
 assert.deepEqual(out,{bad:true,missing:true,disabled:true});
});

test('the shipped companion detects delayed taxi state with the full untouched stock TOC',()=>{
 const out=run(`
  stub.fire('GOSSIP_SHOW'); stub.fire('GOSSIP_CLOSED'); stub.fire('PLAYER_CONTROL_LOST')
  stub.advance(.4); taxi=true; stub.advance(.4)
  emit({shown=shown(),title=text(),stock=PolestarFlightTimer and PolestarFlightTimer:IsShown() or false})
 `,{fullCore:true});
 assert.deepEqual(out,{shown:true,title:"Flight to Rut'theran Village",stock:false});
});
