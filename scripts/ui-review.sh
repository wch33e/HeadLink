#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ui-review
python3 scripts/check-recovery-scope.py
xcrun simctl list devices available --json > build/ui-review/available-devices.json
review_device=$(python3 - <<'PY'
import json,subprocess
d=json.load(open('build/ui-review/available-devices.json'))
items=[(runtime,item) for runtime,values in d['devices'].items() if 'iOS-' in runtime for item in values if item.get('isAvailable') and 'iPhone' in item['name']]
assert items, 'No available iPhone simulator runtime'
items.sort(key=lambda x:('iOS-26' not in x[0], 'SE' not in x[1]['name'], 'Pro Max' in x[1]['name'], x[1]['name']))
runtime,item=items[0]
# Hosted images can contain pre-created devices stuck waiting on BackBoard.
# Use the real installed model/runtime with a fresh data directory for this job.
review_name='HeadLink UI Review'
review_id=subprocess.check_output(['xcrun','simctl','create',review_name,item['deviceTypeIdentifier'],runtime],text=True,timeout=60).strip()
device={'name':review_name,'model':item['name'],'udid':review_id,'deviceTypeIdentifier':item['deviceTypeIdentifier']}
json.dump({'runtime':runtime,'device':device,'hardwareValidation':False},open('build/ui-review/simulator.json','w'),indent=2)
print(review_id)
PY
)
test_destination="platform=iOS Simulator,id=$review_device"
boot_review_device() {
  python3 - "$review_device" <<'PY'
import subprocess,sys
try:
    subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1],'-b'],check=True,timeout=180)
except subprocess.TimeoutExpired:
    print('Simulator boot exceeded 180 seconds; App tests did not pass by waiting.',flush=True)
    raise SystemExit(124)
PY
}
boot_review_device
prune_recordings() {
  python3 - "$1" <<'PY'
import pathlib,sys
for p in pathlib.Path(sys.argv[1]).rglob('*'):
    if p.is_file() and p.suffix.lower() in ('.mp4','.mov'):
        p.unlink()
PY
}
xcrun simctl ui "$review_device" appearance light
python3 scripts/monitor-theme-requests.py "$review_device" > build/ui-review/system-theme.log 2>&1 &
theme_monitor_pid=$!
trap 'kill "$theme_monitor_pid" 2>/dev/null || true' EXIT
review_status=0
xcodebuild -project HeadLink.xcodeproj -scheme HeadLinkUIReview -destination "$test_destination" \
  -derivedDataPath build/UIReview -resultBundlePath build/ui-review/navigation.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test | tee build/ui-review/navigation.log || review_status=$?
xcrun xcresulttool export attachments --path build/ui-review/navigation.xcresult --output-path build/ui-review/screenshots
prune_recordings build/ui-review/screenshots
if [ "$review_status" -ne 0 ]; then
  exit "$review_status"
fi
# Exercise the same real navigation at the system accessibility text size, without App launch hooks.
boot_review_device
xcrun simctl ui "$review_device" content_size accessibility-extra-extra-extra-large
large_text_status=0
xcodebuild -project HeadLink.xcodeproj -scheme HeadLinkUIReview -destination "$test_destination" \
  -derivedDataPath build/UIReview -resultBundlePath build/ui-review/large-text.xcresult \
  -only-testing:HeadLinkUITests/HeadLinkUITests/testLandscapeControlsRemainReachable \
  -only-testing:HeadLinkUITests/ThemeLandscapeUITests/testBothLandscapeDirectionsAndLeftHandedLayoutPreserveActivePipeline \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test-without-building | tee build/ui-review/large-text.log || large_text_status=$?
xcrun xcresulttool export attachments --path build/ui-review/large-text.xcresult --output-path build/ui-review/large-text-screenshots
prune_recordings build/ui-review/large-text-screenshots
exit "$large_text_status"
