# Offline moving-body math prototype — NOT an App feature

This package cannot send camera commands and is not imported by HeadLink. It checks rotation algebra given qualified measurements; it does not manufacture missing body attitude, capture timestamps or Pocket actuator kinematics.

Canonical right-handed axes: +X right, +Y optical forward, +Z up. `q_AB` maps B into A, composed right-to-left. Body compensation is `q_BL_target = inverse(q_WB) * q_WL_target`. The optical ray is preserved while target roll is leveled against world gravity. Full measured lens and joint rotations can recover body rotation as `q_WB = q_WL * inverse(q_BL)` only when both are independently known, contemporaneous and in qualified frames.

The timeline rejects receipt-time-only observations, clock/reference changes, stale inputs and extrapolation; interpolation uses quaternion SLERP at one common capture time. Ideal two-axis projection tests limit continuity but **is not a qualified Pocket mechanical model**. The caller must obtain and qualify body/lens measurements before a real native adapter can be implemented.

15 local math tests pass; fixed App tests (55) and capture parser tests (12) are separate. These do not constitute a mobile hardware test or an integrated control build. See ../../docs/MOVING_BODY_FEASIBILITY.md for exact missing data and next steps.

Run with a normal full Swift toolchain:

```sh
swift test --package-path research/moving-body-prototype --disable-xctest
```

Local CLT-only builds use the same framework and cross-import-overlay flags as `scripts/test-core.sh`, with a separate scratch directory. No complete Xcode installation is required for these local math tests.
