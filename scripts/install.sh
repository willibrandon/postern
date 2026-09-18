#!/bin/sh
# Installs the postern binary for this platform from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/willibrandon/postern/main/scripts/install.sh | sh
#
# Options: --dir DIR for where the binary goes, $HOME/.local/bin without it,
# and --version X.Y.Z for a release other than the latest. The checksum the
# release carries is verified before the binary is put in place, and the path
# is printed at the end.
set -eu

dir="${POSTERN_INSTALL_DIR:-$HOME/.local/bin}"
version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "postern has no release for $(uname -s); see https://github.com/willibrandon/postern/releases" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "postern has no release for $(uname -m); see https://github.com/willibrandon/postern/releases" >&2; exit 1 ;;
esac

if [ -z "$version" ]; then
  version="$(curl -fsSL https://api.github.com/repos/willibrandon/postern/releases/latest \
    | grep '"tag_name"' | head -n 1 | sed 's/.*"v\([^"]*\)".*/\1/')"
fi
[ -n "$version" ] || { echo "could not find the latest release" >&2; exit 1; }

asset="postern-$version-$os-$arch"
base="https://github.com/willibrandon/postern/releases/download/v$version"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
(
  cd "$tmp"
  if command -v sha256sum >/dev/null 2>&1; then
    grep " $asset\$" SHA256SUMS | sha256sum -c - >/dev/null
  else
    grep " $asset\$" SHA256SUMS | shasum -a 256 -c - >/dev/null
  fi
)

mkdir -p "$dir"
install -m 755 "$tmp/$asset" "$dir/postern"
echo "$dir/postern"
