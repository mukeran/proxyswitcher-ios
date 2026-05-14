# ProxySwitcher Implementation Guidelines

## Goals

- Keep App, Control Center, and helper behavior consistent.
- Minimize regressions across rootful/rootless/roothide.
- Preserve responsiveness during proxy/Wi-Fi operations.

## IPC Contract

- IPC transport: Unix domain socket at `PSProxyHelperSocketPath`.
- Request format (JSON, one line):
  - `version` string, currently `"1"`
  - `command` string: `direct`, `apply`, `wifi`, `sync`, `listwifi`
  - `argument` string (optional by command)
- Response format (JSON, one line):
  - `version` string
  - `ok` bool
  - `code` integer
  - `reason` string
  - `message` string
- Protocol version mismatch must return an explicit error.

## Storage and Path Rules

- Profile store path: `/private/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.plist`.
- Always support candidate lookup for roothide mapping:
  - `/rootfs` + canonical path
  - canonical path
- Read operations should accept the first valid candidate.
- Write operations should update all writable candidates.

## UI and UX Rules

- Long-running actions must run off the main thread.
- App and Control Center must show operation-in-progress state and block duplicate taps.
- Wi-Fi candidate selection must use a dedicated list view, not an action sheet.
- Diagnostics should be user-accessible from App UI via a lightweight read-only view.

## Notification and Reload Rules

- Avoid write-notify loops:
  - Do not write store values if no effective change.
- App reload should be coalesced (short debounce) to avoid notification storms.

## Error Handling Rules

- Return structured helper errors (`code`, `reason`, `message`).
- Map transport failures separately from operation failures.
- Keep user-facing text concise; keep detailed reasons in structured fields.

## Release Checklist

1. Build with `THEOS_PACKAGE_SCHEME=roothide`.
2. Install package and restart helper.
3. Respring (`sbreload`).
4. Verify helper status, socket, and package version on-device with your standard SSH commands.
5. Validate:
   - App shows profiles and quick Wi-Fi entries.
   - Add/edit/delete profile works.
   - Add Wi-Fi list page loads and selection persists.
   - Control Center switching works.
