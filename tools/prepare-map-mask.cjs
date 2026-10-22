#!/usr/bin/env node
'use strict';
// AurumTitanos, 2026. GPL-3.0-only. Runs locally; no downloads or game control.
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {nativeDetailMask,tgaAlpha}=require('./native-mask.cjs');
function prepare(openmap, planner) {
  const provenance=require('../addon/Polestar_Planner/OpenMap/provenance.json');
  const read=(name)=>{
    const source='OpenMap/Media/Textures/'+name;
    const expected=provenance.files.find(f=>f.source===source);
    if(!expected)throw new Error('Missing pinned mask provenance: '+name);
    const file=path.join(openmap,'Media/Textures',name);
    if(fs.statSync(file).size>16*1024*1024)throw new Error('Unexpected mask size');
    const bytes=fs.readFileSync(file);
    if(crypto.createHash('sha256').update(bytes).digest('hex')!==expected.sha256)
      throw new Error('OpenMap masks differ from the supported version; no output written: '+name);
    return bytes;
  };
  const continent=read('MapLand/1414.tga'),island=read('MapZoneLand/1438.tga');
  const toc=path.join(planner,'Polestar_Planner.toc');
  if(!fs.existsSync(toc))throw new Error('Planner destination must contain Polestar_Planner.toc');
  const output=path.join(planner,'Media/OpenMap/Textures/NativeDetailLand/1414.tga');
  const bytes=nativeDetailMask(tgaAlpha(continent),tgaAlpha(island));
  fs.mkdirSync(path.dirname(output),{recursive:true});
  fs.writeFileSync(output,bytes);
  return {bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')};
}
if(require.main===module){
  const [source,destination]=process.argv.slice(2);
  if(!source||!destination){console.error('Usage: node tools/prepare-map-mask.cjs <installed-OpenMap-folder> <installed-Polestar_Planner-folder>');process.exitCode=1;}
  else {try {const result=prepare(path.resolve(source),path.resolve(destination));console.log('Created local island mask ('+result.bytes+' bytes). Restart WoW. No artwork was uploaded.');}
    catch(e){console.error(e.message);process.exitCode=1;}}
}
module.exports={prepare};
