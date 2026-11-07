#!/usr/bin/env python3
import hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parents[1]
base=json.loads((root/'docs/BUILD23_BASELINE.json').read_text())
allowed=set("""App/AppModel.swift App/Appearance.swift App/CameraControlEndpoint.swift App/CommissioningView.swift App/DebugFlowFixture.swift App/HeadphoneMotion.swift App/PocketCamera+Video.swift App/PocketCamera.swift App/SettingsView.swift App/ShootingDetails.swift App/Views.swift AppTests/CalibrationRecoveryTests.swift Sources/HeadLinkCore/FormalFollowProfile.swift UITests/ThemeLandscapeUITests.swift Vendor/OpenCine/HEADLINK_MODIFICATIONS.md Vendor/OpenCine/Sources/OpenCineDJI/GimbalNativeTargetStream.swift Vendor/OpenCine/Sources/OpenCineDJIApple/DjiAppleDatalink.swift Vendor/OpenCine/Sources/OpenCineDJIApple/DjiAppleSessionHeartbeat.swift Vendor/manifest.json project.yml scripts/check-recovery-scope.py""".split())
digest=lambda data:hashlib.sha256(data).hexdigest()
changed=[n for n,h in base['files'].items() if n not in allowed and (not (root/n).is_file() or digest((root/n).read_bytes())!=h)]
assert not changed,changed
project=(root/'project.yml').read_text().replace('MARKETING_VERSION: 1.4.0','MARKETING_VERSION: 1.3.0')
assert digest(project.encode())==base['files']['project.yml']
views=(root/'App/Views.swift').read_text()
renderer=views[views.index('struct PreviewSurface:'):views.index('func stateLabel(')]
ui=json.loads((root/'docs/UI_BASELINE_HASHES.json').read_text())
assert digest(renderer.encode())==ui['rendererSHA256']
assert views.count('PreviewSurface(runtime:model.camera.decoder)')==1
print(json.dumps({'baseline':base['commit'],'protected':len(base['files'])-len(allowed),'fixedTrackingMathUnchanged':True,'hardwareValidated':False},indent=2))
