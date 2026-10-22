'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');
const native = require('./fixtures/openmap/native-maps.json');

function lua(value) {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return `{${Object.entries(value).map(([k, v]) => `[${Array.isArray(value) ? +k + 1 : /^\d+$/.test(k) ? +k : JSON.stringify(k)}]=${lua(v)}`).join(',')}}`;
}

function run(script) {
  return runAddon({
    stubs: ['live-openmap.lua'],
    before: `openmapstub.install(${lua(native)})`,
    addons: [{ name: 'Polestar', files: ['Core/Init.lua', 'OpenMap/OpenMap.xml', 'UI/LiveOpenMap.lua'] }],
    script: `
      local F, OM = openmapstub, PolestarPlanner.LiveOpenMap
      Polestar.Compat={IsSecret=function(v) return v==F.secret end}
      local parent=CreateFrame('Frame',nil,UIParent);parent:SetSize(420,354)
      local r=OM.Create(parent);local v=F.view(1429,420,354,3);local bounds=F.bounds(1429)
      ${script}
    `,
  }).emitted;
}

test('a transient upstream view failure recovers on the same renderer without leaving background jobs behind', () => {
  const [out] = run(`
    local initial=r:Paint(1429,v,bounds)
    local S,canvas=r.S,r.canvas
    local sea=S.SetSea
    S.SetSea=function() error('temporary client map failure') end
    local failed=r:Paint(1429,v,bounds)
    local reason=r:Diagnostics().error
    local hidden=not canvas:IsShown()
    local pending=F.activeUpdates()
    S.SetSea=sea
    local recovered=r:Paint(1429,v,bounds)
    local same=r.S==S and r.canvas==canvas
    local diagnostics=r:Diagnostics()
    r:Hide()
    emit({initial=initial,failed=failed,reason=reason,hidden=hidden,pending=pending,
      recovered=recovered,same=same,diagnostics=diagnostics,afterHide=F.activeUpdates()})
  `);
  assert.equal(out.initial, true);
  assert.equal(out.failed, false);
  assert.match(out.reason, /temporary client map failure/);
  assert.equal(out.hidden, true);
  assert.equal(out.pending, 0);
  assert.equal(out.recovered, true, out.diagnostics.error);
  assert.equal(out.same, true, 'recovery must reuse its frames and independent closure');
  assert.equal(out.diagnostics.available, true);
  assert.equal(out.diagnostics.error, undefined);
  assert.equal(out.afterHide, 0);
});

test('unreadable continent corners cannot poison the original renderer projection cache', () => {
  const [out] = run(`
    local original=C_Map.GetWorldPosFromMapPos
    C_Map.GetWorldPosFromMapPos=function(id,p)
      return 0,{GetXY=function() return F.secret,F.secret end}
    end
    local first=r:Paint(1429,v,bounds)
    local rejected=r.ctx.Safe.XY({GetXY=function() return F.secret,F.secret end})==nil
    local before=r.S.FromYards(0,-8840.6,489.7)
    C_Map.GetWorldPosFromMapPos=original
    local u,vv=r.S.FromYards(0,-8840.6,489.7)
    local recovered=r:Paint(1429,v,bounds)
    emit({first=first,rejected=rejected,unreadable=before==nil,
      readable=type(u)=='number' and type(vv)=='number',recovered=recovered,diagnostics=r:Diagnostics()})
  `);
  assert.equal(out.rejected, true);
  assert.equal(out.unreadable, true);
  assert.equal(out.readable, true);
  assert.equal(out.recovered, true, out.diagnostics.error);
});

test('Teldrassil detail uses the repaired native mask and retries if only that new asset is unavailable', () => {
  const [out] = run(`
    local method=stub.Methods.SetTexture
    local missing=true
    stub.Methods.SetTexture=function(self,value,...)
      if missing and type(value)=='string' and value:find('NativeDetailLand',1,true) then return false end
      return method(self,value,...)
    end
    local view=F.view(1438,420,354,3,58.2,57.8)
    local failed=r:Paint(1438,view,F.bounds(1438))
    local reason=r:Diagnostics().error
    local pending=F.activeUpdates()
    missing=false
    local recovered=r:Paint(1438,view,F.bounds(1438))
    local native=0
    for _,texture in ipairs(F.textures(r.canvas,true)) do
      local mask=texture.mask
      local file=mask and mask:GetTexture()
      if type(file)=='string' and file:find('NativeDetailLand',1,true) then native=native+1 end
    end
    emit({failed=failed,reason=reason,pending=pending,recovered=recovered,native=native,diagnostics=r:Diagnostics()})
  `);
  assert.equal(out.failed, false);
  assert.match(out.reason, /detailed-island mask.*restart/);
  assert.equal(out.pending, 0);
  assert.equal(out.recovered, true, out.diagnostics.error);
  assert.ok(out.native > 0, 'actual native terrain textures must have the repaired alpha mask attached');
});
