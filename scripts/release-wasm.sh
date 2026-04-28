#!/usr/bin/env bash
#
# Build the WASM package, publish it to npm at the given version, then
# create and push a matching git tag.
#
# packages/wasm/package.json stays at "0.1.0" in the repo. The version edit
# is applied locally and reverted on exit (success or failure) via a trap,
# so the working tree never lingers dirty.
#
# Usage: scripts/release-wasm.sh <version> [--rc]
#   --rc  Publish under the `next` dist-tag instead of `latest`. Use this
#         for release candidates so they don't become the default install
#         resolved by `npm install @agicash/breez-sdk-spark`.
#
# Examples:
#   scripts/release-wasm.sh 0.13.5-1            # publishes under `latest`
#   scripts/release-wasm.sh 0.13.5-2-rc.1 --rc  # publishes under `next`

set -euo pipefail

VERSION=""
RC=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rc) RC=true ;;
        -*) echo "Unknown flag: $1" >&2; exit 1 ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "Unexpected positional argument: $1" >&2
                exit 1
            fi
            VERSION="$1"
            ;;
    esac
    shift
done

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version> [--rc]" >&2
    exit 1
fi

NPM_TAG="latest"
if [[ "$RC" == "true" ]]; then
    NPM_TAG="next"
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree is dirty. Commit or stash changes before releasing." >&2
    exit 1
fi

TAG="v$VERSION"
if git rev-parse --verify --quiet "$TAG" >/dev/null; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

# `:/` is a git path relative to the repo root, so the trap restores the
# file regardless of cwd at exit time.
trap 'git checkout -- :/packages/wasm/package.json' EXIT

echo "Building WASM package..."
cargo xtask package wasm

cd packages/wasm
echo "Setting version to $VERSION..."
npm --no-git-tag-version --allow-same-version version "$VERSION"

echo "Publishing to npm (dist-tag: $NPM_TAG)..."
npm publish --access public --tag "$NPM_TAG"

cd "$REPO_ROOT"

echo "Creating and pushing tag $TAG..."
git tag "$TAG"
git push origin "$TAG"

echo "Released $VERSION as $TAG (npm dist-tag: $NPM_TAG)."
