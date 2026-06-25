# Troubleshooting

Real issues hit during M2 / M3 development and how they were resolved. Add to
this file when you debug something non-obvious.

## NWBrowser returns zero Bonjour results

**Symptom:** `_adb-tls-connect._tcp` and `_adb-tls-pairing._tcp` browsers
report state `.ready` but `browseResultsChangedHandler` never fires, even
though `dns-sd -B _adb-tls-connect._tcp` from a terminal sees the device.

**Cause:** One of:
1. **Local Network permission** is denied for DroidMirroring. macOS prompts the first
   time `NWBrowser.start()` runs Bonjour; if the user dismissed it, the prompt
   never comes back. Reset via:
   ```sh
   tccutil reset SystemPolicyAllFiles com.droidmirroring.app.DroidMirroring
   tccutil reset SystemPolicyAllNetworkMonitor com.droidmirroring.app.DroidMirroring
   ```
2. **AP client isolation** on the Wi-Fi. Many guest / corporate APs block
   peer-to-peer mDNS. Move both Mac and phone onto a normal LAN.
3. Wrong service type strings. The three DroidMirroring browses are case-sensitive
   and must include the trailing `_tcp`. See
   `Packages/DeviceDiscovery/Sources/DeviceDiscovery/WirelessBrowser.swift`.

## scrcpy server reports `NumberFormatException for input string: ...`

**Symptom:** `scrcpy-smoke` (or the App) crashes the server immediately after
`app_process` spawn. Logcat shows:
```
Caused by: java.lang.NumberFormatException: For input string: "fa1c08d0"
    at java.lang.Integer.parseInt(...)
    at com.genymobile.scrcpy.Server.scid(...)
```

**Cause:** `scid` is parsed via Java `Integer.parseInt(s, 16)`. That parses a
**signed** 32-bit int — anything with the high bit set (≥ `0x80000000`) blows
up.

**Fix:** Generate scid as `UInt32.random(in: 0..<0x7FFF_FFFF)`. DroidMirroring does
this in `ScrcpyServerLauncher.init`. If you change it, keep the high bit clear.

## Video metadata header looks like garbage

**Symptom:** First 12 frames decode fine but the device name is "(\x00…",
or `width` / `height` are absurd values like `0x68323634` (== ASCII "h264").

**Cause:** scrcpy 3.x changed the metadata block. 2.x prefixed a one-byte
dummy field. 3.x removed it. If you ported code from 2.x docs or
`Read first 77 bytes` you are off by one.

**Fix:** Read exactly **76 bytes**: 64 (name) + 4 (codec FourCC) + 4 (width)
+ 4 (height). See `readVideoMetadata` in `ScrcpyServerLauncher.swift`.

## `SocketAcceptor` fails with `EINVAL`

**Symptom:** `NWListener.start()` immediately transitions to `.failed(POSIXErrorCode: EINVAL)`.

**Cause:** Setting `params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: …)`
along with `requiredInterfaceType = .loopback`. Network.framework treats the
combination as over-constrained.

**Fix:** Set only `requiredInterfaceType = .loopback` and pass the port via
`NWListener(using:, on:)`. That's how the current code does it.

## FileProvider domain registration fails with -2001 / -2014

**Symptom:** `NSFileProviderManager.add(domain)` throws
`NSFileProviderErrorDomain Code=-2001` (or -2014) at runtime, even with the
extension correctly bundled in `PlugIns/`.

**Cause:** Ad-hoc / Personal-Team signing. macOS refuses to register
`fileprovider-nonui` extensions that aren't signed by a paid Apple Developer
account.

**Fix:** Configure `DEVELOPMENT_TEAM` in `project.yml`, regenerate, rebuild.
Until then, leave the call to `FinderDomainCoordinator.start(monitor:)`
commented out in `App/droidMirroringApp.swift` (as it is by default).

## Mirror window doesn't change shape on fold/unfold

**Symptom:** On a Samsung Z Fold / Pixel Fold, scrcpy keeps mirroring the
outer cover panel even after the device is unfolded.

**Cause:** scrcpy mirrors a fixed `display_id` for the lifetime of the
session, and the outer panel keeps `display_id=0` whether folded or not. The
inner panel gets a different logical id (often `2` on Samsung, `1` or higher
on Pixel) and a fresh `DisplayDeviceInfo` block.

**Fix:** `SessionCoordinator` polls `dumpsys display` every 1.5s, ranks
displays by `(state, area)`, and relaunches the session on the new id when it
changes. The mirror NSWindow stays open; `MetalFrameRenderer.onDimensionsChanged`
fires to resize it. See `App/ViewModels/SessionCoordinator.swift`
`checkActiveDisplay` and `Packages/ADBKit/Sources/ADBKit/DisplayInfo.swift`.

The known parked work here: there's a brief black frame on relaunch because
the scrcpy server is fully torn down. A polish pass could cross-fade by
keeping the old `CAMetalLayer` content visible until the first new keyframe
lands.

## App is completely silent under `nohup` / log file redirect

**Symptom:** Running `nohup ./DroidMirroring.app/Contents/MacOS/DroidMirroring > /tmp/log 2>&1 &`
produces an empty log even though the App is clearly running.

**Cause:** stdio is line-buffered (or fully buffered) by default; under a
pipe instead of a TTY, nothing flushes until the App exits cleanly. If it
crashes the buffer is lost.

**Fix:** Disable buffering at startup:
```swift
setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)
```
Done in `App/droidMirroringApp.swift` `init`, and in both smoke executables'
`main`. Without it, `print(…)` calls don't appear in `/tmp/droidmirroring.log` until
the process dies.

## adb server not running

**Symptom:** Every `ADBClient` call throws `connection cancelled before ready`
or "cannot connect to daemon".

**Cause:** No `adb` server on `127.0.0.1:5037`. DroidMirroring expects the bundled
`adb` to have run `start-server` at least once per boot.

**Fix:** `DeviceMonitor.bootstrapServer()` runs `adb start-server` as soon as
the App launches. If your build skipped bundling adb (the post-build script
warns: `App/Resources/adb missing — run scripts/fetch-adb.sh`), fix by:
```sh
./scripts/fetch-adb.sh
xcodebuild ... # rebuild
```

## "no online device" from smoke tests

**Symptom:** `sync-smoke` or `scrcpy-smoke` exits with
`DroidMirroringError.deviceNotFound("no online device (have: [...])")`.

**Cause:** Device is `unauthorized` (you haven't tapped "Allow USB debugging"
on the phone), or `offline`.

**Fix:**
- USB: replug, accept the dialog, run `adb devices` until status is `device`.
- Wireless: re-pair, or `adb disconnect && adb connect <host>:<port>`.

## Tests pass locally but `swift test --package-path Packages/ScrcpyClient` hangs

**Symptom:** The test process never exits.

**Cause:** A leftover scrcpy-server process on the phone holding the
`localabstract:scrcpy_*` socket open, OR a leftover macOS-side listener that
caught an early SIGINT.

**Fix:** Kill stale shells: `adb shell pkill -f scrcpy.Server`. Also kill any
zombies on the Mac: `pkill -f scrcpy-smoke`.

## "ad-hoc signature verification failure" on first launch

**Symptom:** Gatekeeper refuses to open a freshly-built Release.app.

**Cause:** App Sandbox + hardened runtime require notarization for distribution.
A Debug build will work locally; a Release build will not.

**Fix:** Either run via Xcode (which prevents Gatekeeper from intervening) or
notarize first:
```sh
xcrun notarytool submit DroidMirroring.app.zip --apple-id … --team-id … --wait
xcrun stapler staple DroidMirroring.app
```
M5 will automate this in `scripts/build-dmg.sh`.

## Phone keyboard won't appear after closing Mirror

**Symptom:** Mirror window closed cleanly, but tapping any text field on the
device does nothing — the IME doesn't slide up.

**Cause:** scrcpy 3.x leaves IME focus pinned to its (now-dead) mirror
surface after the control socket closes. Samsung One UI on Android 16 is
particularly prone to this. The selected input method also occasionally
flips to a scrcpy-internal stub that doesn't render UI.

**Fix:** `ScrcpyServerLauncher.stop()` now runs `adb shell ime reset` to
restore the system default input method. If you hit a phone in this state
that pre-dates the fix, manually clear:
```sh
adb shell ime reset
```

## Mirror crashes with `CrashIfClientProvidedBogusAudioBufferList`

**Symptom:** Mirror window opens, video shows for a moment, then the App
dies with this stack frame from CoreAudio.

**Cause:** A stack-allocated `AudioBufferList` declared as `(mNumberBuffers: 2,
mBuffers: ...)` is sized for ONE buffer in Swift; writing buffer[1] via
pointer arithmetic overruns the local frame on ARM64 (8-byte alignment
between `mNumberBuffers` and the buffer array).

**Fix:** `AudioBufferList.allocate(maximumBuffers: 2)` on the heap, plus
the Apple-blessed `UnsafeMutableAudioBufferListPointer` wrapper for the
input callback. See the patch in `Packages/MirrorEngine/Sources/MirrorEngine/AudioRenderer.swift`.

## `physicalDisplays` returns empty, log shows POSIX 96 (ENOMSG)

**Symptom:** Foldable / rotation never auto-adapts; coordinator log shows
`physicalDisplays error: POSIXErrorCode(rawValue: 96): No message available
on STREAM`.

**Cause:** `dumpsys display` is ~400 KB on Z Fold + Android 16; the adb
shell stream sometimes returns a short read with `ENOMSG` before we've
consumed the full body. Parsing then sees empty input.

**Fix:** Switched to `dumpsys window` (~5 KB) which emits atomic per-display
lines like `Display{#0 state=ON size=2520x1080 ROTATION_90}`. See
`Packages/ADBKit/Sources/ADBKit/DisplayInfo.swift::parseWindowDump`.

## Fusion picker hangs on "Listing apps…"

**Symptom:** Click *Desktop* (or future *Fusion*), pick-an-app sheet appears
with a spinner that never finishes.

**Cause:** The first cut of `AppCatalog` ran `dumpsys package <pkg>` for
every third-party package to fetch its human label. On a real Z Fold 7
with ~340 user-installed apps, that's 100+ seconds of serialized shell
calls.

**Fix:** `AppCatalog.listInstalled` now returns immediately after the single
`pm list packages -3` call, prettifying the last component of the package
name as a label (e.g. `com.tencent.mm` → `Mm`). True label resolution is
deferred until we add a background icon/label enricher.

## Virtual displays accumulate across runs

**Symptom:** `adb shell dumpsys window` shows multiple `Display{#20, #21,
#22 ...}` after several Desktop sessions; new sessions get new ids instead
of recycling.

**Cause:** scrcpy-server creates its virtual display on launch and relies
on the JVM exit hook to release it. If the App is killed (crash, `kill -9`,
power loss), the hook never fires.

**Fix:** Two-layer cleanup —

- **Boot sweep:** `DeviceMonitor.sweepStaleScrcpyServers` runs
  `pkill -f scrcpy.Server` on every online device 1.5 s after the App
  launches.
- **Graceful quit:** `AppDelegate.applicationShouldTerminate` calls
  `SessionCoordinator.shutdownEverything()` which stops every live mirror
  / desktop session in parallel before replying `true` to Cocoa.

Existing leaked displays clear themselves after Android's binder
linkToDeath GC (a few minutes) or a device reboot.
