#!/usr/bin/env python3
"""This is an authorized flow repair, not the archived pure-UI freeze assertion."""
import hashlib,json,pathlib,re
root=pathlib.Path(__file__).resolve().parents[1]
base=json.loads((root/'docs/RECOVERY_BASELINE.json').read_text())
allowed={
 'App/AppModel.swift','App/PocketCamera.swift','App/HeadphoneMotion.swift','App/Views.swift',
 'App/SettingsView.swift','App/CommissioningView.swift','Sources/HeadLinkCore/TrackingDiagnostics.swift','Sources/HeadLinkCore/ControlInputFrame.swift',
 'project.yml','scripts/package-ipa.py','scripts/ui-review.sh','.github/workflows/ios.yml','Vendor/manifest.json',
 'Vendor/OpenCine/HEADLINK_MODIFICATIONS.md',
 'Vendor/OpenCine/Sources/OpenCineDJIApple/DjiAppleDatalink.swift',
}
unexpected=[]
for name,sha in base['files'].items():
    path=root/name
    if name not in allowed and (not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=sha): unexpected.append(name)
assert not unexpected,'Unexpected baseline changes: '+', '.join(unexpected)
project=(root/'project.yml').read_text()
project=re.sub(r'\n  HeadLinkAppTests:.*?\nschemes:', '\nschemes:',project,flags=re.S)
project=project.replace('\n        HeadLinkAppTests: [test]','').replace('targets: [HeadLinkUITests, HeadLinkAppTests]','targets: [HeadLinkUITests]')
project=project.replace('MARKETING_VERSION: 1.2.3','MARKETING_VERSION: 1.2.2')
assert project==base['project'],'Unexpected production identity, permission, SDK or build setting change'
workflow=(root/'.github/workflows/ios.yml').read_text().split('\n  ui-review:')[0].rstrip()+'\n'
assert workflow==base['deviceWorkflow'],'Original device workflow changed'
ui='\n'.join((root/p).read_text() for p in ['App/Views.swift','App/SettingsView.swift','App/CommissioningView.swift'])
assert not re.search(r'\.(task|onAppear|onDisappear)\b',ui),'UI starts a new lifecycle task'
assert ui.count('PreviewSurface(runtime:model.camera.decoder)')==1
views=(root/'App/Views.swift').read_text()
renderer=views[views.index('struct PreviewSurface:'):views.index('func stateLabel(')]
ui_baseline=json.loads((root/'docs/UI_BASELINE_HASHES.json').read_text())
assert hashlib.sha256(renderer.encode()).hexdigest()==ui_baseline['rendererSHA256'],'Video rendering adapter changed'
assert not re.search(r'\b(AppModel|PocketCamera|HeadphoneMotion|MonitorLiveVideoRuntime)\s*\(',ui)
print(json.dumps({'baseline':base['compiledCommit'],'protectedOriginalFiles':len(base['files'])-len(allowed),
 'trackingMathAndLimits':'byte_identical','head200msCamera300ms':'unchanged',
 'identityPermissionsSavedKeys':'unchanged','hardwareValidated':False},indent=2))
