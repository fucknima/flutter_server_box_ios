# Flutter to SwiftUI migration

The native target is a SwiftUI presentation migration. Flutter remains the
source of truth for routes and behavior while screens move behind a native UI
boundary. Existing behavior must be preserved before any old path is removed;
this is not a license to redesign or drop product features.

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
| Server list and status cards | `lib/view/page/server/tab` | Monitor HTTP and SSH status flows exist for the current base metrics |
| Server editor and deduplication | `lib/view/page/server/edit` | Native model and editor flow exist; advanced fields remain |
| Connection statistics | `lib/view/page/server/connection_stats.dart`, `lib/data/store/connection_stats.dart` | Native JSON history, summaries, cleanup, and SwiftUI screen exist |
| SSH authentication | `lib/core/utils/server.dart`, `ssh_auth.dart` | Citadel transport integrated for password and private-key flows |
| Jump hosts and proxy command | `lib/core/utils/jump_chain.dart`, `proxy_command_socket.dart` | Recursive ordered jump candidates are supported; proxy commands are explicitly rejected on iOS because arbitrary process execution is unavailable |
| Remote status script and parsers | `lib/data/model/app/scripts`, `server_status_update_req.dart` | Framed SSH status protocol ported for base metrics |
| SSH terminal and tmux | `lib/view/page/ssh`, `lib/data/ssh` | PTY terminal, initial commands, resize, control keys, lifecycle-safe sessions, and bounded command history exist; full xterm rendering, tmux/session management, and multi-tab restore remain |
| SFTP and local files | `lib/view/page/storage` | Browser, home/search/sort/path navigation, UTF-8 editing, upload/download progress/cancel, missions, chmod, recursive delete, basic remote file operations, local open/share, and local files exist; sudo fallback and binary-aware editor parity remain |
| Docker, process, systemd, PVE | `lib/view/page/container`, `process.dart`, `systemd.dart`, `pve.dart` | Process, systemd, Docker/Podman tools, and SSH-backed PVE resource listing/control exist; full container/image/PVE detail screens remain |
| iperf | `lib/view/page/iperf.dart` | Native form launches the same iperf command in the PTY |
| Port forwarding | `lib/view/page/port_forward.dart`, `lib/data/provider/port_forward_provider.dart` | Native persisted rules support local, remote, and SOCKS5 forwarding through Citadel/NIO |
| Snippets and agent | `lib/view/page/snippet`, `agent` | Persisted snippets, ordered auto-run, basic Agent chat/history, and Keychain API credentials exist; Agent tool execution and full conversation replay remain |
| Backup and settings | `lib/view/page/backup`, `setting` | Native appearance, home tabs, agent, reusable private-key Keychain CRUD, credential-free JSON export/import, and settings shell exist; cloud sync, encrypted backup password, and provider-specific sync remain |
| Widget | `ios/StatusWidget` | Existing Flutter extension retained until native data sharing is complete |
| Watch | `ios/WatchApp` | Explicitly out of scope; do not migrate |

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
