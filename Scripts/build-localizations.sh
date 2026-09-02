#!/bin/bash
#
# Compiles the string catalog into the .lproj tables the package ships.
#
# `swift build` copies resources verbatim: it does not compile .xcstrings the
# way Xcode does. Shipping the catalog alone would mean every lookup outside
# Xcode silently returned its key, so the compiled output is generated here and
# committed. `Localizations/Localizable.xcstrings` stays the file people edit.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
catalog="$root/Localizations/Localizable.xcstrings"
resources="$root/Sources/AgentKit/Resources"

rm -rf "$resources"
mkdir -p "$resources"
xcrun xcstringstool compile "$catalog" --output-directory "$resources"
echo "Compiled $(basename "$catalog") into $(cd "$resources" && ls -d *.lproj | tr '\n' ' ')"
