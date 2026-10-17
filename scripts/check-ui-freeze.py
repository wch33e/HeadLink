#!/usr/bin/env python3
"""Verify UI branch provenance and immutable business files against the verified build-8 snapshot."""
import hashlib,json,pathlib,re
root=pathlib.Path(__file__).resolve().parents[1]
data=json.loads((root/'docs/UI_BASELINE_HASHES.json').read_text())
assert data['baseline']=='3e48086e9a07bad6d0a5fedbaca248eb6cb7bf91'
changed=[p for p,h in data['protected'].items() if not (root/p).is_file() or hashlib.sha256((root/p).read_bytes()).hexdigest()!=h]
assert not changed, 'Frozen baseline changed: '+', '.join(changed)
views=(root/'App/Views.swift').read_text()
renderer=views[views.index('struct PreviewSurface:'):views.index('func stateLabel(')]
labels=views[views.index('func stateLabel('):]
assert hashlib.sha256(renderer.encode()).hexdigest()==data['rendererSHA256'], 'Video adapter changed'
assert hashlib.sha256(labels.encode()).hexdigest()==data['stateLabelsSHA256'], 'State meanings changed'
ui='\n'.join((root/p).read_text() for p in ['App/Views.swift','App/SettingsView.swift','App/CommissioningView.swift','App/UIStyle.swift'])
preferences=re.findall(r'@AppStorage\("([^\"]+)"\) private var \w+=(true|false)',ui)
assert set(preferences)==set(data['preferences'].items()), 'Preference key/default changed'
assert not re.search(r'\.(?:task|onAppear|onDisappear)\b',ui), 'Unexpected UI lifecycle side effect'
assert not re.search(r'\b(?:AppModel|PocketCamera|HeadphoneMotion|MonitorLiveVideoRuntime)\s*\(',ui), 'UI constructs a service'
assert views.count('PreviewSurface(runtime:model.camera.decoder)')==1, 'Multiple video view locations'
formats=set(re.findall(r'String\(format:"([^\"]+)"',ui))
assert formats==set(data['numberFormats']), 'Displayed number format changed'
project=(root/'project.yml').read_text()
project=re.sub(r'\n  HeadLinkUITests:.*?\nschemes:', '\nschemes:',project,flags=re.S)
project=project.split('\n  HeadLinkUIReview:')[0].rstrip()+'\n'
project=project.replace('MARKETING_VERSION: 1.2.2','MARKETING_VERSION: 1.2.0')
assert project==data['project'], 'Production target/SDK/identity changed beyond marketing version'
workflow=(root/'.github/workflows/ios.yml').read_text().split('\n  ui-review:')[0].rstrip()+'\n'
assert workflow==data['deviceWorkflow'], 'Existing device build workflow changed'
print(json.dumps({'baseline':data['baseline'],'unchangedOriginalFiles':len(data['protected']),
    'videoAdapter':'byte_identical','stateLabels':'byte_identical','preferenceKeysAndDefaults':'identical',
    'numberFormats':'identical','productionTarget':'identical_except_marketing_version','hardwareValidation':False},indent=2))
