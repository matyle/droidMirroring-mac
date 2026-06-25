# Security Policy

## Supported versions

| Version | Status |
|---|---|
| `main` branch | actively supported |
| Tagged releases | latest two minor versions |
| Anything older | best-effort only |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security bugs.**

Email **matytan@outlook.com** with:

- A description of the issue
- Steps to reproduce (commands, device, environment)
- Affected version or commit hash
- Your assessment of impact

We aim to acknowledge within **1-2 business days** and to ship a fix or
mitigation within **14 days** for high-severity issues. Once a fix is
released we will credit you in the release notes unless you'd rather stay
anonymous.

## Scope

Surfaces we treat as security-relevant:

- **ADB wire protocol** — `Packages/ADBKit/Sources/ADBKit/ADBConnection.swift`
  and friends. Untrusted bytes from the local adb daemon or a paired device.
- **scrcpy server** — we bundle the upstream Apache-2.0
  `scrcpy-server.jar`; vulnerabilities in scrcpy itself should be reported
  to the upstream project at https://github.com/Genymobile/scrcpy/security.
- **Wireless ADB pairing** — `Packages/ADBKit/Sources/ADBKit/ADBWirelessClient.swift`.
  Pair codes are typed into our UI and forwarded to the bundled `adb pair`
  binary; we do not handle the SPAKE2 cryptography ourselves.
- **FileProvider extension** — `Extensions/FileProviderExt/`. Disabled in
  the open-source build by default; enabled in signed/notarized release
  builds. Treats path traversal and macOS-shell filename poisoning carefully.
- **Bundled `adb` binary** — Google platform-tools, Apache-2.0. We do not
  ship a modified version.

Surfaces explicitly **out of scope** for the bug-bounty intent:

- Issues that only reproduce on jailbroken / rooted devices.
- Self-XSS or attacks that require the user to manually type adversarial input.
- The "an attacker with physical access to the unlocked Mac" threat model.

## Disclosure timeline (default)

| Day | Action |
|---|---|
| 0 | You email us |
| 1-2 | We acknowledge |
| ≤ 14 | We ship a fix in a release |
| Fix + 7 | Public disclosure (you can name yourself, or stay anonymous) |
