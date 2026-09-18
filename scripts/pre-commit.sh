#!/bin/sh
# The pre-commit hook. It runs postern from the PATH when it is there, and
# otherwise the release that matches this checkout's version, fetched once
# into the checkout, which pre-commit keeps in its cache.
set -eu

if command -v postern >/dev/null 2>&1; then
  exec postern check "$@"
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/.postern"
binary="$dir/postern"
if [ -x "$dir/postern.exe" ]; then binary="$dir/postern.exe"; fi

if [ ! -x "$binary" ]; then
  version="$(sed -n 's/^ *version: "\([^"]*\)".*/\1/p' "$root/mix.exs")"
  binary="$(sh "$root/scripts/install.sh" --dir "$dir" --version "$version")"
fi

exec "$binary" check "$@"
