#!/usr/bin/env python3
# coding: utf-8
"""Move this project's existing Keychain credentials into the installed app.

Credentials are never printed or passed as command-line arguments. The one-time
file is written with mode 0600 in a private temporary directory, copied through
Apple's paired device service, then deleted locally. The app consumes and removes
its copy on its next launch, saving to ThisDeviceOnly Keychain storage.
"""
import argparse,json,os,pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('device')
p.add_argument('--bundle-id',default='com.classundefined.alpha6700')
a=p.parse_args()
result=subprocess.run([str(root/'bin/SonyCameraAccess'),'--read'],capture_output=True,check=True)
access=json.loads(result.stdout)
if not all(access.get(k) for k in ('host','user','password','fingerprint')):
    raise SystemExit('Existing Keychain item is incomplete.')
with tempfile.TemporaryDirectory(prefix='alpha-access-') as directory:
    path=pathlib.Path(directory)/'AccessImport.json'
    fd=os.open(str(path),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as f: f.write(result.stdout)
    subprocess.run(['xcrun','devicectl','device','copy','to','--device',a.device,'--source',str(path),'--destination','Documents/AccessImport.json','--domain-type','appDataContainer','--domain-identifier',a.bundle_id,'--quiet'],check=True)
print('Access information copied. Relaunch the app to move it into iOS Keychain.')
