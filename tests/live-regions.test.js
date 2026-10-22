'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {runAddon} = require('./helpers/lua');

function run(script) {
  return runAddon({addons:[{name:'Polestar',files:['Core/Init.lua','UI/LiveRegions.lua']}],script:`
    Polestar.Nav={RGB=function(name) if name=="arrow" then return 1,.8,.3 end return 1,.6,.35 end}
    local R=PolestarPlanner.LiveRegions.Create(UIParent)
    local map={art=true,bounds={c=1,left=100,top=100,kx=-.01,ky=-.01},
      View={width=100,height=100,offsetX=0,offsetY=0,drawWidth=100,drawHeight=100,scale=1}}
    local function region(x1,y1,x2,y2,goal,active)
      return {c=1,hull={100-y1,100-x1,100-y1,100-x2,100-y2,100-x2,100-y2,100-x1},
        goalIndex=goal,label="Mob "..goal,active=active,status="active"}
    end
    local function shown(list) local n=0 for _,v in ipairs(list) do if v:IsShown() then n=n+1 end end return n end
    local function lines() local out={} for i=1,R.lineCount do
      local l=R.Lines[i];out[i]={l.startPoint[3],-l.startPoint[4],l.endPoint[3],-l.endPoint[4]}
    end return out end
    ${script}`}).emitted[0];
}

test('grouped hulls project into terrain coordinates with a soft fill and active gold border',()=>{
  const out=run(`R:Refresh(map,{regions={region(10,20,40,60,1,true)}})
    local t=R.FillTextures[1]
    emit({count=#R.Regions,points=R.Regions[1].points,lines=lines(),fill=t.vertexColor,
      border=R.Lines[1].vertexColor,mouse=R.mouse,snap=t.snapToPixelGrid,offsets=t.vertexOffset})`);
  assert.equal(out.count,1);assert.deepEqual(out.points,[[10,20],[40,20],[40,60],[10,60]]);
  assert.equal(out.lines.length,4);assert.deepEqual(out.border,[1,.8,.3,.8]);
  assert.deepEqual(out.fill,[1,.8,.3,.12]);assert.equal(out.mouse,false);assert.equal(out.snap,false);
  assert.deepEqual(out.offsets,[0,0,0,0,0,0,0,0]);
});

test('viewport clipping preserves actual borders without drawing a false edge at the viewport boundary',()=>{
  const out=run(`R:Refresh(map,{regions={region(-20,20,40,80,1,true)}})
    emit({points=R.Regions[1].points,lines=lines(),hits=#R:HitTest(5,40),outside=#R:HitTest(-1,40)})`);
  assert.equal(out.lines.length,3);assert.equal(out.hits,1);assert.equal(out.outside,0);
  for(const line of out.lines) {
    assert.ok(line.every(v=>v>=0 && v<=100));
    assert.ok(!(line[0]===line[2] && line[0]<1),'a clipped edge must not become an invented region border');
  }
  assert.ok(out.points.every(p=>p[0]>=0 && p[0]<=100));
});

test('a region surrounding the view has a clipped fill and no invented border',()=>{
  const out=run(`R:Refresh(map,{regions={region(-20,-20,120,120,1,true)}})
    emit({regions=#R.Regions,lines=R.lineCount,fills=R.fillCount,hits=#R:HitTest(50,50),points=R.Regions[1].points})`);
  assert.equal(out.regions,1);assert.equal(out.lines,0);assert.equal(out.fills,1);assert.equal(out.hits,1);
  assert.ok(out.points.every(p=>p[0]>=0&&p[1]>=0&&p[0]<=100&&p[1]<=100));
});

test('hover reports every overlapping objective once and includes boundary hits',()=>{
  const out=run(`R:Refresh(map,{regions={region(10,10,80,80,1,true),region(20,20,90,90,2,false),region(25,25,70,70,1,true)}})
    local hits=R:HitTest(40,40)
    emit({labels={hits[1].label,hits[2].label},edge=#R:HitTest(10,20),outside=#R:HitTest(2,2),far=#R:HitTest(99,99)})`);
  assert.deepEqual(out.labels,['Mob 1','Mob 2']);assert.equal(out.edge,1);
  assert.equal(out.outside,0);assert.equal(out.far,0);
});

test('unchanged camera and scene reuse textures, toggle clears hit tests, and no update handler runs independently',()=>{
  const out=run(`local scene={regions={region(10,10,80,80,1,true)}}
    R:Refresh(map,scene);local paints=R.paints
    for i=1,10 do R:Refresh(map,scene) end
    local unchanged=R.paints
    R:SetEnabled(false)
    local disabled={fills=shown(R.FillTextures),lines=shown(R.Lines),hits=#R:HitTest(40,40)}
    R:SetEnabled(true);R:Refresh(map,scene)
    emit({paints=paints,unchanged=unchanged,disabled=disabled,enabled=R:GetEnabled(),hits=#R:HitTest(40,40),update=R:GetScript("OnUpdate")~=nil})`);
  assert.equal(out.paints,out.unchanged);assert.deepEqual(out.disabled,{fills:0,lines:0,hits:0});
  assert.equal(out.enabled,true);assert.equal(out.hits,1);assert.equal(out.update,false);
});

test('wrong-continent, invalid, outside and degenerate hulls draw nothing',()=>{
  const out=run(`local wrong=region(10,10,50,50,1,true);wrong.c=2
    local invalid=region(10,10,50,50,2,true);invalid.hull[2]=math.huge
    local bad={c=1,hull={1,2,3},goalIndex=3}
    local outside=region(110,110,150,150,4,true)
    local degenerate=region(10,10,10,60,5,true)
    R:Refresh(map,{regions={wrong,invalid,bad,outside,degenerate}})
    emit({regions=#R.Regions,fills=R.fillCount,lines=R.lineCount,hits=#R:HitTest(20,20)})`);
  assert.deepEqual(out,{regions:0,fills:0,lines:0,hits:0});
});

test('map letterboxing clips against terrain bounds instead of filling unused viewport space',()=>{
  const out=run(`map.View.offsetX=25;map.View.drawWidth=50
    R:Refresh(map,{regions={region(-20,-20,120,120,1,true)}})
    emit({points=R.Regions[1].points,left=#R:HitTest(10,50),center=#R:HitTest(50,50),right=#R:HitTest(90,50)})`);
  assert.ok(out.points.every(p=>p[0]>=25&&p[0]<=75));assert.equal(out.left,0);assert.equal(out.center,1);assert.equal(out.right,0);
});
