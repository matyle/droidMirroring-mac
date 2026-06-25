# Wire protocols

Every byte on the wire between DroidMirroring, the adb server, and the Android device
is documented below. Anything not here is either standard TCP or
implementation-detail Swift.

The two big "gotchas" up front:

1. **adb host service and adb sync use different framings.** Host service is
   4 ASCII hex digits + payload; sync is 4 ASCII id + 4-byte little-endian u32
   length + payload. Easy to confuse if you only know one.
2. **scrcpy 3.x removed the leading dummy byte from the video metadata header.**
   The header is now 76 bytes (64 + 4 + 4 + 4), not 77. See M2 troubleshooting.

References for the originals:
- adb: <https://android.googlesource.com/platform/system/core/+/master/adb/protocol.txt>
- sync: <https://android.googlesource.com/platform/system/core/+/master/adb/SYNC.TXT>
- scrcpy: <https://github.com/Genymobile/scrcpy/blob/master/app/src/server.c>

---

## 1. adb host service

The macOS app speaks this protocol over loopback TCP to the adb server, by
default at `127.0.0.1:5037`.

### Command framing

Each request is sent as one length-prefixed frame:

```
+----------------------------+------------------------+
| 4 ASCII hex digits (len)   |  ASCII command payload |
+----------------------------+------------------------+
```

`len` is the hex-encoded byte length of the payload. Example:
`host:version` → `"000c" "host:version"`.

The server replies with a 4-byte status:

```
+--------+
| "OKAY" |       (success, may be followed by payload)
+--------+

+--------+----------------------------+----------------+
| "FAIL" |   4 ASCII hex digits (len) |  UTF-8 reason  |
+--------+----------------------------+----------------+
```

### Common host commands

| Command | Reply payload (length-prefixed) |
|---|---|
| `host:version` | 4-hex protocol version |
| `host:devices-l` | one device per line: `<serial> <state> [usb:…] [product:…] [model:…] …` |
| `host:track-devices-l` | as above, but the connection stays open and emits a new frame on every state change |
| `host:transport:<serial>` | empty — connection is now bound to the device |
| `host-serial:<serial>:forward:tcp:<port>;localabstract:<name>` | empty (followed by a 2nd `OKAY`) |

### Per-device commands

After `host:transport:<serial>` returns OKAY, the same connection can issue
exactly one device-scoped service. The connection cannot be reused after that
service finishes.

| Service | Used by |
|---|---|
| `shell:<cmd>` | `ADBClient.shell` — exit on EOF, output is stdout/stderr concatenated |
| `sync:` | Switches the rest of the connection to the **sync sub-protocol** |
| `reverse:forward:localabstract:<name>;tcp:<port>` | scrcpy port plumbing |
| `reverse:killforward:localabstract:<name>` | tear-down |

Implementation: `Packages/ADBKit/Sources/ADBKit/ADBConnection.swift` and
`ADBClient.swift`.

---

## 2. adb sync sub-protocol

After `sync:`+OKAY the framing changes to:

```
+-------------------+-------------------------+----------------+
| 4 ASCII id        |  4-byte LE u32 length   |  length bytes  |
+-------------------+-------------------------+----------------+
```

**Endianness:** little-endian, not the host service's ASCII hex. Confusing
this single byte order will eat half an afternoon — and has.

### Command set

| ID | Direction | Payload meaning |
|---|---|---|
| `STAT` | C→S | path |
| `STAT` | S→C | mode (LE u32) + size (LE u32) + mtime (LE u32) — **no length field** |
| `LIST` | C→S | path |
| `DENT` | S→C | mode + size + mtime + nameLen + name (repeated) |
| `DONE` | S→C | terminates LIST; followed by 16 zero bytes |
| `RECV` | C→S | path |
| `DATA` | S→C | one chunk of file bytes (len in header) |
| `DONE` | S→C | terminates RECV; followed by 4 zero bytes |
| `SEND` | C→S | header payload `<path>,<mode-as-decimal>` |
| `DATA` | C→S | one chunk of file bytes (≤ 64 KiB) |
| `DONE` | C→S | finishes SEND; **length field is reused as mtime (epoch seconds)** |
| `OKAY` | S→C | SEND succeeded (followed by 4 zero bytes) |
| `FAIL` | either | length + UTF-8 reason |
| `QUIT` | C→S | tear down the sync session |

Mode bits follow POSIX:
- `0o040000` directory
- `0o100000` regular file
- `0o120000` symlink

Max chunk size: 64 KiB on the wire. Modern adb supports 1 MiB but 64 KiB is
the safe lowest common denominator and is what we ship.

Implementation: `Packages/ADBKit/Sources/ADBKit/SyncProtocol.swift`.

---

## 3. scrcpy-server launch sequence

We embed `scrcpy-server.jar` from upstream (Apache-2.0) and drive it ourselves.
Sequence implemented in `Packages/ScrcpyClient/Sources/ScrcpyClient/ScrcpyServerLauncher.swift`.

```
1. adb push  Resources/scrcpy-server.jar  →  /data/local/tmp/scrcpy-server-<scid>.jar
2. macOS:    listen on 127.0.0.1:<localPort>  (NWListener, loopback only)
3. adb reverse  localabstract:scrcpy_<scid>  tcp:<localPort>
4. adb shell  CLASSPATH=/data/local/tmp/scrcpy-server-<scid>.jar \
              app_process / com.genymobile.scrcpy.Server <version> \
              scid=<scid> log_level=info \
              video_codec=h265 video_bit_rate=8000000 max_fps=60 \
              audio=true audio_codec=opus control=true \
              display_id=0 tunnel_forward=false cleanup=true raw_stream=false
5. accept N sockets on the listener, in order:
     [0] video  (always)
     [1] audio  (iff audio=true)
     [2] control (iff control=true)
6. read video metadata header off socket [0]
```

### scid (session id)

scid is the unique identifier scrcpy uses for its `localabstract:scrcpy_<scid>`
socket and its internal logs. **It must fit in a Java signed `Integer`** —
scrcpy-server parses it with `Integer.parseInt(s, 16)`, so the high bit must
stay clear. DroidMirroring uses `UInt32.random(in: 0..<0x7FFF_FFFF)`. Setting the high
bit yields a `NumberFormatException` on the device and the session never
starts.

---

## 4. scrcpy video framing

### Initial metadata (one-shot, sent before any frame)

```
+--------------------------------------------+
| 64 bytes : device name (UTF-8, null-padded)|
+--------------------------------------------+
|  4 bytes : codec FourCC (big-endian u32)   |   "h264" / "hevc" / " av1"
+--------------------------------------------+
|  4 bytes : width  (big-endian u32)         |
+--------------------------------------------+
|  4 bytes : height (big-endian u32)         |
+--------------------------------------------+
                  total = 76 bytes
```

There is **no leading dummy byte** in scrcpy 3.x. (scrcpy 2.x prefixed a
one-byte field that 3.x removed. If your header is 77 bytes you have an off-by-
one and the device name will look like garbage.)

### Per-frame header (12 bytes, big-endian)

```
+-------------------------------------------------------------------+
| 8 bytes : PTS u64                                                 |
|   bit 63   : CONFIG flag       (parameter sets, no picture)       |
|   bit 62   : KEY_FRAME flag                                       |
|   bits 0-61: PTS in microseconds                                  |
+-------------------------------------------------------------------+
| 4 bytes : payload size u32                                        |
+-------------------------------------------------------------------+
| <size> bytes : Annex-B NAL units                                  |
+-------------------------------------------------------------------+
```

`payload` is Annex-B (start codes `00 00 00 01` between NAL units). The
`VTDecoder` rewrites those to AVCC (4-byte big-endian length prefixes) before
handing the buffer to VideoToolbox.

Implementation: `Packages/ScrcpyClient/Sources/ScrcpyClient/VideoStream.swift`.

---

## 5. scrcpy audio framing

Audio uses the same 12-byte per-packet header as video. The audio socket also
starts with a 4-byte codec FourCC, distinct from the 64-byte video name.

Recognised FourCCs (ASCII, padded with space):

| FourCC | Codec |
|---|---|
| `opus` | Opus (default) |
| ` aac` | AAC |
| `flac` | FLAC |
| `raw ` | raw PCM |

Implementation: `Packages/ScrcpyClient/Sources/ScrcpyClient/AudioStream.swift`.

---

## 6. scrcpy control messages

Direction: client → server.

```
+-----------+--------------------+
| 1 byte    |  variable payload  |
| msg type  |                    |
+-----------+--------------------+
```

Message types (see `Packages/ScrcpyClient/Sources/ScrcpyClient/ControlMessage.swift`):

| Type | Code | Payload |
|---|---|---|
| `injectKeycode` | 0 | action(u8) + keycode(BE u32) + repeat(BE u32) + meta(BE u32) |
| `injectText` | 1 | textLen(BE u32) + UTF-8 bytes |
| `injectTouchEvent` | 2 | action(u8) + pointerId(BE u64) + x(BE i32) + y(BE i32) + screenW(BE u16) + screenH(BE u16) + pressure(BE u16 fixed-point) + actionButton(BE u32) + buttons(BE u32) |
| `injectScrollEvent` | 3 | x(BE i32) + y(BE i32) + screenW(BE u16) + screenH(BE u16) + hscroll(BE i16) + vscroll(BE i16) + buttons(BE u32) |
| `backOrScreenOn` | 4 | action(u8) |
| `expandNotificationPanel` | 5 | — |
| `expandSettingsPanel` | 6 | — |
| `collapsePanels` | 7 | — |
| `getClipboard` | 8 | copyKey(u8) |
| `setClipboard` | 9 | sequence(BE u64) + paste(u8) + textLen(BE u32) + UTF-8 |
| `setScreenPowerMode` | 10 | mode(u8) |
| `rotateDevice` | 11 | — |
| `uhidCreate` | 12 | uhid create blob |
| `uhidInput` | 13 | uhid input blob |
| `openHardKeyboardSettings` | 14 | — |
| `startApp` | 15 | nameLen(u8) + UTF-8 package |
| `resetVideo` | 16 | — |

Touch coordinates are in **device pixels**, not view pixels. DroidMirroring scales
NSEvent positions by the current video dimensions before sending. The
`screenWidth/screenHeight` fields are how the server normalizes if your
coordinate system disagrees with its current orientation.

Pressure is a Q0.16 fixed-point value: encode `pressure * 65535`.

Scroll hscroll/vscroll are Q1.15 signed: encode `clamp(-1, 1) * 32767`.

---

## 6b. scrcpy device messages

Direction: server → client. Read on the *same* control socket that we write
ControlMessages to — `NWConnection` is full-duplex so a `ControlSocketWriter`
and a `DeviceMessageReader` share the connection (see
`Packages/ScrcpyClient/Sources/ScrcpyClient/DeviceMessage.swift`).

```
+-----------+----------------------+
| 1 byte    |  variable payload    |
| msg type  |                      |
+-----------+----------------------+
```

| Type | Code | Payload |
|---|---|---|
| `clipboard` | 0 | textLen(BE u32) + UTF-8 bytes |
| `ackClipboard` | 1 | sequence(BE u64) — echoes the seq we sent in SET_CLIPBOARD |
| `uhidOutput` | 2 | uhidId(BE u16) + dataLen(BE u16) + bytes |

`ClipboardBridge` consumes the `clipboard` stream, writes to `NSPasteboard`,
and skips writes that match the hash it last *sent* to avoid a ping-pong
loop with the macOS pasteboard poller (`App/ViewModels/ClipboardBridge.swift`).

---

## 7. Wireless ADB (Android 11+)

Bonjour service types we browse (see
`Packages/DeviceDiscovery/Sources/DeviceDiscovery/WirelessBrowser.swift`):

| Service | Meaning |
|---|---|
| `_adb._tcp` | Legacy `adb tcpip` (Android 9/10) — already trusted |
| `_adb-tls-connect._tcp` | Modern wireless ADB, already paired — ready to `adb connect <host>:<port>` |
| `_adb-tls-pairing._tcp` | Transient — published only while the Android "Pair with code" screen is open |

### Pair → connect flow

```
1. user opens Wireless Debugging on the phone, taps "Pair device with pairing code"
2. DroidMirroring sees a new _adb-tls-pairing endpoint via NWBrowser
3. user types the 6-digit code into PairingSheet
4. DroidMirroring: adb pair <host>:<port> <code>            (TLS + SPAKE2)
5. phone now advertises _adb-tls-connect endpoint
6. DroidMirroring: adb connect <host>:<port>                (TLS + cached key)
7. device appears in host:track-devices-l as wifi
```

Pair + connect are the only things we shell out to the bundled `adb` for —
the TLS / SPAKE2 stack is impractical to reimplement. See
`ADBWirelessClient.swift`.

### QR-code payload

Android's QR pairing payload is a single line of plain ASCII:

```
WIFI:T:ADB;S:<service-name>;P:<password>;;
```

- `T:ADB` is the literal tag.
- `S:` is the Bonjour service name the phone will advertise on
  `_adb-tls-pairing._tcp` once the QR is scanned.
- `P:` is the pairing code (random 6 alphanumeric chars on phone-generated QRs).

DroidMirroring does not yet generate QR codes — pairing-code entry only — but the
parser is straightforward enough to add when needed.

---

## 8. Display selection (foldables)

scrcpy mirrors a single `display_id`, but foldables expose multiple logical
displays whose states change during fold/unfold animations. DroidMirroring calls
`adb shell dumpsys display` and parses `LogicalDisplay` blocks for size + state:

```
ON  >  ON_SUSPEND  >  DOZE  >  DOZE_SUSPEND  >  OFF/UNKNOWN
```

Tie-break by area (descending). See
`Packages/ADBKit/Sources/ADBKit/DisplayInfo.swift` and the polling loop in
`App/ViewModels/SessionCoordinator.swift`. When the picked id changes, the
session is torn down and relaunched on the new id; the mirror NSWindow stays
open and re-fits via `MetalFrameRenderer.onDimensionsChanged`.
