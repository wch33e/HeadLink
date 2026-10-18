#!/usr/bin/env python3
"""Only package an inspected physical-device build. Never accept a simulator app."""
import datetime, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys
app=pathlib.Path(sys.argv[1]).resolve(); out=pathlib.Path(sys.argv[2]).resolve()
assert app.is_dir() and app.suffix=='.app', 'Missing device .app'
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info.get('CFBundleIdentifier')=='org.headlink.personal', 'Unexpected bundle identifier'
assert info.get('CFBundleShortVersionString') and '$(' not in info['CFBundleShortVersionString'], 'Unresolved app version'
if os.environ.get('GITHUB_RUN_NUMBER'):
    assert info.get('CFBundleVersion')==os.environ['GITHUB_RUN_NUMBER'], 'Build number must match this workflow run'
assert info.get('CFBundleSupportedPlatforms')==['iPhoneOS'], 'Not an iPhoneOS build'
assert info.get('DTPlatformName')=='iphoneos', 'Simulator or unknown platform'
assert not list(app.glob('PlugIns/*.appex')), 'Unexpected extension'
for key in ('NSMotionUsageDescription','NSBluetoothAlwaysUsageDescription','NSLocalNetworkUsageDescription'):
    assert info.get(key), f'Missing permission description: {key}'
assert not info.get('UIBackgroundModes'), 'Unexpected background mode'
assert not info.get('NSCameraUsageDescription') and not info.get('NSMicrophoneUsageDescription'), 'Unexpected phone camera/microphone permission'
executables=[app/info['CFBundleExecutable']]
for framework in app.glob('Frameworks/*.framework'):
    fi=plistlib.loads((framework/'Info.plist').read_bytes()); executables.append(framework/fi['CFBundleExecutable'])
executables+=list(app.glob('Frameworks/*.dylib'))
for binary in executables:
    arch=subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()
    assert 'arm64' in arch.split() and 'x86_64' not in arch.split(), f'Wrong architectures: {binary.name} {arch}'
    load=subprocess.check_output(['xcrun','vtool','-show-build',str(binary)],text=True)
    assert 'IOSSIMULATOR' not in load and 'platform IOS' in load, f'Not iOS Mach-O: {binary.name}'
    signing=subprocess.run(['codesign','-d','--entitlements',':-',str(binary)],capture_output=True)
    assert b'com.apple.developer.networking.HotspotConfiguration' not in signing.stdout+signing.stderr, 'Unexpected Hotspot entitlement'
    linked=subprocess.check_output(['otool','-L',str(binary)],text=True)
    for line in linked.splitlines()[1:]:
        path=line.strip().split(' (')[0]
        if path.startswith('@rpath/'):
            relative=path[len('@rpath/'):]
            assert (app/'Frameworks'/relative).exists() or relative.startswith('libswift'), f'Missing embedded dependency {relative}'
staging=out/'ipa-staging'
if os.environ.get('GITHUB_SHA'):
    provenance={'commit':os.environ['GITHUB_SHA'],'branch':os.environ.get('GITHUB_REF_NAME','unavailable'),
                'run':os.environ['GITHUB_RUN_NUMBER']}
    (app/'BuildProvenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
assert not staging.exists(), 'Staging already exists; use a clean build output'
(staging/'Payload').mkdir(parents=True)
shutil.copytree(app,staging/'Payload'/app.name)
ipa=out/'HeadLink-unsigned.ipa'
subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent','Payload',str(ipa)],cwd=staging,check=True)
sha=hashlib.sha256(ipa.read_bytes()).hexdigest()
(out/'SHA256SUMS').write_text(sha+'  '+ipa.name+'\n')
metadata={'signature':'UNSIGNED; local signing required','commit':os.environ.get('GITHUB_SHA','local-uncommitted'),
          'branch':os.environ.get('GITHUB_REF_NAME'),
          'run':os.environ.get('GITHUB_RUN_NUMBER'), 'createdUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'sha256':sha,'bundleID':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],
          'buildVersion':info['CFBundleVersion'],'minimumOS':info['MinimumOSVersion'],
          'sdk':info.get('DTSDKName'),'architectures':'arm64','hardwareValidated':False}
(out/'build-metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(ipa)
