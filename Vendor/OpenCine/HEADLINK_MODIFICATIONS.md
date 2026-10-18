HeadLink changes: subset Package.swift; expose nativeWrites read-only counter in DjiAppleDatalink; make interpolated OSLog values private in:

OpenCineDJIApple/DjiAppleDatalink.swift
OpenCineDJIApple/DjiAppleBluetoothLink.swift
No wire builders, identifiers, parser offsets or command semantics changed.

Fixed-body recovery patch: expose existing UDP-parsed newest pose and receipt/parse/Main delivery timing; preserve UDP receipt timestamp through Main callbacks. No wire builders, parser offsets, command units, or timeout thresholds changed. DEBUG-only parser-ingress fixture is excluded from Release.
