HeadLink changes: subset Package.swift; expose nativeWrites read-only counter in DjiAppleDatalink; make interpolated OSLog values private in:

OpenCineDJIApple/DjiAppleDatalink.swift
OpenCineDJIApple/DjiAppleBluetoothLink.swift
No wire builders, identifiers, parser offsets or command semantics changed.

Fixed-body recovery patch: expose existing UDP-parsed newest pose and receipt/parse/Main delivery timing; preserve UDP receipt timestamp through Main callbacks. No wire builders, parser offsets, command units, or timeout thresholds changed. DEBUG-only parser-ingress fixture is excluded from Release.

Foreground repair follow-up: expose `refreshStatusSubscriptions()` to resend the original read-only subscription set with the same IDs. The App bounds retries to three per connection/foreground epoch, never substitutes stale samples, never reinitializes gimbal mode in this operation, and retains all wire builders unchanged. Foreground recovery uses the existing identity-only open, SSID query and verified registration path. No background entitlement is added.

Mobile-relative follow: optional absolute head-sample expiry on the existing tokenized one-slot target stream; fresh inbound control inhibits heartbeat path-loss retirement independently of video. No packet opcode, mechanical bound, stop packet or cadence changes.
