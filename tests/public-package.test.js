'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {nativeDetailMask,tgaAlpha}=require('../tools/native-mask.cjs');
const root=path.resolve(__dirname,'..');
test('public TOC excludes all personal macro-transfer modules',()=>{
 const toc=fs.readFileSync(path.join(root,'addon/Polestar_Planner/Polestar_Planner.toc'),'utf8');
 assert.doesNotMatch(toc,/MacroTransfer|Tools\\/);
 assert.match(toc,/## Dependencies: Polestar/);
 for(const entry of toc.split(/\r?\n/).filter(s=>s.trim()&&!s.startsWith('#')))
  assert.ok(fs.existsSync(path.join(root,'addon/Polestar_Planner',entry.replaceAll('\\','/'))),entry);
});
test('public rendering reads dependency media, and private artwork is not required for basic terrain',()=>{
 const theme=fs.readFileSync(path.join(root,'addon/Polestar_Planner/Theme/Theme.lua'),'utf8');
 const map=fs.readFileSync(path.join(root,'addon/Polestar_Planner/UI/LiveOpenMap.lua'),'utf8');
 assert.ok(theme.includes('Interface\\\\AddOns\\\\Polestar\\\\Media'));
 assert.ok(map.includes('Interface\\\\AddOns\\\\OpenMap\\\\Media'));
 assert.match(map,/Install OpenMap/);
});
test('local mask generator preserves opaque land and creates valid top-left TGA from synthetic inputs',()=>{
 const land={width:8,height:8,alpha:new Uint8Array(64).fill(255)};
 const island={width:8,height:8,alpha:new Uint8Array(64).fill(0)};
 const result=nativeDetailMask(land,island);
 const decoded=tgaAlpha(result);
 assert.equal(decoded.width,8);assert.equal(decoded.height,8);
 assert.ok(decoded.alpha.every(a=>a===255));
 assert.equal(result[2],2);assert.equal(result[16],32);assert.equal(result[17],40);
});
