#!/usr/bin/env bash
set -euo pipefail

RELEASE_NAME="$1"
OLD_TARBALL="$2"
NEW_TARBALL="$3"
OLD_VERSION="$4"
NEW_VERSION="$5"
BOOT_TIMEOUT="${6:-30}"
UPGRADE_TIMEOUT="${7:-60}"
FAIL_ON_WARNINGS="${8:-false}"

# Same validation, same rationale, as relup-guard-elixir's own
# run-upgrade.sh - this part is not build-tool specific.
for pair in "boot-timeout-seconds:${BOOT_TIMEOUT}" "upgrade-timeout-seconds:${UPGRADE_TIMEOUT}"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "::error title=Invalid ${name}::'${value}' is not a non-negative integer."
    exit 1
  fi
done

EXTRACT_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/relup-guard-erlang-old.XXXXXX")
tar -xzf "$OLD_TARBALL" -C "$EXTRACT_DIR"

UNIQUE_SUFFIX="$(date +%s)_$$"

cd "$EXTRACT_DIR" || exit 1

# Unlike Mix, where exporting RELEASE_NODE/RELEASE_COOKIE overrides the
# node name a release boots with, relx's vm.args is a plain file the
# extended start script reads -sname/-setcookie out of directly; setting
# those as env vars instead has no effect at all. The existing lines are
# replaced in place with sed, not appended to: the extended start script
# scans vm.args first and refuses to start at all if it finds
# -name/-sname more than once ("... parameter found in ... but already
# specified as ..."), rather than letting a later line win the way plain
# erl's own argument parsing would. Unique per invocation, not just the
# cookie: a fixed name is fine on a GitHub-hosted runner (a fresh VM per
# job), but would collide with anything else using the release's own
# default node name on a reused self-hosted runner.
VM_ARGS_FILE="releases/${OLD_VERSION}/vm.args"
if [ -f "$VM_ARGS_FILE" ]; then
  # A temp file plus mv, not `sed -i`: BSD sed (macOS, used for local
  # verification) and GNU sed (the GitHub-hosted runners this actually
  # runs on) take that flag's in-place-edit suffix differently, so this
  # avoids the discrepancy entirely rather than special-casing it.
  sed \
    -e "s/^-s\{0,1\}name .*/-sname relup_guard_erlang_old_${UNIQUE_SUFFIX}/" \
    -e "s/^-setcookie .*/-setcookie relup-guard-erlang-${UNIQUE_SUFFIX}/" \
    "$VM_ARGS_FILE" > "${VM_ARGS_FILE}.tmp"
  mv "${VM_ARGS_FILE}.tmp" "$VM_ARGS_FILE"
fi

# Same rationale as the Mix side: Erlang distribution binds to all
# interfaces once a node name is set, regardless of the node name's own
# hostname. Only one vm.args file to patch here, unlike Mix's
# vm.args + remote.vm.args pair: the ephemeral node the extended start
# script spins up for each `eval` call is started with -dist_listen
# false (it only ever connects out, never listens), so there's nothing
# on that side needing the same restriction. The extended start script
# already greps this exact "-kernel inet_dist_use_interface" line out of
# vm.args itself and forwards it when starting the main node, so
# appending it here is read automatically, not something extra to wire up.
if [ -f "$VM_ARGS_FILE" ]; then
  echo '-kernel inet_dist_use_interface {127,0,0,1}' >> "$VM_ARGS_FILE"
fi

cleanup() {
  ./bin/"${RELEASE_NAME}" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Booting old release (${OLD_VERSION}) as a daemon..."
./bin/"${RELEASE_NAME}" daemon

echo "Waiting for ${RELEASE_NAME} to come up (timeout ${BOOT_TIMEOUT}s)..."
booted=false
for ((i = 1; i <= BOOT_TIMEOUT; i++)); do
  if ./bin/"${RELEASE_NAME}" pid >/dev/null 2>&1; then
    booted=true
    break
  fi
  sleep 1
done

if [ "$booted" != true ]; then
  echo "::error title=Release did not boot::${RELEASE_NAME} did not boot within ${BOOT_TIMEOUT}s."
  exit 1
fi
echo "Node is up."

# Same rationale as the Mix side: confirms a genuine hot swap, not a
# disguised restart, by comparing the OS pid before and after.
OLD_OS_PID=$(./bin/"${RELEASE_NAME}" pid)
echo "OS pid before upgrade: ${OLD_OS_PID}"

mkdir -p releases
cp "$NEW_TARBALL" releases/
NEW_TARBALL_BASENAME=$(basename "$NEW_TARBALL")
UNPACK_NAME=${NEW_TARBALL_BASENAME%.tar.gz}

# bin/<name> eval only returns the evaluated expression's final value -
# it does not capture io:format output the way Mix's rpc subcommand
# does, so an io:format call inside an eval'd expression never reaches
# this script's stdout at all. So instead of the sentinel-prefixed print
# lines the Mix side greps out of its own captured rpc output, this
# writes the result to a plain file on the shared filesystem - both this
# script and the node it starts are on the same machine, so a file is a
# perfectly ordinary way to get a structured result back, not a
# workaround for being unable to use rpc.
RESULT_FILE=$(mktemp "${RUNNER_TEMP:-/tmp}/relup-guard-erlang-result.XXXXXX")
rm -f "$RESULT_FILE"

RPC_EXPR=$(cat <<EOF
ResultFile = "${RESULT_FILE}",
UnpackName = "${UNPACK_NAME}",
NewVsn = "${NEW_VERSION}",
OldVsn = "${OLD_VERSION}",
RelName = "${RELEASE_NAME}",
try
    ModulesBefore = sets:from_list([M || {M, _} <- code:all_loaded()]),
    case release_handler:unpack_release(UnpackName) of
        {ok, _} ->
            ok;
        {error, {enoent, EnoentPath}} ->
            throw({relup_guard_fail,
                io_lib:format(
                    "unpack_release failed: ~s does not exist. release_handler:unpack_release/1 needs a FLAT releases/<name>-<vsn>.rel file inside the tarball - relx's own nested releases/<vsn>/<name>.rel is not enough on its own.",
                    [EnoentPath])});
        {error, UnpackReason} ->
            throw({relup_guard_fail, io_lib:format("unpack_release failed: ~p", [UnpackReason])})
    end,
    Root = code:root_dir(),
    NewRel = filename:join([Root, "releases", NewVsn, RelName]),
    OldRel = filename:join([Root, "releases", OldVsn, RelName]),
    LibGlob = filename:join([Root, "lib", "*", "ebin"]),
    OutDir = filename:join([Root, "releases", NewVsn]),
    {Warnings, Relup} =
        case systools:make_relup(NewRel, [OldRel], [OldRel], [silent, {path, [LibGlob]}, {outdir, OutDir}]) of
            {ok, RelupResult, _RelupMod, W} ->
                {W, RelupResult};
            {error, RelupMod, RelupErr} ->
                throw({relup_guard_fail,
                    io_lib:format("systools:make_relup failed: ~s", [RelupMod:format_error(RelupErr)])})
        end,
    WarningsStr = case Warnings of
        [] -> "";
        _ -> io_lib:format("~p", [Warnings])
    end,
    {_RelupVsn, UpFromScripts, _DownToScripts} = Relup,
    Instructions = case lists:keyfind(OldVsn, 1, UpFromScripts) of
        {OldVsn, _Descr, Instrs} -> Instrs;
        false -> []
    end,
    LoadedByRelup = sets:from_list(
        lists:flatten([Mods || {load_object_code, {_App, _AppVsn, Mods}} <- Instructions])
    ),
    NewModules = sets:subtract(LoadedByRelup, ModulesBefore),
    HasApply = lists:any(fun({apply, _}) -> true; (_) -> false end, Instructions),
    UnstartedStr = case sets:size(NewModules) > 0 andalso not HasApply of
        true -> io_lib:format("~p", [lists:sort(sets:to_list(NewModules))]);
        false -> ""
    end,
    {ok, _, _} = release_handler:check_install_release(NewVsn),
    case release_handler:install_release(NewVsn, []) of
        {ok, _, _} -> ok;
        {continue_after_restart, _, _} -> ok;
        InstallErr -> throw({relup_guard_fail, io_lib:format("install_release failed: ~p", [InstallErr])})
    end,
    ok = release_handler:make_permanent(NewVsn),
    Releases = release_handler:which_releases(),
    Permanent = lists:any(fun({_N, V, _A, S}) -> V =:= NewVsn andalso S =:= permanent end, Releases),
    case Permanent of
        true ->
            file:write_file(ResultFile,
                io_lib:format("RELUP_GUARD_OK~nRELUP_GUARD_WARNINGS:~s~nRELUP_GUARD_UNSTARTED_MODULES:~s~n",
                    [WarningsStr, UnstartedStr]));
        false ->
            file:write_file(ResultFile,
                io_lib:format("RELUP_GUARD_FAIL:new version not permanent after install, which_releases=~p~n",
                    [Releases]))
    end
catch
    throw:{relup_guard_fail, FailMsg} ->
        file:write_file(ResultFile, io_lib:format("RELUP_GUARD_FAIL:~s~n", [FailMsg]));
    CatchKind:CatchReason ->
        file:write_file(ResultFile, io_lib:format("RELUP_GUARD_FAIL:~p ~p~n", [CatchKind, CatchReason]))
end.
EOF
)

echo "Synthesizing and applying the upgrade ${OLD_VERSION} -> ${NEW_VERSION} (timeout ${UPGRADE_TIMEOUT}s)..."

# Bounded with timeout(1), same as the Mix side, for the same reason: a
# hang here is almost always release_handler waiting on a process that
# never acknowledges a suspend/code_change. The timeout wraps the whole
# eval subcommand process regardless of what its own exit code or output
# would otherwise mean.
#
# -k/--kill-after is not optional here, unlike a plain `timeout DURATION
# CMD` would be for most commands: the escript wrapper `bin/<name> eval`
# spawns does not die promptly on the SIGTERM timeout(1) sends on its
# own when it's genuinely blocked waiting on a suspended node, so a
# forced follow-up kill is needed to keep the actual wall-clock time
# close to what upgrade-timeout-seconds promises rather than several
# minutes past it. The grace period is deliberately short (not scaled
# with UPGRADE_TIMEOUT): by the time SIGTERM has already been sent, the
# upgrade has already failed to meet its bound, so there's nothing to
# wait longer for.
set +e
timeout -k 5 "${UPGRADE_TIMEOUT}" ./bin/"${RELEASE_NAME}" eval "$RPC_EXPR" >/dev/null 2>&1
RPC_EXIT=$?
set -e

if [ "$RPC_EXIT" -eq 124 ]; then
  echo "::error title=Hot upgrade timed out::Hot upgrade to ${NEW_VERSION} did not complete within ${UPGRADE_TIMEOUT}s and was killed. This usually means systools:make_relup or release_handler:install_release hung (e.g. a process not acknowledging code_change) rather than failing cleanly - raise the upgrade-timeout-seconds input if your release is just slow, otherwise treat this as a bug in the upgrade path itself."
  exit 1
fi

if [ ! -f "$RESULT_FILE" ]; then
  echo "::error title=Hot upgrade failed::No result file was written to ${RESULT_FILE}. This means eval itself failed before the upgrade expression's own try/catch could run (e.g. the node was unreachable) - rerun with boot-timeout-seconds raised if this is a boot/connection issue, otherwise treat this as a bug in the upgrade path itself."
  exit 1
fi

RPC_OUTPUT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"
echo "$RPC_OUTPUT"

if ! echo "$RPC_OUTPUT" | grep -q "RELUP_GUARD_OK"; then
  echo "::error title=Hot upgrade failed::Hot upgrade to ${NEW_VERSION} failed. See the result above for the root cause."
  exit 1
fi

RELUP_WARNINGS=$(echo "$RPC_OUTPUT" | grep "RELUP_GUARD_WARNINGS:" | sed 's/^RELUP_GUARD_WARNINGS://' || true)
if [ -n "$RELUP_WARNINGS" ]; then
  if [ "$FAIL_ON_WARNINGS" = "true" ]; then
    echo "::error title=systools reported relup warnings (fail-on-warnings is true)::${RELUP_WARNINGS}"
    exit 1
  fi
  echo "::warning title=systools reported relup warnings::${RELUP_WARNINGS}"
fi

UNSTARTED_MODULES=$(echo "$RPC_OUTPUT" | grep "RELUP_GUARD_UNSTARTED_MODULES:" | sed 's/^RELUP_GUARD_UNSTARTED_MODULES://' || true)
if [ -n "$UNSTARTED_MODULES" ]; then
  MESSAGE="The relup loads ${UNSTARTED_MODULES} but has no apply instruction anywhere in this upgrade script. If any of these are meant to run as a new supervised process (not just be loaded as code - e.g. a new gen_server added as a supervisor child), it will NOT actually be started: load_object_code only loads code, starting a new child needs its own explicit apply instruction (e.g. supervisor:start_child), same as the OTP appup cookbook's documented pattern for this exact case. If these are ordinary new modules that nothing needs to start, this is expected and safe to ignore."
  if [ "$FAIL_ON_WARNINGS" = "true" ]; then
    echo "::error title=Relup may not start new supervised children (fail-on-warnings is true)::${MESSAGE}"
    exit 1
  fi
  echo "::warning title=Relup may not start new supervised children::${MESSAGE}"
fi

NEW_OS_PID=$(./bin/"${RELEASE_NAME}" pid 2>/dev/null || true)
if [ -z "$NEW_OS_PID" ] || [ "$NEW_OS_PID" != "$OLD_OS_PID" ]; then
  echo "::error title=Node restarted during upgrade::The OS process id changed from ${OLD_OS_PID} to ${NEW_OS_PID:-<gone>} while applying the upgrade. release_handler reported the upgrade as successful, but the node was actually restarted rather than hot-upgraded in place - any running state this appup wasn't told to carry forward was lost exactly as it would be on a full deploy."
  exit 1
fi
echo "OS pid unchanged (${OLD_OS_PID}): confirmed this was a hot code swap, not a restart."

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  if [ -n "$RELUP_WARNINGS" ] || [ -n "$UNSTARTED_MODULES" ]; then
    echo "had-warnings=true" >> "$GITHUB_OUTPUT"
  else
    echo "had-warnings=false" >> "$GITHUB_OUTPUT"
  fi
fi

echo "Hot upgrade to ${NEW_VERSION} succeeded."
