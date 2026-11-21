# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.1.1

### Fixed

- `run-upgrade.sh` now prints the tail of the daemon's own boot log, and the head of `erl_crash.dump` if present, before failing on a boot timeout, instead of only reporting a generic "did not boot within Ns" message.
  Both already capture the real reason in the common failure modes - an unresolved `vm.args` placeholder, an application crashing on a missing env var, a release built for the wrong ERTS version - so this surfaces it instead of leaving trial and error as the only way to find it.

### Changed

- README documents GitHub Actions workflow dependency lockfiles as a third pinning option alongside tag-pinning and SHA-pinning, noting this repository hasn't adopted one yet.

## 1.1.0

### Added

- `patch-version.sh` now appends a short, build-only suffix derived from each ref's own commit SHA to every OTP application's `vsn`, plus the relx release tuple's own vsn if it's a literal, before each build.
  A relup needs two distinct application versions to generate anything against - OTP's relup/appup mechanism is keyed on each app's own vsn, not on whether the underlying code actually changed - so a PR that changes code without also bumping `app.src` by hand now still gets a real relup generated and tested, instead of the hard failure this previously required.
  `old-ref` and `new-ref` resolving to the exact same commit is still treated as an error, since that genuinely has no second version to relup against.

## 1.0.0

### Added

- Composite action that builds a release at `old-ref` and `new-ref`, boots `old-ref` as a daemon, and runs a real hot code upgrade against it: unpack, synthesize the relup, `check_install_release`, `install_release`, `make_permanent`.
- Detection of relups that load a new module but never start it as a supervised process, via a diff against what the node had loaded before the upgrade.
- `fail-on-relup-warnings` input to treat `systools:make_relup/4` warnings, and the unstarted-module check above, as failures instead of only annotations.
- `boot-timeout-seconds` and `upgrade-timeout-seconds` inputs, so a hang fails fast with a clear reason instead of relying on the calling job's own timeout.
- Verification that the OS process never restarted during the upgrade, catching a disguised full restart that `which_releases/0` alone can't distinguish from a genuine hot swap.
- Job summary output (`$GITHUB_STEP_SUMMARY`) showing old/new refs, versions, and result, including a distinct "succeeded, with warnings" state.
- `working-directory`, `profile`, and `build-command` inputs for umbrella apps and non-default release setups.
- Self-test suite (`.github/workflows/ci.yml`) running the action against itself on every push, covering the happy path, both ref-resolution failure modes, both timeout failure modes, and both directions of `fail-on-relup-warnings`.
