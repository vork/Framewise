#!/bin/bash
# Print the body of a single version's section from CHANGELOG.md.
#
# Usage: extract-changelog.sh <version>          # e.g. 0.5.0 or v0.5.0
#        CHANGELOG_PATH=path/CHANGELOG.md extract-changelog.sh 0.5.0
#
# Prints the entries under "## [<version>] - <date>" up to (but not including)
# the next "## [" heading. Exits non-zero if the version isn't found.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <version>" >&2
  exit 2
fi

VERSION="${1#v}"
CHANGELOG="${CHANGELOG_PATH:-CHANGELOG.md}"

if [ ! -f "$CHANGELOG" ]; then
  echo "extract-changelog: $CHANGELOG not found" >&2
  exit 1
fi

# Stream the section into a variable so we can both validate and trim.
SECTION="$(awk -v ver="$VERSION" '
  # Match "## [<ver>]" exactly so 0.4.0 does not match 0.4.10.
  $0 ~ "^## \\[" ver "\\]([[:space:]]|$)" {
    in_section = 1
    next
  }
  in_section && /^## \[/ { exit }
  in_section { print }
' "$CHANGELOG")"

# Trim leading and trailing blank lines.
SECTION="$(printf '%s' "$SECTION" | awk '
  NF { if (!started) started = 1; buf = buf $0 ORS; next }
  started { buf = buf $0 ORS }
  END {
    sub(/[[:space:]]+$/, "", buf)
    if (length(buf)) print buf
  }
')"

if [ -z "$SECTION" ]; then
  echo "extract-changelog: no section for version '$VERSION' in $CHANGELOG" >&2
  exit 1
fi

printf '%s\n' "$SECTION"
