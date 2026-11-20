#!/usr/bin/env bash
set -euo pipefail

# Appends a short, build-only suffix (derived from REF, so old-ref and
# new-ref always get a different one) to every OTP application's own vsn
# this project defines, plus the relx release tuple's own vsn if it's a
# literal - so a relup has something real to diff even when nobody
# bumped a vsn by hand for this change. Only ever touches the ephemeral
# checkout build-release.sh's own `git checkout --force` just produced,
# never anything committed - and runs unconditionally, on both old-ref
# and new-ref, rather than only reacting after the fact to the two
# resolving to the same version: by the time that would be noticed,
# relx's in-place rebuild has already overwritten old-ref's own
# releases/<vsn>/ and lib/<app>-<vsn>/ directories, with nothing left to
# diff against.
#
# build-release.sh sources this file - rather than executing it as a
# separate process - specifically so it can do so BEFORE its own
# `git checkout --force "$REF"`. This repo's own CI builds its fixture
# app from inside this same repository (old-ref/new-ref are commits in
# relup-guard-erlang's own history, not a separate consumer repo's), so
# checking out an old-ref that predates this file would otherwise
# delete it from disk before a later, separate `patch-version.sh`
# process invocation could even start - a real consumer never hits
# this, since its own checkout never touches the action's own files,
# which live under a separate, already-resolved action_path.
#
# REF, RELEASE_NAME, WORKING_DIRECTORY, and SUFFIX are build-release.sh's
# own variables, already set by the time it sources this file - defining
# the functions below against them here, rather than re-declaring them
# as this script's own positional parameters, is what makes sourcing
# before the checkout equivalent to running this as its own process
# after it.

# A plain recursive search for *.app.src covers a single-app project
# (src/<app>.app.src) and an umbrella (apps/*/src/<app>.app.src) alike,
# with no need to tell which shape a given project uses - excluding
# _build/_checkouts/deps/.git keeps it from also "patching" a fetched
# dependency's own vendored .app.src, which isn't this project's to
# change and isn't what a relup here is about anyway.
patch_app_versions() {
  local f vsn
  while IFS= read -r -d '' f; do
    vsn="$(grep -oE '\{vsn, *"[^"]*"' "$f" | head -1 | grep -oE '"[^"]*"' | tr -d '"')"

    if [ -z "$vsn" ]; then
      echo "::error title=No vsn found::${f} has no {vsn, \"...\"} tuple relup-guard-erlang could parse."
      exit 1
    fi

    case "$vsn" in
      git)
        # rebar3's own built-in convention for a vsn that's already
        # unique per commit (substituted with `git describe` output at
        # compile time) - patching it would corrupt the literal string
        # "git" into something rebar3 no longer recognizes, and there's
        # nothing to fix here anyway since it already satisfies the same
        # goal on its own.
        echo "Skipping ${f}: {vsn, \"git\"} already resolves to a unique value per commit."
        ;;
      *+*)
        # Already carries a suffix of its own (a previous run of this
        # same patch, or a convention the project already had) - leave
        # it alone rather than stacking another suffix onto it.
        ;;
      *)
        perl -i -pe "s/\\{vsn, *\"\\Q${vsn}\\E\"/{vsn, \"${vsn}+${SUFFIX}\"/" "$f"
        echo "Patched ${f}: vsn ${vsn} -> ${vsn}+${SUFFIX}"
        ;;
    esac
  done < <(find "$WORKING_DIRECTORY" \
    \( -path '*/_build' -o -path '*/_checkouts' -o -path '*/deps' -o -path '*/.git' \) -prune \
    -o -name '*.app.src' -print0)
}

# The relx release tuple's own vsn in rebar.config is a separate field
# from any app's .app.src vsn - sometimes a literal of its own, sometimes
# tied to a same-named app via the `semver` keyword. build-release.sh
# detects a "new version" by this release-level vsn alone (the
# releases/<vsn>/ directory relx wrote), so it has to change too, even
# though patch_app_versions above is what actually makes the upgrade
# itself meaningful.
patch_relx_release_vsn() {
  local rebar_config="${WORKING_DIRECTORY}/rebar.config"
  local vsn

  [ -f "$rebar_config" ] || return 0

  vsn="$(grep -oE "\\{release, *\\{${RELEASE_NAME}, *\"[^\"]*\"" "$rebar_config" \
    | head -1 | grep -oE '"[^"]*"' | tr -d '"')"

  # Empty means either release-name doesn't match any release tuple here
  # (a working-directory/release-name mismatch that build-release.sh's
  # own later checks already report clearly), or the tuple uses relx's
  # `semver` keyword instead of a literal string - meaning it already
  # derives this release's own vsn from the matching app's vsn
  # automatically, which patch_app_versions above just took care of.
  # Either way, there is nothing of ours to patch here.
  case "$vsn" in
    "" | *+*) return 0 ;;
  esac

  perl -i -pe "s/\\{release, *\\{${RELEASE_NAME}, *\"\\Q${vsn}\\E\"/{release, {${RELEASE_NAME}, \"${vsn}+${SUFFIX}\"/" "$rebar_config"
  echo "Patched ${rebar_config}: release ${RELEASE_NAME} vsn ${vsn} -> ${vsn}+${SUFFIX}"
}
