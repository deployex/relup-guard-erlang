#!/usr/bin/env bash
set -euo pipefail

OLD_REF="$1"
NEW_REF="$2"
OLD_VERSION="${3:-}"
NEW_VERSION="${4:-}"
OUTCOME="${5:-unknown}"
HAD_WARNINGS="${6:-false}"

if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
  exit 0
fi

case "$OUTCOME" in
  success)
    if [ "$HAD_WARNINGS" = "true" ]; then
      RESULT="⚠️ upgrade succeeded, with warnings - see the step logs"
    else
      RESULT="✅ upgrade succeeded"
    fi
    ;;
  failure) RESULT="❌ upgrade failed" ;;
  cancelled) RESULT="⚪ cancelled" ;;
  *) RESULT="⚪ ${OUTCOME} (an earlier step didn't get this far)" ;;
esac

{
  echo "### relup-guard-erlang"
  echo
  echo "| | ref | version |"
  echo "|---|---|---|"
  echo "| old | \`${OLD_REF}\` | ${OLD_VERSION:-?} |"
  echo "| new | \`${NEW_REF}\` | ${NEW_VERSION:-?} |"
  echo
  echo "**Result:** ${RESULT}"
} >> "$GITHUB_STEP_SUMMARY"
