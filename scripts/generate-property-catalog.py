#!/usr/bin/env python3
# coding: utf-8
"""Extract display names only from a pinned MIT-licensed Sony property table.

This does not import support flags, ranges, datatypes or commands. Those must
come from the connected camera and the tested alpha2go protocol implementation.
"""
import json,pathlib,re,urllib.request
revision='0fe3c68516f8c0fe89c963437bbc385d68620b25'
base='https://raw.githubusercontent.com/mikefsq/ptp/'+revision+'/'
source=urllib.request.urlopen(base+'sony/props_gen.go',timeout=30).read().decode()
license_text=urllib.request.urlopen(base+'LICENSE',timeout=30).read().decode()
rows=re.findall(r'^\s*Prop\w+\s+Prop\s*=\s*(0x[0-9A-Fa-f]+)\s*//\s*(\S+)',source,re.M)
names={str(int(code,16)):name for code,name in rows if not name.lower().startswith(('reserved','priv'))}
if len(names)<600: raise SystemExit('Unexpected upstream table shape; inspect before regenerating.')
root=pathlib.Path(__file__).resolve().parents[1]/'mobile/core/catalog'
root.mkdir(parents=True,exist_ok=True)
(root/'names.json').write_text(json.dumps(names,indent=2,sort_keys=True)+'\n')
(root/'LICENSE').write_text(license_text)
(root/'SOURCE.txt').write_text('Display names extracted from '+base+'sony/props_gen.go\nCopyright (c) 2026 mikefsq. MIT License; see LICENSE.\nNo model support flags or write constraints are imported.\n')
print('Wrote %d display names.' % len(names))
