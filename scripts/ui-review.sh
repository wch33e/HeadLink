#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ui-review
python3 scripts/check-ui-freeze.py
xcrun simctl list devices available --json > build/ui-review/available-devices.json
review_device=$(python3 - <<'PY'
import json
d=json.load(open('build/ui-review/available-devices.json'))
items=[(runtime,item) for runtime,values in d['devices'].items() if 'iOS-' in runtime for item in values if item.get('isAvailable') and 'iPhone' in item['name']]
assert items, 'No available iPhone simulator runtime'
items.sort(key=lambda x:('iOS-26' not in x[0], 'SE' not in x[1]['name'], 'Pro Max' in x[1]['name'], x[1]['name']))
runtime,item=items[0]
json.dump({'runtime':runtime,'device':item,'hardwareValidation':False},open('build/ui-review/simulator.json','w'),indent=2)
print(item['udid'])
PY
)
test_destination="platform=iOS Simulator,id=$review_device"
xcrun simctl bootstatus "$review_device" -b
prune_recordings() {
  python3 - "$1" <<'PY'
import pathlib,sys
for p in pathlib.Path(sys.argv[1]).rglob('*'):
    if p.is_file() and p.suffix.lower() in ('.mp4','.mov'):
        p.unlink()
PY
}
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
xcrun simctl bootstatus "$review_device" -b
xcrun simctl ui "$review_device" content_size accessibility-extra-extra-extra-large
large_text_status=0
xcodebuild -project HeadLink.xcodeproj -scheme HeadLinkUIReview -destination "$test_destination" \
  -derivedDataPath build/UIReview -resultBundlePath build/ui-review/large-text.xcresult \
  -only-testing:HeadLinkUITests/HeadLinkUITests/testLandscapeControlsRemainReachable \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test-without-building | tee build/ui-review/large-text.log || large_text_status=$?
xcrun xcresulttool export attachments --path build/ui-review/large-text.xcresult --output-path build/ui-review/large-text-screenshots
prune_recordings build/ui-review/large-text-screenshots
exit "$large_text_status"
