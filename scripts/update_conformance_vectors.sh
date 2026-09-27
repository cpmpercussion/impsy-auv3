#!/usr/bin/env bash
# Copy IMPSY's conformance vectors (spec/vectors + spec/models) from a tagged
# release of the sibling IMPSY checkout into Tests/Conformance/.
#
#   ./scripts/update_conformance_vectors.sh v1.2.1
#   IMPSY_DIR=/path/to/impsy ./scripts/update_conformance_vectors.sh v1.3.0
#
# The vectors are copied rather than read from ../impsy at test time so the
# suite is pinned to a known spec version and runs on Xcode Cloud, where the
# sibling checkout doesn't exist. See ../impsy/spec/README.md.
set -euo pipefail

TAG="${1:?usage: $0 <impsy-tag>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMPSY_DIR="${IMPSY_DIR:-$ROOT/../impsy}"
DEST="$ROOT/Tests/Conformance"

commit="$(git -C "$IMPSY_DIR" rev-parse --verify "$TAG^{commit}")"

rm -rf "$DEST/vectors" "$DEST/models"
mkdir -p "$DEST"
git -C "$IMPSY_DIR" archive "$commit" spec/vectors spec/models \
    | tar -x -C "$DEST" --strip-components=1

spec_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["spec_version"])' "$DEST/vectors/midi_input.json")"

cat > "$DEST/SOURCE" <<EOF
impsy_tag=$TAG
impsy_commit=$commit
spec_version=$spec_version
EOF

echo "Copied IMPSY conformance vectors $spec_version from $TAG ($commit) into $DEST"
