#!/usr/bin/env bash
#
# Checks that every QML file in the repository still parses.
#
#   test/qml.sh
#
# Uses qmlformat rather than qmllint, deliberately. qmllint does semantic
# analysis, and Omarchy's qs.Commons and qs.Ui cannot be installed on a CI
# runner - so every reference to Style, Color, or a shared component becomes an
# "unqualified access" warning, and some qmllint versions exit non-zero on
# warnings. The build then fails for a reason that has nothing to do with the
# code. qmlformat only parses, which is the question worth failing a build
# over: does this file still load?
#
# The one adjustment is `function name(): void`. The QML engine accepts it and
# Quickshell's own IpcHandler documentation uses it, but the parser behind
# qmlformat and qmllint does not. Normalising it away beats skipping
# BarWidget.qml, which is where the entire IPC surface lives.

set -uo pipefail

cd "$(dirname "$0")/.."

# Qt's tools write their diagnostics through the logging category machinery,
# which stays silent unless it believes it has a console.
export QT_FORCE_STDERR_LOGGING=1

if ! command -v qmlformat >/dev/null 2>&1; then
  echo "qmlformat not found." >&2
  echo "  Arch:          pacman -S qt6-declarative" >&2
  echo "  Debian/Ubuntu: apt install qt6-declarative-dev-tools" >&2
  exit 127
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

status=0
count=0
for file in *.qml; do
  sed 's/(): void/()/g' "$file" > "$work/$file"
  if qmlformat "$work/$file" >/dev/null; then
    count=$((count + 1))
  else
    echo "FAIL  $file does not parse" >&2
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "all $count QML files parse"
exit "$status"
