#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
source_svg="$project_dir/App/AppIcon.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert is required (brew install librsvg)" >&2
    exit 1
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxyswitcher-appicon.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

render_icon() {
    size=$1
    destination=$2
    temporary="$tmp_dir/$(basename -- "$destination")"

    rsvg-convert \
        --format=png \
        --width="$size" \
        --height="$size" \
        --output="$temporary" \
        "$source_svg"
    install -m 0644 "$temporary" "$destination"
}

render_icon 120 "$project_dir/App/AppIcon60x60@2x.png"
render_icon 180 "$project_dir/App/AppIcon60x60@3x.png"

echo "Generated AppIcon60x60@2x.png and AppIcon60x60@3x.png from AppIcon.svg"
