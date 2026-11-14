#!/bin/sh
# Every SDK carries the same version: in its manifest and in the client's user-agent constant.
#   scripts/version.sh            prints the current version (from js/package.json)
#   scripts/version.sh check 1.2.3 fails unless every place says 1.2.3
#   scripts/version.sh bump 1.2.3  rewrites every place (and the tests that assert the user-agent) to 1.2.3
set -eu
cd "$(dirname "$0")/.."
current=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' js/package.json | head -1)
files="js/package.json js/src/index.ts python/pyproject.toml python/src/sendclap/__init__.py go/sendclap.go rust/Cargo.toml rust/src/lib.rs dotnet/src/Sendclap/Sendclap.csproj php/src/Http.php"
case "${1:-}" in
  "") echo "$current" ;;
  check)
    want=${2#v}; bad=0
    for f in $files; do grep -q "$want" "$f" || { echo "$f does not say $want" >&2; bad=1; }; done
    exit $bad ;;
  bump)
    new=${2#v}
    for f in $files js/package-lock.json rust/Cargo.lock go/sendclap_test.go python/tests/test_sendclap.py js/test/sendclap.test.mjs rust/tests/client.rs php/tests/run.php dotnet/tests/Sendclap.Tests/ClientTests.cs; do
      # only the sendclap lines in the lockfiles: other packages may share the old version number
      case "$f" in
        rust/Cargo.lock) awk -v o="$current" -v n="$new" '/^name = "sendclap"$/{s=1} s&&$0=="version = \""o"\""{$0="version = \""n"\"";s=0} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
        js/package-lock.json) awk -v o="$current" -v n="$new" 'NR<=10{gsub("\"version\": \""o"\"", "\"version\": \""n"\"")} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
        *) sed -i.bak "s/$current/$new/g" "$f" && rm "$f.bak" ;;
      esac
    done
    "$0" check "$new" && echo "now $new" ;;
  *) echo "usage: $0 [check|bump] [version]" >&2; exit 2 ;;
esac
