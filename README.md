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

## Usage

Open ProxySwitcher, add one or more proxy profiles, then tap Direct or a profile to apply it to the current Wi-Fi. Add the ProxySwitcher module in Settings > Control Center. Tapping the module cycles through Direct and the saved profiles; turning it off applies Direct.

The shared profile store is `/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.plist`, which avoids hard-coded jailbreak prefixes and works across rootful, rootless, and roothide packaging.
