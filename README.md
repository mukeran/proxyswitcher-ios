# ProxySwitcher

ProxySwitcher is a Theos package for iOS 16 and newer. It includes:

- a small UIKit app for saving HTTP proxy profiles;
- a Control Center module for quickly switching the current Wi-Fi between Direct and saved proxy profiles;
- shared SystemConfiguration code that updates the active Wi-Fi service proxy settings.

## Build

Rootless is the default:

```sh
make package-rootless
```

Rootful:

```sh
make package-rootful
```

roothide:

```sh
make package-roothide
```

Install after building:

```sh
make install-roothide
```

## App-only mode (non-jailbreak)

Build only the app payload (no Control Center module, no helper):

```sh
make package-nonjailbreak
```

Output: `packages/ProxySwitcher_<version>_nonjailbreak.ipa`

This mode switches proxy via `NetworkExtension` VPN configuration in-app and does not modify per-Wi-Fi system proxy settings or switch Wi-Fi SSIDs.

## Compatibility mode in jailbreak build

In the regular jailbreak app build, you can toggle `Compatibility (VPN)` in-app:

- `OFF`: jailbreak system mode (helper + SystemConfiguration + Wi-Fi switch)
- `ON`: degraded non-jailbreak-like mode (VPN proxy, Wi-Fi switching disabled)

Implementation rules and engineering conventions:

- [Implementation Guidelines](docs/implementation-guidelines.md)

## Usage

Open ProxySwitcher, add one or more proxy profiles, then tap Direct or a profile to apply it to the current Wi-Fi. Add the ProxySwitcher module in Settings > Control Center. Tapping the module cycles through Direct and the saved profiles; turning it off applies Direct.

The shared profile store is `/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.plist`, which avoids hard-coded jailbreak prefixes and works across rootful, rootless, and roothide packaging.

## Public SDK control entry (non-jailbreak app)

The app supports URL actions that can be called from Shortcuts and then exposed in iOS Control Center as a Shortcut control:

- `proxyswitcher://direct`
- `proxyswitcher://toggle` (toggle between `Direct` and last active profile)
- `proxyswitcher://apply?id=<profile_identifier>`

This uses only public iOS APIs on the app side.
