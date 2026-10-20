#!/usr/bin/env python3
"""CI host only: apply a REAL simulator system appearance on an explicit DEBUG UI-test request.
No app-side system appearance override or polling is used. Never runs on a phone/Release app.
"""
import json,pathlib,subprocess,sys,time
udid=sys.argv[1];seen=None;container=None
for _ in range(1800):
    try:
        if container is None:
            r=subprocess.run(['xcrun','simctl','get_app_container',udid,'org.headlink.personal','data'],capture_output=True,text=True,timeout=10)
            if r.returncode == 0: container=pathlib.Path(r.stdout.strip())
        if container:
            p=container/'Documents/HeadLinkThemeRequest.json'
            if p.is_file():
                d=json.loads(p.read_text())
                if d.get('nonce') != seen and d.get('mode') in ('light','dark'):
                    subprocess.run(['xcrun','simctl','ui',udid,'appearance',d['mode']],check=True,timeout=15)
                    ack=container/'Documents/HeadLinkThemeAck.json'
                    temp=ack.with_suffix('.tmp');temp.write_text(json.dumps(d));temp.replace(ack)
                    seen=d['nonce'];print('Applied actual simulator system appearance:',d['mode'],flush=True)
    except (OSError,ValueError,subprocess.SubprocessError) as e:
        print(type(e).__name__,flush=True)
    time.sleep(0.5)
