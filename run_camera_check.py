#!/usr/bin/env python3
"""Read this task's camera credentials from Keychain and pipe them to Go."""
import argparse
import datetime
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("step", choices=["info", "liveview", "list", "thumbnail", "download", "resume-check", "reconnect", "iso-roundtrip", "capture-once"])
args = parser.parse_args()
credentials = subprocess.run([str(ROOT / "bin/SonyCameraAccess"), "--read"], capture_output=True)
if credentials.returncode:
    sys.exit("请先在本地运行 bin/SonyCameraAccess，填写相机访问认证信息。")
try:
    access = json.loads(credentials.stdout)
except ValueError:
    sys.exit("无法读取本地认证信息。")
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
out = ROOT / "evidence" / f"{args.step}-{stamp}"
try:
    result = subprocess.run([
        str(ROOT / "bin/camera-check"), "-step", args.step,
        "-out", str(out), "-guid-file", str(ROOT / ".local/initiator-guid")
    ], input=credentials.stdout, capture_output=True, timeout=140)
except subprocess.TimeoutExpired:
    sys.exit("验证进程超时，已终止；没有自动重试。")
for stream, dest in ((result.stdout, sys.stdout), (result.stderr, sys.stderr)):
    text = stream.decode(errors="replace")
    for secret in (access.get("password"), access.get("user")):
        if secret:
            text = text.replace(secret, "[redacted]")
    dest.write(text)
print(f"Evidence: {out}")
sys.exit(result.returncode)
