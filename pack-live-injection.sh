#!/usr/bin/env bash
set -euo pipefail

# pack-live-injection — build a Ventoy LiveInjection archive that installs files
# into /usr/local/bin inside the live system (via sysroot/ prefix).
#
# Usage:
#   pack-live-injection script1.sh script2.py ...
#   pack-live-injection --out /path/to/live_injection.tar.gz script.sh
#   pack-live-injection --xz script.sh                    # outputs .tar.xz
#   pack-live-injection --dest /usr/local/bin a b c       # different target dir
#
# Notes:
# - Default dest inside live system: /usr/local/bin
# - Default archive: ./live_injection.tar.gz
# - Adds +x to scripts, checks for missing shebangs, strips CRLF if present.

out="pop-ubuntu.tar.gz"
dest="/usr/local/bin"
use_xz=false

die(){ echo "error: $*" >&2; exit 1; }

# Parse args
args=()
while (($#)); do
  case "$1" in
    --out) shift; out="${1:-}"; [[ -n "$out" ]] || die "--out needs a value";;
    --xz) use_xz=true;;
    --dest) shift; dest="${1:-}"; [[ "$dest" == /* ]] || die "--dest must be absolute (e.g. /usr/local/bin)";;
    -h|--help)
      sed -n '1,80p' "$0" | sed -n '1,/^$/p' ; exit 0;;
    --) shift; break;;
    -*)
      die "unknown option: $1";;
    *)
      args+=("$1");;
  esac
  shift || true
done
# Remaining positional args (if any)
if (($#)); then args+=("$@"); fi
((${#args[@]})) || die "no scripts provided"

# Build a staging dir with sysroot/ prefix
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/sysroot${dest}"

# Copy scripts in, normalize perms/line-endings, warn on missing shebangs
for src in "${args[@]}"; do
  [[ -f "$src" ]] || die "not a file: $src"
  base="$(basename "$src")"
  tgt="$staging/sysroot${dest}/$base"
  # strip CRLF if any
  if file "$src" | grep -qi 'CRLF'; then
    tr -d '\r' < "$src" > "$tgt"
  else
    cp -f "$src" "$tgt"
  fi
  chmod 0755 "$tgt"
  # basic shebang check (warn only)
  if ! head -n1 "$tgt" | grep -q '^#!'; then
    echo "warn: $base has no shebang (#!). It may still run if invoked by shell explicitly." >&2
  fi
done

# Ensure parent dir exists for output
mkdir -p "$(dirname "$out")"

# Create archive
if $use_xz; then
  # .tar.xz (test with your ISO; Ventoy LiveInjection examples use .tar.gz)
  [[ "$out" == *.tar.xz ]] || out="${out%.*}.tar.xz"
  (cd "$staging" && tar -cJf "$out" sysroot)
  mv "$staging/$out" "$out"
else
  # .tar.gz (recommended by LiveInjection docs)
  [[ "$out" == *.tar.gz ]] || out="${out%.*}.tar.gz"
  (cd "$staging" && tar -czf "$out" sysroot)
  mv "$staging/$out" "$out"
fi

echo "Created archive: $out"
echo "Contents:"
tar -tf "$out"
