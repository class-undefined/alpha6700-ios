#!/usr/bin/env python3
# coding: utf-8
"""Print only provisioning dates; never print signing certificates or device IDs."""
import datetime, pathlib, plistlib, subprocess, sys
app=pathlib.Path(sys.argv[1])
data=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(app/'embedded.mobileprovision')],stderr=subprocess.DEVNULL))
for key in ('CreationDate','ExpirationDate'):
    value=data[key].replace(tzinfo=datetime.timezone.utc).astimezone()
    print('%s: %s' % (key,value.isoformat(timespec='seconds')))
print('Personal Team: %s' % data.get('LocalProvision',False))
