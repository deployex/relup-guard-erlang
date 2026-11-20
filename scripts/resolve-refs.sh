#!/usr/bin/env bash
set -euo pipefail

# Resolves old-ref and new-ref to concrete commit SHAs before anything
# checks out old-ref and moves the working tree. Both refs are evaluated
# against the SAME, still-pristine checkout the calling workflow set up -
# critical for new-ref's own documented default of "HEAD": once old-ref
# has been checked out, the literal string "HEAD" no longer means "the
# commit the job originally checked out", it means "whatever we're
# currently sitting on" (old-ref itself). Resolving both refs up front,
# before either checkout happens, avoids that entirely.
OLD_REF="$1"
NEW_REF="$2"

resolve() {
  local label="$1" ref="$2" sha
  # The error annotation goes to stderr, not stdout - this function's
  # stdout is captured by a command substitution below (that's how the
  # resolved sha gets back to the caller), and a $(...) capture only
  # takes stdout. An echo here without >&2 would silently vanish into
  # that capture instead of ever reaching the log.
  if ! sha=$(git rev-parse --verify "${ref}^{commit}" 2>&1); then
    echo "::error title=Could not resolve ${label}::'${ref}' is not a commit this checkout knows about: ${sha}. The most common cause is the calling workflow's own actions/checkout step missing fetch-depth: 0, which leaves only a shallow slice of history - ${ref} (and whatever it needs to diff against) has to actually be present locally for this to work." >&2
    exit 1
  fi
  echo "$sha"
}

OLD_SHA=$(resolve "old-ref" "$OLD_REF")
NEW_SHA=$(resolve "new-ref" "$NEW_REF")

echo "Resolved old-ref '${OLD_REF}' -> ${OLD_SHA}"
echo "Resolved new-ref '${NEW_REF}' -> ${NEW_SHA}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "old-sha=${OLD_SHA}"
    echo "new-sha=${NEW_SHA}"
  } >> "$GITHUB_OUTPUT"
fi
