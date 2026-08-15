# Flutter to SwiftUI migration

The native target is a replacement implementation, not a visual wrapper
around Flutter. The Flutter target remains in the repository while each
feature is moved behind a native boundary and verified before the old path is
removed.

## Target architecture

```text
SwiftUI views
    -> feature view models (@MainActor)
        -> app services and repositories
            -> SSH/SFTP transport, Keychain, JSON storage, URLSession
```

The native layers are intentionally split as follows:

- `Models`: Codable value types with no UI or transport code.
- `Services`: SSH, SFTP, remote command scripts, Keychain, backup, and stores.
- `ViewModels`: lifecycle, cancellation, state transitions, and user-facing errors.
- `Views`: SwiftUI navigation and rendering only.

Passwords and private keys are never written to `UserDefaults` or the server
configuration JSON. They are stored in Keychain and referenced by server or
key identifiers.

## Feature parity matrix

| Flutter area | Main source | Native status |
| --- | --- | --- |
| Server list and status cards | `lib/view/page/server/tab` | Monitor HTTP flow exists; SSH flow in progress |
| Server editor and deduplication | `lib/view/page/server/edit` | Native model and editor migration in progress |
| SSH authentication | `lib/core/utils/server.dart`, `ssh_auth.dart` | Citadel transport being integrated |
| Jump hosts and proxy command | `lib/core/utils/jump_chain.dart`, `proxy_command_socket.dart` | Planned in SSH transport boundary |
| Remote status script and parsers | `lib/data/model/app/scripts`, `server_status_update_req.dart` | Protocol port in progress |
| SSH terminal and tmux | `lib/view/page/ssh`, `lib/data/ssh` | Planned after transport boundary |
| SFTP and local files | `lib/view/page/storage` | Planned after SFTP transport |
| Docker, process, systemd, PVE | `lib/view/page/container`, `process.dart`, `systemd.dart`, `pve.dart` | Planned feature modules |
| Snippets and agent | `lib/view/page/snippet`, `agent` | Planned feature modules |
| Backup and settings | `lib/view/page/backup`, `setting` | Planned native repositories and settings |
| Widget and Watch | `ios/StatusWidget`, `ios/WatchApp` | Existing Flutter extensions retained until native data sharing is complete |

## Native routes

The final SwiftUI navigation will cover the same user-facing destinations:

`Servers`, `Server detail`, `Server editor`, `Server discovery`, `Connection
stats`, `SSH sessions`, `Local files`, `SFTP`, `SFTP missions`, `Snippets`,
`Containers`, `Processes`, `Systemd`, `PVE`, `iperf`, `Port forwarding`,
`Private keys`, `Backup`, `Settings`, and the Agent workspace.

## Verification rule

A Flutter feature is not considered migrated when only its view exists. Each
module must have a working normal path, cancellation, error state, persistence
where applicable, and a regression test for its protocol or state transition.
