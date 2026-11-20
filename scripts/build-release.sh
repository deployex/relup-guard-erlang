#!/usr/bin/env bash
set -euo pipefail

# Checks out REF *in place* (no worktree) and builds the release there.
#
# old-ref and new-ref are built sequentially in the same working
# directory/_build, not isolated worktrees: rebar3/relx preserves each
# version's own releases/<vsn>/ and lib/<app>-<vsn>/ directories across
# in-place rebuilds in the same profile, which rebar3_appup_plugin needs
# to diff old against new the same way Jellyfish relies on the
# equivalent behavior for Mix.
REF="$1"
RELEASE_NAME="$2"
PROFILE="$3"
BUILD_COMMAND="${4:-rebar3 as ${PROFILE} release}"
EXCLUDE_VERSION="${5:-}"
WORKING_DIRECTORY="${6:-.}"
PREVIOUS_VERSION="${7:-}"

git checkout --force "$REF"

# Appends a build-only suffix to every vsn this project defines, so a
# relup has something real to diff even when nobody bumped a vsn by hand
# for this change - see patch-version.sh for why this has to happen now,
# before the build, rather than reactively after the fact.
"$(dirname "${BASH_SOURCE[0]}")/patch-version.sh" "$REF" "$RELEASE_NAME" "$WORKING_DIRECTORY"

cd "$WORKING_DIRECTORY" || exit 1
bash -euo pipefail -c "$BUILD_COMMAND"

RELEASE_ROOT="_build/${PROFILE}/rel/${RELEASE_NAME}"

if [ ! -d "$RELEASE_ROOT/releases" ]; then
  echo "::error title=Release not assembled::${RELEASE_ROOT}/releases does not exist after building ${REF}. Check that build-command actually assembles a release named '${RELEASE_NAME}' under profile '${PROFILE}' (e.g. 'rebar3 as ${PROFILE} release')."
  exit 1
fi

# Version dirs persist across in-place rebuilds (see above), so after
# building new-ref there are normally two: old-ref's and new-ref's.
# Excluding the already-known one (old-ref's own version, passed in as
# EXCLUDE_VERSION once it's been built) leaves exactly the version this
# call just produced - the same exclude-the-known-one approach
# build-release.sh's Mix counterpart uses for tarball filenames, applied
# here to version directories instead.
shopt -s nullglob
VERSION_DIRS=("$RELEASE_ROOT"/releases/*/)
shopt -u nullglob

CANDIDATES=()
if [ "${#VERSION_DIRS[@]}" -gt 0 ]; then
  for d in "${VERSION_DIRS[@]}"; do
    v="$(basename "$d")"
    if [ "$v" != "$EXCLUDE_VERSION" ]; then
      CANDIDATES+=("$v")
    fi
  done
fi

if [ "${#CANDIDATES[@]}" -ne 1 ]; then
  echo "::error title=Expected exactly one new release version::${RELEASE_ROOT}/releases at ${REF} has ${#CANDIDATES[@]} version(s) other than '${EXCLUDE_VERSION:-<none>}': ${CANDIDATES[*]:-none}. relup-guard-erlang already appends a build-only, per-commit suffix to every vsn it found, so this almost always means old-ref and new-ref resolved to the exact same commit - there's nothing to build a second version from. If they're genuinely different commits, check that the relx release tuple in rebar.config actually names '${RELEASE_NAME}' and uses a literal vsn string or 'semver', not something this action's patching step couldn't recognize."
  exit 1
fi

VERSION="${CANDIDATES[0]}"

# release_handler:unpack_release/1 needs a FLAT releases/<name>-<vsn>.rel
# file; relx's own nested releases/<vsn>/<name>.rel does not satisfy it,
# and fails with an enoent error naming that exact missing path. Same
# requirement Jellyfish solves for Mix; relx just doesn't produce this
# flat copy on its own.
NESTED_REL="${RELEASE_ROOT}/releases/${VERSION}/${RELEASE_NAME}.rel"
if [ ! -f "$NESTED_REL" ]; then
  echo "::error title=Release .rel file not found::${NESTED_REL} does not exist. release-name ('${RELEASE_NAME}') must match the file relx actually wrote there, which comes from the release name in rebar.config's relx release tuple - a mismatch here (e.g. a multi-app release where release-name was given as one of the apps rather than the release itself) is the most common cause."
  exit 1
fi
cp "$NESTED_REL" "${RELEASE_ROOT}/releases/${RELEASE_NAME}-${VERSION}.rel"

# Only when building new-ref (old-ref has nothing to diff against yet).
#
# A plugin that hooks appup generation into the normal build - e.g.
# rebar3_jellyfish_plugin's {provider_hooks, [{post, [{compile, ...}]}]}
# - already left a .appup under each changed app's own versioned
# lib/<app>-<vsn>/ebin/ by the time "$BUILD_COMMAND" above returns.
# There's nothing left for this step to do in that case, and it must not
# try anyway: rebar3_appup_plugin is the only thing that understands the
# `rebar3 appup generate --previous/--current` invocation below, so
# running it unconditionally fails outright - "Command appup not found" -
# for any project using a different (or no) appup-generating plugin.
#
# rebar3_appup_plugin itself needs this explicit call: its own
# provider_hooks.tar hook does a different thing (state record migration
# code injection, not appup diffing), and it writes what it generates to
# a shared, unversioned location keyed by RELEASE_NAME - which only
# lines up with an actual OTP application when the release is a
# single-app one named after that application. Multi-app/umbrella
# projects aren't supported by this fallback; use a hook-based plugin
# for those instead.
shopt -s nullglob
EXISTING_APPUPS=("${RELEASE_ROOT}"/lib/*-"${VERSION}"/ebin/*.appup)
shopt -u nullglob

if [ -n "$PREVIOUS_VERSION" ] && [ "${#EXISTING_APPUPS[@]}" -eq 0 ]; then
  bash -euo pipefail -c "rebar3 as ${PROFILE} appup generate --previous ${RELEASE_ROOT} --previous_version ${PREVIOUS_VERSION} --current ${RELEASE_ROOT}"

  GENERATED_APPUP="_build/${PROFILE}/lib/${RELEASE_NAME}/ebin/${RELEASE_NAME}.appup"
  if [ ! -f "$GENERATED_APPUP" ]; then
    echo "::error title=No appup generated::Expected ${GENERATED_APPUP} after 'rebar3 appup generate' diffing ${PREVIOUS_VERSION} against ${VERSION}, but it wasn't created. relup-guard-erlang already appends a build-only suffix to '${RELEASE_NAME}.app.src' so its vsn always changes, so this is more likely rebar3_appup_plugin itself failing to find or diff that app - check the step's own log above for its actual output."
    exit 1
  fi

  cp "$GENERATED_APPUP" "${RELEASE_ROOT}/lib/${RELEASE_NAME}-${VERSION}/ebin/${RELEASE_NAME}.appup"
elif [ -n "$PREVIOUS_VERSION" ]; then
  echo "Found $(IFS=,; echo "${EXISTING_APPUPS[*]}") already under ${RELEASE_ROOT}/lib - skipping rebar3_appup_plugin's explicit 'appup generate' step."
fi

# Packaged with plain tar, not 'rebar3 ... tar': that command always
# re-triggers a fresh release assembly first (visible as its own
# "Assembling release..." log line even when only tar was asked for),
# and that re-assembly silently wipes anything placed directly under
# releases/ moments earlier, including the flat .rel file above. The
# per-version lib/<app>-<vsn>/ebin/ directories are left alone by that
# re-assembly, but relying on that asymmetry would be fragile - packaging
# the tarball directly, without a further relx assembly step in between,
# avoids it entirely.
# A nullglob, not `find | basename`: chaining basename onto a possibly-
# empty find result depends on that specific basename implementation's
# handling of an empty argument (POSIX explicitly allows returning "."
# there) - a glob that simply matches nothing is unambiguous either
# way, with no implementation-specific edge case to depend on.
shopt -s nullglob
ERTS_DIRS=("$RELEASE_ROOT"/erts-*/)
shopt -u nullglob

TAR_ARGS=(lib releases bin)
if [ "${#ERTS_DIRS[@]}" -gt 0 ]; then
  TAR_ARGS+=("$(basename "${ERTS_DIRS[0]}")")
fi

TARBALL="${RELEASE_ROOT}/${RELEASE_NAME}-${VERSION}.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$RELEASE_ROOT" "${TAR_ARGS[@]}"

ABS_TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"

echo "Built ${RELEASE_NAME} ${VERSION} from ${REF} -> ${ABS_TARBALL}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=${VERSION}"
    echo "tarball=${ABS_TARBALL}"
  } >> "$GITHUB_OUTPUT"
fi
