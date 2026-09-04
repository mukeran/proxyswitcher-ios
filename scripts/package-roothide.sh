#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

if [ -z "${THEOS:-}" ]; then
    echo "error: THEOS is not set" >&2
    exit 1
fi

dm_pl="$THEOS/vendor/dm.pl/dm.pl"
if [ ! -f "$dm_pl" ]; then
    echo "error: Theos package builder not found: $dm_pl" >&2
    exit 1
fi

for command_name in make perl rsync mktemp ar xz tar lipo; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command not found: $command_name" >&2
        exit 1
    fi
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxyswitcher-roothide.XXXXXX")
cleanup() {
    case "$work_dir" in
        */proxyswitcher-roothide.*) /bin/rm -rf "$work_dir" ;;
    esac
}
trap cleanup EXIT HUP INT TERM

stage_dir="$work_dir/stage"
package_root="$work_dir/package"
mkdir -p "$stage_dir" "$package_root/DEBIAN"

make_roothide() {
    make -C "$project_dir" "$@" \
        THEOS_PACKAGE_SCHEME=roothide \
        PACKAGE_ARCH=iphoneos-arm64e \
        THEOS_PACKAGE_INSTALL_PREFIX= \
        THEOS_STAGING_DIR="$stage_dir"
}

echo "==> Building roothide iphoneos-arm64e"
make_roothide clean
make_roothide all stage
make_roothide before-package

for required_path in \
    "$stage_dir/DEBIAN/control" \
    "$stage_dir/DEBIAN/postinst" \
    "$stage_dir/Applications/ProxySwitcher.app/ProxySwitcher" \
    "$stage_dir/Applications/ProxySwitcher.app/AppIcon60x60@2x.png" \
    "$stage_dir/Applications/ProxySwitcher.app/AppIcon60x60@3x.png" \
    "$stage_dir/Applications/ProxySwitcher.app/PlugIns/ProxySwitcherTunnel.appex/ProxySwitcherTunnel" \
    "$stage_dir/Library/ControlCenter/Bundles/ProxySwitcherCC.bundle/ProxySwitcherCC" \
    "$stage_dir/Library/LaunchDaemons/codes.var.tweak.proxyswitcher.helper.plist" \
    "$stage_dir/usr/bin/proxyswitcherctl"; do
    if [ ! -e "$required_path" ]; then
        echo "error: staging file missing: $required_path" >&2
        exit 1
    fi
done

chmod 0755 "$stage_dir/DEBIAN/postinst"
chmod 4755 "$stage_dir/usr/bin/proxyswitcherctl"

control_value() {
    sed -n "s/^$1:[[:space:]]*//p" "$stage_dir/DEBIAN/control" | head -n 1
}

package_name=$(control_value Package)
package_version=$(control_value Version)
package_arch=$(control_value Architecture)

if [ -z "$package_name" ] || [ -z "$package_version" ]; then
    echo "error: package control is missing Package or Version" >&2
    exit 1
fi
if [ "$package_arch" != "iphoneos-arm64e" ]; then
    echo "error: package architecture is $package_arch, expected iphoneos-arm64e" >&2
    exit 1
fi

for executable in \
    "$stage_dir/Applications/ProxySwitcher.app/ProxySwitcher" \
    "$stage_dir/Applications/ProxySwitcher.app/PlugIns/ProxySwitcherTunnel.appex/ProxySwitcherTunnel" \
    "$stage_dir/Library/ControlCenter/Bundles/ProxySwitcherCC.bundle/ProxySwitcherCC" \
    "$stage_dir/usr/bin/proxyswitcherctl"; do
    executable_archs=$(lipo -archs "$executable")
    case " $executable_archs " in
        *" arm64e "*) ;;
        *) echo "error: $executable is missing arm64e (found: $executable_archs)" >&2; exit 1 ;;
    esac
done

if [ ! -u "$stage_dir/usr/bin/proxyswitcherctl" ] || [ ! -x "$stage_dir/usr/bin/proxyswitcherctl" ]; then
    echo "error: proxyswitcherctl must have mode 4755" >&2
    exit 1
fi

cmp "$project_dir/App/AppIcon60x60@2x.png" "$stage_dir/Applications/ProxySwitcher.app/AppIcon60x60@2x.png"
cmp "$project_dir/App/AppIcon60x60@3x.png" "$stage_dir/Applications/ProxySwitcher.app/AppIcon60x60@3x.png"

rsync -a "$stage_dir/DEBIAN/" "$package_root/DEBIAN/"
rsync -a --exclude DEBIAN "$stage_dir/" "$package_root/"

mkdir -p "$project_dir/packages"
output_file="$project_dir/packages/${package_name}_${package_version}_roothide_iphoneos-arm64e.deb"

echo "==> Packaging $output_file"
perl "$dm_pl" -Zlzma -z1 -b "$package_root" "$output_file"

package_listing="$work_dir/data.list"
ar -p "$output_file" data.tar.lzma | xz --format=lzma -dc | tar -tf - > "$package_listing"
for packaged_path in \
    Applications/ProxySwitcher.app/ProxySwitcher \
    Applications/ProxySwitcher.app/AppIcon60x60@2x.png \
    Applications/ProxySwitcher.app/AppIcon60x60@3x.png \
    Library/ControlCenter/Bundles/ProxySwitcherCC.bundle/ProxySwitcherCC \
    Library/LaunchDaemons/codes.var.tweak.proxyswitcher.helper.plist \
    usr/bin/proxyswitcherctl; do
    if ! grep -Fx "$packaged_path" "$package_listing" >/dev/null 2>&1; then
        echo "error: package is missing $packaged_path" >&2
        exit 1
    fi
done

mkdir -p "$project_dir/.theos"
printf '%s\n' "$output_file" > "$project_dir/.theos/last_package"
echo "==> Complete: $output_file"
