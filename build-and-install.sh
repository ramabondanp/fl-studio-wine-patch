#!/usr/bin/env bash
#
# Build and install a patched Wine crypt32.dll that fixes Authenticode
# verification of signatures that use noncanonical DER SET OF attribute
# ordering (for example FL Studio 2026).
#
# Symptom it fixes:
#   WinVerifyTrust fails with 0x80096004 (TRUST_E_CERT_SIGNATURE) even though
#   the signature, file digest, and certificate chain are all valid.
#
# Cause:
#   Wine re-encodes (sorts) the authenticated attributes before hashing them
#   during verification. Signatures made over the original ordering then fail.
#
# Only /usr/lib/wine/x86_64-windows/crypt32.dll is replaced. The original is
# backed up next to it as crypt32.dll.dist-backup.
#
# Requires (build dependencies): clang, lld, llvm (llvm-dlltool), flex, bison,
# make, python3, curl, plus your distro's Wine build dependencies.
# Memory/CPU: builds a single module. Use JOBS=1 on low-power machines.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/wine-crypt32-signed-attrs.patch"

REF=""
LIBDIR="/usr/lib/wine"
RESTORE=0
JOBS="${JOBS:-1}"

usage() {
    cat <<'EOF'
Usage: build-and-install.sh [--ref REF] [--libdir DIR] [--restore] [--help]

  --ref REF      Wine source ref to build (tag or commit).
                 Default: auto-detected from `wine --version`.
  --libdir DIR   Root of the Wine libraries (default: /usr/lib/wine).
  --restore      Restore the original crypt32.dll from its backup and exit.
  --help         Show this help.

Environment:
  JOBS           Parallel make jobs (default: 1)

After a Wine upgrade, re-run this script to rebuild against the new version.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)     REF="$2"; shift 2 ;;
        --libdir)  LIBDIR="$2"; shift 2 ;;
        --restore) RESTORE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

TARGET_DLL="$LIBDIR/x86_64-windows/crypt32.dll"
BACKUP_DLL="$TARGET_DLL.dist-backup"

if [ "$RESTORE" = 1 ]; then
    if [ ! -f "$BACKUP_DLL" ]; then
        echo "No backup found at $BACKUP_DLL" >&2
        exit 1
    fi
    sudo cp -a "$BACKUP_DLL" "$TARGET_DLL"
    echo "Restored $TARGET_DLL from backup."
    exit 0
fi

for tool in git curl patch tar make sudo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

if [ ! -f "$PATCH_FILE" ]; then
    echo "Patch not found: $PATCH_FILE" >&2
    exit 1
fi

# Detect the Wine source ref if not supplied.
if [ -z "$REF" ]; then
    wine_version="$(wine --version 2>/dev/null || true)"
    # git builds report e.g. wine-11.18-167-g9d17984f27b
    REF="$(sed -n 's/.*-g\([0-9a-f]\{7,\}\).*/\1/p' <<<"$wine_version")"
    if [ -z "$REF" ]; then
        # release builds report e.g. wine-11.0
        REF="$(sed -n 's/^\(wine-[0-9][0-9.]*\).*/\1/p' <<<"$wine_version")"
    fi
fi

if [ -z "$REF" ]; then
    echo "Could not detect the Wine source ref. Pass --ref <tag-or-commit>." >&2
    exit 1
fi

echo "Wine source ref : $REF"
echo "Install target  : $TARGET_DLL"
echo "Build jobs      : $JOBS"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Fetching Wine source ($REF)"
curl -fL --retry 2 --max-time 600 \
    "https://codeload.github.com/wine-mirror/wine/tar.gz/$REF" \
    -o "$WORKDIR/wine.tar.gz"

mkdir -p "$WORKDIR/src"
tar -xzf "$WORKDIR/wine.tar.gz" -C "$WORKDIR/src" --strip-components=1

echo "==> Applying patch"
patch -p1 -d "$WORKDIR/src" < "$PATCH_FILE"

echo "==> Configuring"
mkdir -p "$WORKDIR/build"
(
    cd "$WORKDIR/build"
    "$WORKDIR/src/configure" --enable-win64 --disable-tests \
        CFLAGS="-O1 -g0" CROSSCFLAGS="-O1 -g0"
)

echo "==> Building crypt32.dll (this builds a few host tools first)"
(
    cd "$WORKDIR/build"
    nice -n 15 make -j"$JOBS" dlls/crypt32/x86_64-windows/crypt32.dll
)

BUILT_DLL="$WORKDIR/build/dlls/crypt32/x86_64-windows/crypt32.dll"
[ -f "$BUILT_DLL" ] || { echo "Build did not produce $BUILT_DLL" >&2; exit 1; }

if [ ! -f "$BACKUP_DLL" ]; then
    echo "==> Backing up original to $BACKUP_DLL"
    sudo cp -a "$TARGET_DLL" "$BACKUP_DLL"
else
    echo "==> Existing backup kept at $BACKUP_DLL"
fi

echo "==> Installing patched crypt32.dll"
sudo cp "$BUILT_DLL" "$TARGET_DLL"

echo
echo "Done. Verify with:"
echo "  wine <path-to-a-signed-exe-or-dll>   # FL Studio should now start"
echo
echo "To revert:  $0 --restore"
