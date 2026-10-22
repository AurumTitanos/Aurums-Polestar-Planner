#!/usr/bin/env python3
"""Build a source-visible install ZIP, deliberately excluding local media/saves."""
from pathlib import Path
import hashlib, zipfile
root=Path(__file__).resolve().parents[1]
addon=root/'addon/Polestar_Planner'
output=root/'.dist/Polestar_Planner-0.1.11.zip'
output.parent.mkdir(exist_ok=True)
allowed={'.lua','.xml','.toc','.md','.txt','.json'}
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for p in sorted(addon.rglob('*')):
  if not p.is_file():continue
  rel=p.relative_to(addon)
  if p.is_symlink() or rel.parts[0] in {'Media','Tools'}:continue
  if p.suffix not in allowed and p.name!='LICENSE':raise ValueError('Unexpected package file: '+str(rel))
  info=zipfile.ZipInfo('Polestar_Planner/'+rel.as_posix(),(2026,10,22,0,0,0))
  info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
  z.writestr(info,p.read_bytes())
sha=hashlib.sha256(output.read_bytes()).hexdigest()
(output.parent/'SHA256SUMS').write_text(sha+'  '+output.name+'\n')
print(output.name,output.stat().st_size,sha)
