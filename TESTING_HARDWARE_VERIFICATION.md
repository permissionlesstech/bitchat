# Hardware verification runbook: private original image over BLE

Scope: this runbook is for manual BLE hardware verification. It does not claim the tests below have been run. Run each case at least 3 times before marking pass/fail because BLE airtime, OS scheduling, and relay timing vary substantially.

## Expected timing thresholds

For a 512 KiB image (`524288` bytes), the current private image path creates 9 Noise payload chunks: 8 full chunks of 60 KiB (`61440` bytes) plus 1 final 32 KiB chunk. BLE fragmentation uses a 469B fragment size and 25-30ms spacing per fragment train.

Approximate 1-hop calculation under `bleMaxConcurrentTransfers = 2` uses a parallel-wave model: each wave contains up to 2 active fragment trains, so wave duration is the longer train in that wave, not the sum of both trains.

- Full 60 KiB chunk: `ceil(61440 / 469) = 132` BLE fragments.
- Final 32 KiB chunk: `ceil(32768 / 469) = 70` BLE fragments.
- Two concurrent trains means 8 full chunks run as 4 parallel waves, then the final chunk runs as 1 wave.
- Theoretical lower-bound at 25ms spacing: `(4 * max(132, 132) + max(70)) * 25ms = (4 * 132 + 70) * 25ms = 14950ms`.
- Theoretical upper-bound at 30ms spacing: `(4 * max(132, 132) + max(70)) * 30ms = (4 * 132 + 70) * 30ms = 17940ms`.

Use `N = 25 seconds` for the 1-hop pass threshold. This is the ~15-18s theoretical scheduling window plus ~7-10s operational margin for GATT negotiation/ack behavior, Noise encryption work, CoreBluetooth scheduling, and radio variance on physical devices.

For >=2-hop relay, each fragment also pays one relay scheduling jitter. The `+8ms`/`+25ms` values below are code-backed constants: `TransportConfig.bleFragmentRelayMinDelayMs = 8` and `TransportConfig.bleFragmentRelayMaxDelayMs = 25` (`bitchat/Services/TransportConfig.swift:12-13`), applied by `RelayController` when choosing relay delay for fragment packets (`bitchat/Services/RelayController.swift:65`). The same parallel-wave model applies: each wave is bounded by the longer train in the wave, but each fragment in that train now includes local spacing plus relay jitter.

- Theoretical lower-bound: `(4 * max(132, 132) + max(70)) * (25ms + 8ms) = (4 * 132 + 70) * 33ms = 19734ms`.
- Theoretical upper-bound: `(4 * max(132, 132) + max(70)) * (30ms + 25ms) = (4 * 132 + 70) * 55ms = 32890ms`.

Use `M = 45 seconds` for the >=2-hop completion threshold. This is the ~20-33s theoretical relay scheduling window plus ~12s operational margin for relay contention, retransmission/backpressure effects, CoreBluetooth wake scheduling, and device placement variance. Use `60 seconds` as the explicit fail-with-log timeout threshold, giving another ~15s beyond `M` for a clear failure instead of an indefinite sending state.

## Case 1: 1-hop image near 512 KiB

Goal: verify that a private original image near the 512 KiB cap completes directly between two devices without byte changes.

Setup:

- Two physical iOS devices running a debug build from this branch.
- Devices A and B are in direct Bluetooth range.
- A and B have an established private chat.
- Prepare an image file as close as practical to `524288` bytes without exceeding it.
- Open Console.app or Xcode device logs for both devices.

Steps:

1. On device A, open private chat with B.
2. Start a timer.
3. Send the near-512 KiB image as a private image.
4. Stop the timer when B renders/receives the image.
5. In A logs, find the debug line:
   - `Private original image send bytes=<size> sha256=<hash>`
6. In B logs, find the debug line:
   - `Private original image received bytes=<size> sha256=<hash>`
7. Repeat at least 3 times.

Pass/fail from logs:

- Pass if B receives the image, sender and receiver `bytes` match, sender and receiver `sha256` match, completion time is <= 25 seconds, and neither app crashes nor UI hangs.
- Fail if hashes differ, sizes differ, B receives no image, completion exceeds 25 seconds in repeated runs, or either app crashes/hangs.

Measurements:

| Run | Image bytes | Sender SHA-256 | Receiver SHA-256 | Duration | Pass/fail | Notes |
|---|---:|---|---|---:|---|---|
| 1 |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |

## Case 2: >=2-hop relay

Goal: verify that a private original image transfer either completes through a relay or fails clearly without an indefinite sending state.

Setup:

- Three physical iOS devices running a debug build from this branch.
- Device A sends to device B through device C as relay.
- If possible, place A and B so they cannot maintain a direct BLE link, while A-C and C-B remain in range.
- Use the same near-512 KiB image as Case 1.
- Open logs for all three devices.

Steps:

1. Confirm A can see/reach B through the mesh with C present.
2. Start a timer.
3. On A, send the near-512 KiB image to B in private chat.
4. Stop the timer if B receives the image.
5. If the transfer does not complete, wait until 60 seconds and check whether the logs show a clear failure/timeout instead of silent indefinite sending.
6. Compare A sender SHA-256 and B receiver SHA-256 logs if the transfer completes.
7. Repeat at least 3 times.

Pass/fail from logs:

- Pass if the transfer completes within 45 seconds with matching `bytes` and `sha256`, or fails within 60 seconds with a clear log and no indefinite sending state.
- Fail if the app remains stuck in sending indefinitely, produces a corrupted image, logs mismatched hashes/sizes, or crashes/hangs.

Measurements:

| Run | Image bytes | Sender SHA-256 | Receiver SHA-256 | Duration/fail time | Result | Notes |
|---|---:|---|---|---:|---|---|
| 1 |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |

## Case 3: text while image is transferring

Goal: verify that text messages still get through while private image BLE fragment trains are active.

Setup:

- Use the same two-device 1-hop setup as Case 1.
- Before sending any image, measure text-only baseline latency between A and B in the same environment.
- Suggested baseline: send 5 short private text messages A->B and record median delivery latency.

Steps:

1. Record the text-only baseline median latency.
2. Start sending the near-512 KiB private image from A to B.
3. While the image is still transferring, send 1-3 short text messages from A to B.
4. Record each text message latency.
5. Compare image-transfer text latency against the baseline.
6. Repeat at least 3 times.

Pass/fail from logs:

- Pass if text messages still arrive and median latency while image transfer is active is <= 3x the text-only baseline median.
- Fail if text messages do not arrive, arrive only after the image transfer is completely done in repeated runs, or median latency is > 3x baseline.

Measurements:

| Run | Baseline median | Text latencies during image | Multiplier vs baseline | Image completed? | Pass/fail | Notes |
|---|---:|---|---:|---|---|---|
| 1 |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |

## Case 4: relay disappears mid-transfer

Goal: verify that losing the relay mid-transfer does not crash either endpoint, produce a corrupted image, or keep partial chunks forever.

Setup:

- Use the same three-device >=2-hop relay setup as Case 2.
- Use the same near-512 KiB private image.
- Open logs for all three devices.

Steps:

1. Start sending the private image from A to B through C.
2. After transfer begins but before completion, disable Bluetooth on C, close the app on C, or move C out of range.
3. Observe A and B for at least 60 seconds.
4. Confirm B does not save/render a corrupted partial image.
5. Check logs for clear failure/timeout behavior.
6. Repeat at least 3 times.

Pass/fail from logs:

- Pass if A and B do not crash, B does not create a corrupted image, and the transfer does not remain pending indefinitely after timeout.
- Fail if either endpoint crashes, B creates an invalid image, or sender/receiver remains stuck indefinitely with no clear log.

Measurements:

| Run | Relay action/time | Sender state after 60s | Receiver state after 60s | Corrupt image created? | Pass/fail | Notes |
|---|---|---|---|---|---|---|
| 1 |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |

## Optional Case 5: app backgrounded mid-transfer

Status: optional; not required for merge unless the reviewer wants explicit iOS background behavior coverage.

Code evidence before hardware testing:

- `Info.plist` declares `UIBackgroundModes` for `bluetooth-central` and `bluetooth-peripheral`.
- `AppRuntime.handleScenePhaseChange(.background)` does not call `meshService.stopServices()`; it marks app backgrounded, stops Tor/Nostr activity, ends geohash sampling, and leaves BLE service lifecycle intact.
- `BLEService.appDidEnterBackground()` restarts scanning in background mode, arms pending background connects, persists gossip state, and logs Bluetooth status.
- No explicit `beginBackgroundTask` wrapper exists around private image transfer, so actual transfer survival depends on CoreBluetooth background execution/wake behavior and must be verified on physical devices.

Goal: observe what happens if iOS backgrounds A or B mid-transfer.

Setup:

- Use Case 1 or Case 2 setup.
- Use debug build logs.

Steps:

1. Start a near-512 KiB private image transfer.
2. While the transfer is active, send the app on A or B to background.
3. Leave it backgrounded for 30-60 seconds, then return to foreground.
4. Check whether transfer completes, fails clearly, or stalls.
5. Repeat at least 3 times if this case is selected for review.

Measurements:

| Run | Device backgrounded | Background duration | Result | Logs observed | Notes |
|---|---|---:|---|---|---|
| 1 |  |  |  |  |  |
| 2 |  |  |  |  |  |
| 3 |  |  |  |  |  |
