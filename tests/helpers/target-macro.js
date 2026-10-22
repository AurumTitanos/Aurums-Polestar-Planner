const fs=require('node:fs'),path=require('node:path');
const {STOCK}=require('./lua');
const version=/^## Version:\s*(.+)$/m.exec(fs.readFileSync(path.join(STOCK,'addon/Polestar/Polestar.toc'),'utf8'))[1].trim();
const guarded=version==='0.2.6';
module.exports={version,singleTarget:name=>guarded?`/cleartarget [nocombat]\n/targetexact ${name}\n/cleartarget [dead]`:`/targetexact ${name}`};
