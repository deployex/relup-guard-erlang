# relup-guard-erlang

CI action that verifies Erlang hot code upgrades actually work, by building old and new rebar3/relx releases and running a real relup before you merge.

Sibling project to [relup-guard-elixir](https://github.com/deployex/relup-guard-elixir), which does the same thing for Mix releases.
The two are kept separate rather than merged into one action, because rebar3/relx and Mix differ enough in where a release's tarball lands, how its appup gets generated, and what its boot script's subcommands do, that branching one action's logic by build tool would cost more than it saves.

## Why

A release can build cleanly and still fail to hot-upgrade: a missing appup, a `code_change/3` that doesn't match the new state shape, a dependency bump with no upgrade instructions.
Most CI pipelines only check that a release *builds*.
They never check that an upgrade into it actually *applies* against a live node.
`relup-guard-erlang` closes that gap: it builds the release at your PR's base ref and at its head in the same working directory (so rebar3 appup tooling can see both), boots the old release, and drives the same sequence a real deploy does - unpack, synthesize the relup, `check_install_release`, `install_release`, `make_permanent` - against it.
If any step fails, the PR fails, before the broken upgrade ever reaches production.

```mermaid
flowchart TB
    subgraph build["Build both releases (sequentially, same working directory)"]
        A["old-ref"] --> A1["rebar3 release<br/>+ build-only vsn suffix"]
        B["new-ref"] --> B1["rebar3 release<br/>+ build-only vsn suffix<br/>+ generate .appup vs old"]
    end

    A1 --> C["Boot old release<br/>as an isolated daemon"]
    B1 --> D["Unpack new release<br/>into the running node"]
    C --> D
    D --> E["Synthesize the relup<br/>systools:make_relup/4"]
    E --> F["Apply it for real<br/>check_install_release → install_release → make_permanent"]
    F --> G{"New version running?<br/>Same OS pid?"}
    G -->|yes| H["✅ Pass"]
    G -->|no / timeout| I["❌ Fail"]
```

## Prerequisites

Your project needs the following already in place; `relup-guard-erlang` does not set any of it up for you.

- [`rebar3_appup_plugin`](https://github.com/lrascao/rebar3_appup_plugin) (or an equivalent that produces the same `.appup` files) as a plugin in `rebar.config`. It does not produce a `relup`; `relup-guard-erlang` synthesizes that itself at upgrade time, the same way a real deploy does.
- The `:sasl` application included in the release, since `release_handler` lives there - already the case for a plain `rebar3 new release`.
- A supervised child's module (the one you expect a hot upgrade to migrate) actually registered as a child in your top supervisor's `init/1`. `release_handler` only attempts to suspend processes it can discover by walking the supervision tree - a process started any other way (a plain `spawn`, or linked directly from the application callback outside any supervisor) is never targeted by an upgrade instruction at all, and the upgrade will "succeed" without ever touching it.
- The calling workflow must check out the repository with `fetch-depth: 0`, so both `old-ref` and `new-ref` are reachable as git history.
- The calling workflow must set up the Erlang/rebar3 toolchain itself (e.g. with `erlef/setup-beam`), matching whatever `.tool-versions` or version pins your project uses.
- A Linux or macOS runner (e.g. `ubuntu-24.04`).
  relx releases only support daemon/pid/eval boot-script subcommands on Unix; Windows releases use a separate service wrapper with none of them, so `relup-guard-erlang` fails fast with an explanation rather than running on `windows-*`.

`relup-guard-erlang` checks out `old-ref` and then `new-ref` in place, in the job's own working directory, so it leaves the checkout on `new-ref` when it finishes.
Run it as its own job, or as the last step in a job, rather than before other steps that assume the original checkout is untouched.

## Usage

```yaml
name: Verify hot upgrade

on:
  pull_request:
    branches: [main]

jobs:
  relup-guard-erlang:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict

      - uses: deployex/relup-guard-erlang@v1
        with:
          old-ref: ${{ github.event.pull_request.base.sha }}
          release-name: my_app
```

Tags above are pinned to a major version, not a commit SHA: a tag can move to point at different code later, which a SHA cannot.
This repository's own `.github/workflows/ci.yml` makes the same choice, paired with a `.github/dependabot.yml` for the `github-actions` ecosystem that opens a PR whenever a pinned major version has a newer release.
If you'd rather not depend on that - a tag you don't control being trustworthy for as long as you use it - pin to a full commit SHA instead and keep the tag as a trailing comment, e.g. `uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`.

### Booting a release that needs environment variables

If your release reads environment variables in `sys.config`/`vm.args` (database URL, secret key, etc.), set those as `env` on the step that calls `relup-guard-erlang`, not as a `with:` input.
Composite action steps run inside the same job as the step that calls them, so any `env:` set there is inherited by every step inside `relup-guard-erlang`, including the one that actually boots the release:

```yaml
- uses: deployex/relup-guard-erlang@v1
  env:
    DATABASE_URL: ecto://postgres:postgres@localhost/my_app_test
    SECRET_KEY: ${{ secrets.SECRET_KEY }}
  with:
    old-ref: ${{ github.event.pull_request.base.sha }}
    release-name: my_app
```

A few things this doesn't cover:

- If your release checks out a real dependency on boot, such as a database, that dependency has to actually be reachable in the job (e.g. a `services:` container), the same as it would for any other test job.
- `relup-guard-erlang` gives the booted release a unique node name and cookie per run, not just on a single runner but across two concurrent jobs sharing the same self-hosted runner, where a fixed node name would otherwise let one job's calls land on the other job's node. It does this by rewriting the extracted release's own `vm.args` directly (replacing its `-sname`/`-setcookie` lines), not by setting environment variables: unlike Mix, where exporting `RELEASE_NODE`/`RELEASE_COOKIE` overrides the boot-time node identity, relx's extended start script reads those two flags straight out of `vm.args` and ignores environment variables entirely. If your own release's `vm.args` is unusual enough that this rewrite doesn't apply cleanly, this is the first thing to check.
- That `-sname`/`-setcookie` rewrite is a plain text substitution, independent of whether `RELX_REPLACE_OS_VARS` is set, so the node name and cookie always come up fine even if you've never touched that option.
  Any *other* `${SOME_VAR}`-style placeholder in your `vm.args` or `sys.config` (a TLS options file path, a custom distribution setting, anything your own release template puts there) is not covered by that rewrite, and relx only fills those in at boot if the calling job sets `RELX_REPLACE_OS_VARS: "true"` as `env:` on this step, with every variable the placeholder references also set.
  Without both, the literal, unresolved placeholder text gets passed straight to `erl`, and the release fails to boot.
  The same applies to any application code that reads an environment variable unconditionally on startup (e.g. parsing a port number with no check for whether it was actually set) - the job has to supply it, the same as it would in any other environment the release actually runs in.
- If the old release doesn't boot at all, `relup-guard-erlang` prints the tail of `relx`'s own boot log (and the start of `erl_crash.dump`, if the emulator itself went down rather than just an application) to the job log before failing, so the real reason - the unresolved placeholder above, a crashing application, a missing shared library, anything `erl` itself printed before giving up - is visible directly in this step's own output instead of only a "did not boot" timeout message.
- It also appends `-kernel inet_dist_use_interface {127,0,0,1}` to the extracted release's `vm.args`, restricting its Erlang distribution listener to loopback - only one file to patch here, unlike Mix's `vm.args`/`remote.vm.args` pair, since the ephemeral node relx's `eval` subcommand spins up for each call is started with `-dist_listen false` (it only ever connects out, never listens) and so has nothing to restrict. This matters most on a self-hosted runner reachable on a wider network: without it, Erlang distribution binds to every interface by default regardless of the node name's own hostname, leaving a short-lived window where the test node is reachable network-wide, guarded only by a cookie that (unlike a real production one) is just a timestamp and pid.
- If the upgrade itself raises - inside `unpack_release`/`make_relup`/`install_release`, or inside anything an `apply` instruction invokes as part of applying it, such as a newly-started child's `start_link` - or if the old release fails to boot in the first place, `relup-guard-erlang` prints the raw Erlang crash term, or boot log/crash dump excerpt, to the job log so the actual cause is visible, and that output can contain whatever value was in scope at the point of the crash, or whatever your own application logged on its way down. That's a problem if the value is a secret your own code fetched at runtime (e.g. from a secrets manager) rather than one that came in through this step's own `env:`. GitHub automatically masks values it already knows are secrets - the ones passed through its own `secrets:` context - but it has no way to know about a value your application fetched on its own, so that one can't be auto-masked by default. If that's a real risk for your release, mask it yourself in the calling workflow: GitHub's `::add-mask::` command (`echo "::add-mask::$THE_VALUE"`) matches by value wherever it later appears in the log, including from inside a nested crash dump this step prints.

### Booting a release that needs a database

If the release connects to a database on boot, the old release simply won't come up without that dependency reachable - the connection error itself should show up in the boot log `relup-guard-erlang` prints on a boot failure (see above), but the fix is the same either way.
Add the dependency as a `services:` container on the job, and point the release at it with `env:`, the same way you would for any other integration test job.

```yaml
jobs:
  relup-guard-erlang:
    runs-on: ubuntu-24.04
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict

      - uses: deployex/relup-guard-erlang@v1
        env:
          DATABASE_URL: ecto://postgres:postgres@localhost:5432/my_app
        with:
          old-ref: ${{ github.event.pull_request.base.sha }}
          release-name: my_app
```

If the schema needs to exist before the release will boot, run migrations against that database as a step before `relup-guard-erlang`, the same way you would before a normal integration test job.
`relup-guard-erlang` has no opinion on this either way - it boots whatever `bin/<name> daemon` boots, exactly as a real deploy would.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `old-ref` | yes | - | Git ref/SHA to build as the currently-deployed release. |
| `new-ref` | no | `HEAD` | Git ref/SHA to build as the release being tested. |
| `release-name` | yes | - | The release name from `rebar.config`'s relx release tuple. |
| `profile` | no | `prod` | rebar3 profile used to build both releases. |
| `working-directory` | no | `.` | Directory containing the `rebar.config` that defines the release, relative to the repository root. Use this when the release isn't built from the repository root. |
| `build-command` | no | `rebar3 as <profile> release` | Command run to assemble (not package) the release, once per ref, in `working-directory`. Must leave an assembled release under `_build/<profile>/rel/<release-name>`, not a tarball - this action packages the tarball itself once it has also injected the generated appup and a flat `.rel` file, both of which `release_handler` needs and relx does not produce on its own. |
| `boot-timeout-seconds` | no | `30` | How long to wait for the old release to boot before failing. Must be a non-negative integer - anything else fails fast with a clear error instead of being silently misread. |
| `upgrade-timeout-seconds` | no | `60` | How long to wait for the unpack/make_relup/install/make_permanent sequence to finish before treating it as hung and failing fast, rather than relying on the calling job's own timeout. Must be a non-negative integer - anything else fails fast with a clear error instead of being silently misread. |
| `fail-on-relup-warnings` | no | `false` | Treat `systools:make_relup/4` warnings, and relup-guard-erlang's own "module loaded but possibly never started" check, as failures instead of only annotating them with `::warning::`. |

### Outputs

| Output | Description |
|---|---|
| `old-version` | The version string built from `old-ref`. |
| `new-version` | The version string built from `new-ref`. |
| `had-warnings` | `"true"` if the upgrade succeeded but raised a relup warning (see step 7 below), `"false"` otherwise. |

## How it works

1. **Resolve old-ref and new-ref to commit SHAs first, before anything checks either one out.**
   This has to happen against the calling workflow's own pristine checkout: once old-ref is checked out in the next step, the literal string `"HEAD"` - new-ref's own default - no longer means "the commit the job originally checked out", it means "whatever we're currently sitting on", which by then is old-ref itself.
2. **Before each build, append a build-only suffix derived from that ref's own commit SHA to every `app.src` vsn found, plus the relx release tuple's own vsn if it's a literal.**
   A relup needs two distinct *application* versions to generate anything against - OTP's relup/appup mechanism is keyed on each app's own vsn, not on whether the underlying code actually changed - so without this, a PR that changes code without also bumping `app.src` by hand would have nothing to test. old-ref and new-ref always resolve to different commits, so they always get a different suffix, and a relup is always generated and tested for real. This only ever touches the ephemeral checkout, never anything committed.
3. **Build old-ref, then new-ref, in the same working directory.**
   relx preserves each version's own `releases/<vsn>/` and `lib/<app>-<vsn>/` directories across in-place rebuilds in the same profile, which `rebar3_appup_plugin` needs to diff old against new, so the two builds have to be sequential in place rather than in isolated worktrees.
4. **For new-ref specifically: generate the appup, then package the tarball by hand.**
   `rebar3 appup generate` (pointed at both versions explicitly - its own defaults don't do anything useful once two versions coexist) writes the `.appup` file into a shared, unversioned location, not into the assembled release's own `lib/<app>-<new-vsn>/ebin/` - this action copies it there itself, along with a flat `releases/<name>-<vsn>.rel` (see step 6). The tarball is then built with a plain `tar`, not relx's own `tar` command: that command always re-triggers a fresh release assembly first, which silently wipes anything placed directly under `releases/` moments earlier, including that flat `.rel` file.
5. **Fail fast if the versions are still identical.**
   The one case step 2's suffix can't paper over: old-ref and new-ref resolving to the exact same commit, which gets the exact same suffix too, and genuinely has no second version to relup against.
6. **Boot the old release as a daemon**, under a node name and cookie unique to this run (see the note on `vm.args` above) and with Erlang distribution restricted to loopback.
7. **Unpack the new release into it** via `release_handler:unpack_release/1`, which places the new `.rel` and `lib/<app>-<new-version>/ebin` alongside the old ones on the already-running node.
   If the tarball is missing the flat `.rel` file, this fails with a specific explanation naming that exact missing path, rather than the raw `{error, {enoent, Path}}` tuple `unpack_release/1` itself returns.
8. **Synthesize the relup** via `systools:make_relup/4`, now that both versions' `.rel` files and the new version's `.appup` file coexist on that node - this is the step most naive "does it build" checks skip entirely.
   Any warnings `systools` returns (not just its errors) are surfaced as a `::warning::` annotation rather than silently discarded - a relup that "succeeds" with warnings often means `systools` fell back to a cruder instruction than intended, such as reloading everything for a dependency that bumped version with no `.appup` of its own.
   Set `fail-on-relup-warnings: true` to turn that `::warning::` into a build failure instead, the same "warnings as errors" choice many build and lint tools offer.
   Separately, `relup-guard-erlang` also checks the relup for modules that get loaded but never started: if the new version introduces a module this node didn't have loaded before, and the upgrade script has no `apply` instruction anywhere, that's surfaced the same way (and controlled by the same `fail-on-relup-warnings` flag).
   This is a real gap in auto-generated appups, not a hypothetical one: a module *loading* successfully says nothing about whether it was wired into a supervisor, because `load`/`load_object_code` only load code - starting a new supervised child needs its own explicit `apply` instruction (e.g. `supervisor:start_child`), per the OTP appup cookbook's documented pattern for this exact case.
   A module flagged this way is not necessarily a bug - plenty of new modules aren't processes that need starting - so this stays a warning by default rather than a failure.
9. **Apply it for real, bounded by `upgrade-timeout-seconds`**: `release_handler:check_install_release/1`, `release_handler:install_release/2`, then `release_handler:make_permanent/1`.
   A hang here (a process not acknowledging `code_change`, a deadlocked supervisor) is killed and reported as a timeout rather than silently eating the calling job's own multi-hour default timeout. The kill is forced, not just requested: `timeout(1)`'s default signal alone is not enough here, since the underlying process does not always die promptly on it while genuinely blocked, so a short grace period followed by `SIGKILL` keeps the actual wall-clock time close to what `upgrade-timeout-seconds` promises.
10. **Confirm the new version is actually the one left running**, via `release_handler:which_releases/0`, rather than trusting that the install calls alone imply success.
11. **Confirm the OS process never restarted**, by comparing the node's OS pid before and after.
    The entire point of a hot upgrade is that the running process survives it; `which_releases/0` alone can't tell a genuine in-place code swap from a disguised full restart (a stray `restart_new_emulator` instruction, or an init system quietly restarting a crashed node) that happens to land on the right version anyway.
12. **Stop the node** and report pass/fail.
13. **Write old-version, new-version, and the result to the job's Summary tab**, via `$GITHUB_STEP_SUMMARY` - the same convention `actions/cache` and other popular actions use so the outcome is visible at a glance without opening step logs, even when an earlier step failed first. `$GITHUB_STEP_SUMMARY` is scoped to the step that writes it, though: a later step in the calling workflow can't read this content back through that same env var, even within the same job - use the `had-warnings` output instead for that.
    A success with `fail-on-relup-warnings` left false but a warning raised anyway shows as its own distinct "⚠️ succeeded, with warnings" result, not an indistinguishable plain "✅" - otherwise the summary's whole point (visible at a glance) would fail silently for exactly the runs it matters most for.

## What this does not do (yet)

- **Version-bump convention enforcement.**
  Since `relup-guard-erlang` appends its own build-only suffix regardless of whether `app.src`'s vsn was bumped by hand, v1 has no opinion on whether a real version bump happened at all, or whether its size matched the change.
  That can be layered on top later as an optional check.
- **A pristine checkout afterward.**
  Because old-ref and new-ref are built sequentially in place, the repository ends up checked out at `new-ref`, with build artifacts from both versions in `_build`.
  See the note under Prerequisites about where to place this in your job.
- **Testing the downgrade path.**
  A relup file actually contains instructions both ways - `release_handler:install_release/2` can walk a running node forward *or* back - which looks like it should make "also test the rollback" a cheap addition, the same way database-migration tooling tests `down` as well as `up`.
  It isn't, for the specific pair of versions this action builds: `old-ref`'s release only exists on the test node because it was booted directly from its own boot script, never unpacked through `release_handler`, so `release_handler:which_releases/0` reports it with an empty app list, and any script instruction that needs that app list (`load_object_code`, in practice every non-trivial relup) fails deep inside `release_handler`'s own evaluator.
  Rolling back a release that *was* installed through `release_handler` (i.e. any version after the first one a node ever ran) does not hit this, because `unpack_release` is what populates that app list in the first place; testing that path for real would need a third, already-"managed" version to roll back to, which is a bigger addition than the two-version model this action builds on.
  This is called out here rather than offered as a flag because no flag would make it work for the versions this action actually has on hand - if you want confidence in your own rollback path, test it against two versions you have already deployed through `release_handler` at least once, not against a freshly booted node.

## Tested against

`fixtures/demo_app` is a minimal rebar3/relx release: one `gen_server` (`relup_worker`) with a `code_change/3` that migrates its state shape, plus a second module (`relup_worker2`) with no corresponding appup `apply` instruction, specifically to exercise the "unstarted module" check.
Unlike the Elixir fixture's equivalent, `relup_worker2` is not a supervisor child - necessary, not just stylistic: `rebar3_appup_plugin`'s own automatic "did a supervisor's children change" detection crashes outright on a plain `init/1` child-spec list, so a standalone module that nothing starts reaches the same "shipped but never running" gap without touching the supervisor at all.

`.github/workflows/ci.yml` runs `relup-guard-erlang` against itself on every push:

- The main self-test job, and two more exercising `new-ref`'s documented default and a deterministic `boot-timeout-seconds: "0"` failure, build from a dedicated `fixtures/baseline` branch (an earlier state of `fixtures/demo_app`, without `relup_worker2`) against the current commit.
- Two more jobs exercise the "unstarted module" check from that same pair, covering both directions of `fail-on-relup-warnings`: one confirms the default (`false`) still succeeds with `had-warnings: "true"`, the other confirms `true` turns that same warning into a failure.
- A negative test confirms identical `old-ref`/`new-ref` fails outright (no second version to relup between), and another confirms an `old-ref` that doesn't resolve to any commit fails with a clear reason rather than a raw git error.
- A final job exercises `upgrade-timeout-seconds` - the one failure mode no input value alone can force deterministically - using `relup_stuck_worker`, which casts itself into a `receive after infinity` on boot and so can never acknowledge the suspend request a real upgrade sends it. Unlike `relup_worker2`, this one *is* a supervised child, kept that way identically across both versions on the branch: necessary, since `release_handler` only attempts to suspend processes it can discover by walking the supervision tree, and keeping the supervisor's own module identical between old-ref and new-ref also avoids the same plugin crash `relup_worker2` avoids differently. That fixture lives on a dedicated `fixtures/stuck-worker` branch, not `main`: a hang landing on `main`, even transiently, risks hanging the whole self-test rather than just adding a warning the way `relup_worker2` does. `actions/checkout`'s own `fetch-depth: 0` fetches every branch and tag, not just the triggering ref's history, so this job can still resolve that branch's commits from a checkout of `main`.
- `shellcheck` runs against every script on every push.

Every job sets its own `timeout-minutes` (5 for the two that need no BEAM toolchain at all, 15 for the rest), rather than relying on GitHub's own 360-minute per-job default: `boot-timeout-seconds`/`upgrade-timeout-seconds` only bound the specific steps they wrap, not a hang somewhere outside them entirely, such as a toolchain download or a package registry outage.

## Releasing

```
make release VERSION=1.0.0
```

Tags the current commit `v1.0.0`, moves the floating `v1` tag to point at it too, and pushes both - the same convention `actions/checkout` and most of the GitHub Actions ecosystem use, so a consumer pinned to `@v1` picks up new `v1.x.y` releases automatically.

The same thing is also available as a manual GitHub Actions workflow (`.github/workflows/release.yml`), for releasing without a local checkout: open the **Actions** tab, select **Release**, click **Run workflow**, pick `main` as the branch, and enter the version. It runs the same `make release` target, so the two stay in sync by construction rather than needing to be kept consistent by hand.

## References

- [`relup-guard-elixir`](https://github.com/deployex/relup-guard-elixir) - the sibling project this one is modeled on, for Mix releases.
- [`ferd/dandelion`](https://github.com/ferd/dandelion) - reference implementation of this same idea for rebar3/relx, running an equivalent check on every pull request.
- [My Favorite Erlang Container](https://ferd.ca/my-favorite-erlang-container.html)
- [`Ahzed11/HotCI`](https://github.com/Ahzed11/HotCI) - a GitHub Actions template for rebar3/Erlang projects, building old and new releases and running a `common_test` suite against both an upgrade and a downgrade.
- [`rebar3_appup_plugin`](https://github.com/lrascao/rebar3_appup_plugin) - generates `.appup` files for a rebar3/relx release.

## License

MIT, see [LICENSE.md](LICENSE.md).
