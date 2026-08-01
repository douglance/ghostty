#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# xcodebuild -create-xcframework does not overwrite existing output.
rm -rf "${ROOT_DIR}/zig-out/lib/ghostty-vt.xcframework"

zig build \
    -Dtarget=aarch64-macos \
    -Demit-lib-vt=true \
    -Demit-xcframework=true \
    -Demit-docs=false \
    -Demit-webdata=false \
    -Dversion-string=1.3.0 \
    -Dlib-version-string=0.1.0 \
    -Doptimize=ReleaseFast \
    "$@"

# GhosttyKit and GhosttyVt are linked into one SwiftPM target. SwiftPM copies
# static-XCFramework headers into one flat product include directory, so two
# root module.modulemap files conflict. vmux compiles its narrow C bridge
# against vendored headers and uses this artifact for linking only.
VT_XCFRAMEWORK="${ROOT_DIR}/zig-out/lib/ghostty-vt.xcframework"
index=0
while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${index}" \
    "${VT_XCFRAMEWORK}/Info.plist" >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${index}:HeadersPath" \
        "${VT_XCFRAMEWORK}/Info.plist" >/dev/null 2>&1 || true
    index=$((index + 1))
done
find "${VT_XCFRAMEWORK}" -type d -name Headers -prune -exec rm -rf {} +

# The surface library and libghostty-vt share internal dependencies and global
# symbols. Namespace every symbol defined by the VT archive so both engines can
# be linked into vmux during the guarded migration. Undefined system imports
# are intentionally not rewritten.
LLVM_OBJCOPY="$(command -v llvm-objcopy || true)"
if [[ -z "${LLVM_OBJCOPY}" && -x /opt/homebrew/opt/llvm/bin/llvm-objcopy ]]; then
    LLVM_OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy
fi
if [[ -z "${LLVM_OBJCOPY}" ]]; then
    echo "llvm-objcopy is required to namespace libghostty-vt" >&2
    exit 1
fi

while IFS= read -r archive; do
    symbol_map="$(mktemp "${TMPDIR:-/tmp}/ghostty-vt-symbols.XXXXXX")"
    nm -gU "${archive}" \
        | awk 'NF >= 3 { original=$3; renamed=original; sub(/^_/, "", renamed); print original, "_vmuxvt_" renamed }' \
        | sort -u > "${symbol_map}"
    "${LLVM_OBJCOPY}" --redefine-syms="${symbol_map}" "${archive}"
    rm -f "${symbol_map}"
done < <(find "${VT_XCFRAMEWORK}" -type f -name '*.a' -print)
