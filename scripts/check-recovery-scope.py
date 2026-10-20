#!/usr/bin/env python3
import hashlib,json,pathlib,re,plistlib
root=pathlib.Path(__file__).resolve().parents[1]
base=json.loads((root/'docs/BUILD20_BASELINE.json').read_text())
allowed={"App/AppModel.swift","App/PocketCamera.swift","App/Views.swift","App/HeadLinkApp.swift","App/UIStyle.swift","App/SettingsView.swift","App/CommissioningView.swift","App/Info.plist","App/DebugFlowFixture.swift","project.yml","scripts/check-recovery-scope.py","scripts/ui-review.sh","UITests/HeadLinkUITests.swift","AppTests/CalibrationRecoveryTests.swift"}
changed=[]
for name,sha in base['files'].items():
 p=root/name
 if name not in allowed and (not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=sha):changed.append(name)
assert not changed,changed
project=(root/'project.yml').read_text().replace('MARKETING_VERSION: 1.3.0','MARKETING_VERSION: 1.2.4')
project=project.replace('        UILaunchScreen: {}','        UILaunchScreen: {}\n        UIUserInterfaceStyle: Dark')
assert hashlib.sha256(project.encode()).hexdigest()==base['files']['project.yml'],'Production settings changed beyond authorized theme/version'
views=(root/'App/Views.swift').read_text()
renderer=views[views.index('struct PreviewSurface:'):views.index('func stateLabel(')]
ui=json.loads((root/'docs/UI_BASELINE_HASHES.json').read_text())
assert hashlib.sha256(renderer.encode()).hexdigest()==ui['rendererSHA256']
assert views.count('PreviewSurface(runtime:model.camera.decoder)')==1
for name in ['App/Views.swift','App/SettingsView.swift','App/ShootingDetails.swift']:
 assert not re.search(r'\.(task|onAppear|onDisappear)\b',(root/name).read_text())
assert 'UIUserInterfaceStyle' not in plistlib.loads((root/'App/Info.plist').read_bytes())
assert '.preferredColorScheme(.dark)' not in (root/'App/HeadLinkApp.swift').read_text()
print(json.dumps({'baseline':base['sourceCommit'],'protectedFiles':len(base['files'])-len(allowed),'trackingMathParametersFreshness':'byte_identical','recoveryAndVideo':'byte_identical','previewSurface':'byte_identical','hardwareValidated':False},indent=2))
