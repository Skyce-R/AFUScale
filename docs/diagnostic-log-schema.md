# Diagnostic log schema 1

UTF-8 newline-delimited JSON. Each complete event ends with LF. Do not edit raw captures. Exports are immutable snapshots and include the exact journal bytes plus a readable summary.

Each event has `schema`, `session`, `sequence` (starts at 1), `timestamp` (UTC ISO8601 with milliseconds), `uptime` (seconds, same boot), `kind`, and `fields` (string-to-string). Uptime is meaningful within a boot; session boundaries and UTC timestamp cover restarts. Sequences reflect this app's main-queue callback order; they are not BLE air-interface sequence numbers.

Event families:

- `session.start` / `session.stop`: app, OS, timezone, profile and capture boundaries.
- `profile.changed`, `app.lifecycle`, `user.marker`: experimental context.
- `bluetooth.*`, `scan.*`, `connection.*`, `advertisement`: discovery and lifecycle.
- `gatt.*.request`, `gatt.*.result`, `gatt.value.rx`, `gatt.descriptor.rx`: discovery, supported reads, notification subscription and all returned values. `hex` preserves byte order. `serviceIndex` and `characteristicIndex` disambiguate duplicate UUIDs within the discovered tree.
- `packet.unparsed`: preserves FFB2 packets rejected by the existing parser, pointing to `sourceSequence`.
- `measurement.final`: parser-derived weight and candidate A/B, exact `hex`, local profile snapshot, `sourceSequence` of raw RX, `scaleStoredProfile=unknown`.
- `annotation`: manual values with `measurementSequence` pointing to a final event **in the same session**. Latest annotation is the current revision; earlier annotations remain in the file.

Fields `scaleFatPercent`, `officialFatPercent` contain percentage values, e.g. `20.3`, not fractions. `officialWeightKg`, `officialProfile`, `scaleStoredProfile`, `participantCode`, `officialAppVersion`, `notes` are supplied by the user. Empty fields mean unavailable, not zero.

CoreBluetooth uses a single value callback for read results and notifications; `delivery` documents that limitation rather than guessing their origin. Subscription requests do not expose raw platform-generated CCCD write bytes. Descriptor values that are not byte arrays are recorded as their typed string description.

The journal is append-only and synchronizes each event. A failing write disables logging and surfaces an error. After interruption, complete lines can be read/exported; malformed or unterminated lines are reported, and annotation append is rejected rather than overwriting evidence. New captures use new files. No automatic data upload or hidden truncation is implemented.
