# Native iOS SwiftUI port

This directory contains the first native iOS implementation of ServerBox. It
does not embed Flutter.

## Current scope

The native app implements the Monitor `/status` workflow:

- Add, edit, delete, and persist monitor endpoints.
- Fetch CPU, memory, disk, and network values with `URLSession`.
- Show loading, empty, success, offline, malformed-payload, and retry states.
- Refresh manually and while the app is active.
- Store endpoint configuration as Codable JSON in Application Support.

The endpoint format is the one used by ServerBoxMonitor:

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "name": "home",
    "cpu": "12.5%",
    "mem": "1.3g / 1.9g",
    "disk": "7.1g / 30.0g",
    "net": "712.3k / 1.2m"
  }
}
```

## Open in Xcode

Open `ServerBox.xcodeproj`. The project targets iOS 16 and supports iPhone and
iPad. If XcodeGen is available, `project.yml` describes the same project.

GitHub Actions runs the same test target on an iOS Simulator and uploads an
unsigned `iphoneos` App archive from the `Native iOS` workflow. An unsigned
archive is a build artifact only; it must be signed before installation on a
device.

This checkout is made on a Linux host, so Xcode compilation and simulator
testing must be run on macOS.

## Migration boundary

The original Flutter app has a much larger SSH feature set. SSH terminal,
SFTP, jump hosts, Docker, process management, and systemd are intentionally
not claimed as migrated here. They need native SSH transport, host-key
verification, Keychain-backed credentials, and feature-specific tests before
being added to the app.
