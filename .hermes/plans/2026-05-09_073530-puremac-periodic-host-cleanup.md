# PureMac Periodic Host Cleanup Plan

## Goal

Take over `/Users/mike/Projects/KovaForge/PureMac` and make it reliably achieve one operational success criterion:

> The host Mac should maintain at least **10% free disk space** through periodic, safe cleanup of temporary/build artifacts, especially Visual Studio / .NET / IDE `bin` and `obj` directories.

This should be handled through PureMac itself where possible, with repo maintenance if the current app/CLI cannot meet the objective.

## Strategic framing

PureMac currently looks like a GUI-first macOS cleaner with some scheduler support. The request is operationally different: it needs a **headless, repeatable, measurable cleanup loop** with a hard free-space floor. The leverage point is not another one-off deletion; it is turning PureMac into a small host-maintenance subsystem:

1. Measure disk pressure.
2. Estimate safe reclaimable space.
3. Clean low-risk caches/build outputs first.
4. Escalate only when the 10% target is still missed.
5. Prove every run with logs and before/after free-space metrics.

The durable architecture should therefore be CLI + launchd + conservative cleanup rules + audit logs, with the GUI as a companion rather than the only execution path.

## Current context confirmed by read-only inspection

Repository:

- Path: `/Users/mike/Projects/KovaForge/PureMac`
- Branch: `main`
- Remote: `origin https://github.com/KovaForge/PureMac.git`
- Upstream: `https://github.com/momenbasel/PureMac.git`
- Working tree: clean at inspection time.

Deployment / CLI status:

- No `puremac`, `PureMac`, `pure-mac`, or `pmac` executable was found in `PATH`.
- `/Applications/PureMac.app` was not present.
- `/Users/mike/Applications/PureMac.app` was not present in the inspected environment.
- `~/Library/LaunchAgents/com.puremac.scheduler.plist` was not present.
- `brew list --cask puremac` reported not installed.
- Conclusion: **PureMac is not currently deployed as a usable host cleanup CLI or scheduled app on this machine.**

Build/tooling status:

- `xcodegen` available: `2.44.1`
- `xcodebuild` available: Xcode `26.4.1`
- `swift` available: Swift `6.3.1`

Disk state:

- `/Users/mike` filesystem total: `499,931,717,632` bytes.
- Free: `1,309,700,096` bytes.
- Free percentage: `0.26%`.
- 10% target: about `49,993,171,763` bytes.
- Additional free space needed now: about `48,683,471,667` bytes / `45.34 GiB`.
- This host is currently far below the requested success threshold.

Initial reclaim candidates from read-only sizing:

- `/Users/mike/Projects`: `79G` total, likely contains major project/build outputs.
- `/Users/mike/.nuget/packages`: `13G`.
- `/Users/mike/Library/Caches`: `8.6G`.
- `/Users/mike/.cache`: `6.0G`.
- `/Users/mike/Library/Developer/Xcode/DerivedData`: `840M`.
- `/Users/mike/Library/Caches/com.apple.dt.Xcode`: `728K`.
- `/Users/mike/Library/Developer/CoreSimulator/Caches`: `0B`.

Current PureMac capability gaps relative to the goal:

- It has a GUI app target only (`project.yml` defines `PureMac` application target).
- Scheduler writes a LaunchAgent that runs the app executable with `--scheduled-clean`, but `PureMacApp.swift` does not currently parse CLI arguments.
- Existing scheduled cleaning is stateful inside `AppViewModel`, not a standalone headless command.
- Existing scan categories include Xcode junk, Homebrew cache, system/user caches, trash, etc.
- It does **not** currently include Visual Studio / Rider / .NET solution build cleanup for recursive `bin` and `obj` directories.
- It does not currently enforce a minimum-free-space target such as 10%.
- Existing scan code uses `FileManager.default.homeDirectoryForCurrentUser`, which in agent contexts may resolve to the Hermes profile home rather than `/Users/mike`; the CLI must support an explicit `--home /Users/mike` or equivalent.

## Proposed approach

### Principle 1: Make cleanup target-driven, not interval-driven

The periodic run should not blindly delete every hour. It should:

1. Check free-space percentage.
2. Exit quietly if free space is already >= 10% plus a buffer.
3. If below threshold, clean safe categories in priority order until target is reached or all safe candidates are exhausted.
4. Report `success` only when free space is >= 10% after cleanup.

Recommended defaults:

- `--min-free-percent 10`
- `--buffer-percent 1` if practical, so the system does not oscillate at exactly 10%.
- `--dry-run` as the default for new rule validation.
- `--execute` required for actual deletion.

### Principle 2: Separate safe automatic cleanup from review-required cleanup

Automatically safe categories:

- IDE build outputs: recursive `bin/`, `obj/`, `.vs/`, `TestResults/`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `.gradle` build caches where scoped safely.
- Xcode DerivedData and simulator caches.
- User caches: `~/Library/Caches`, `~/.cache`, npm/yarn/pnpm/pip caches.
- Homebrew download cache.
- Trash, if explicitly enabled.
- Time Machine local snapshot thinning, if supported and non-destructive.

Review-required categories:

- Large files in Documents/Desktop/Downloads.
- Whole repositories under `/Users/mike/Projects`.
- NuGet package cache deletion if it could impact offline builds; can be enabled but should be clearly logged.
- Anything outside configured roots.

### Principle 3: Keep proof trails

Every scheduled run should write structured logs, e.g.:

- `~/Library/Logs/PureMac/cleanup-runs/YYYY-MM-DDTHHMMSS.json`
- `~/Library/Logs/PureMac/cleanup-runs/latest.json`

Each run record should include:

- timestamp
- PureMac version/commit if built from source
- configured threshold
- filesystem total/free before
- categories scanned
- candidate count and bytes by category
- paths deleted
- bytes reclaimed estimate
- filesystem free after
- final status: `success`, `partial`, `no_action_needed`, or `failed`
- errors and skipped paths

## Implementation plan

### Phase 0 — Safety guardrails before deletion

1. Add a shared cleanup policy model:
   - explicit allowed roots, defaulting to `/Users/mike`, `/Users/mike/Projects`, and standard cache folders.
   - denied roots: `/System`, `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/Library` except specific cache/log paths, mounted backup volumes, cloud-storage roots unless explicitly allowed.
   - symlink handling: never follow symlinks for deletion unless explicitly allowed.
   - age filters for build outputs, defaulting to delete only directories not modified in the last N hours unless `--aggressive` is passed.
2. Add dry-run mode and make it easy to compare dry-run vs execute output.
3. Add path normalization and root containment checks before every remove operation.

Likely files:

- `PureMac/Models/Models.swift` or new `PureMac/Models/CleanupPolicy.swift`
- `PureMac/Services/CleaningEngine.swift`
- `PureMac/Services/ScanEngine.swift`
- new tests if a test target is added.

### Phase 1 — Create a real headless CLI path

Preferred architecture: add a Swift command-line executable target sharing the scan/cleaning services. Per McoreD follow-up, this should be treated as a **first-party CLI for OpenClaw and Hermes**: provide a small JSON manifest describing executable name, commands, args, output mode, safety flags, and success criteria. Do not overbuild plugin support yet; the manifest is discovery/contract metadata, not a plugin runtime.

Possible target name:

- `puremaccli`

Subcommands:

```bash
puremaccli status --home /Users/mike --min-free-percent 10
puremaccli scan --home /Users/mike --json
puremaccli clean --home /Users/mike --min-free-percent 10 --dry-run --json
puremaccli clean --home /Users/mike --min-free-percent 10 --execute --json
puremaccli install-agent --home /Users/mike --interval-minutes 60 --min-free-percent 10
puremaccli uninstall-agent
```

Key requirements:

- Does not require the GUI to be open.
- Does not depend on `FileManager.homeDirectoryForCurrentUser` alone; supports explicit `--home`.
- Returns meaningful exit codes:
  - `0`: already healthy or cleanup achieved target.
  - `1`: cleanup ran but still below threshold.
  - `2`: configuration/permission error.
  - `3`: unsafe candidate/path rejected.
- Emits JSON for scheduler logs and machine verification.

Likely files:

- `project.yml` — add CLI target.
- new `PureMacCLI/main.swift` or `Sources/PureMacCLI/main.swift`.
- refactor shared services into a reusable module if necessary.
- `README.md` — document CLI and periodic setup.

### Phase 2 — Add Visual Studio / .NET / IDE build-output scanning

Add a dedicated category, probably `ideBuildArtifacts` or `Developer Build Artifacts`.

Scan rules:

- Search configured roots, especially `/Users/mike/Projects`.
- Detect and clean directories named exactly:
  - `bin`
  - `obj`
  - `.vs`
  - `TestResults`
  - `.idea/.?` only cache subpaths if safe; avoid deleting JetBrains project config indiscriminately.
  - `.gradle/caches` or `build/` only with conservative language-specific rules.
- Prioritize `.csproj`, `.sln`, `Directory.Build.props`, `packages.config`, `global.json`, `*.fsproj`, `*.vbproj` parent contexts for `bin`/`obj` cleanup.
- Avoid deleting arbitrary directories named `bin` under tool installations or user-managed package folders.
- Skip directories modified within the last 2-6 hours by default to avoid disrupting active builds.

This is probably the most important repo update because the user explicitly called out Visual Studio and other IDEs.

Likely files:

- `PureMac/Models/Models.swift` — new category and labels.
- `PureMac/Services/ScanEngine.swift` — new scanner.
- `PureMac/Services/CleaningEngine.swift` — policy-aware deletion.
- `PureMac/Views/*` — GUI category support if the app remains feature-complete.
- localization files under `PureMac/en.lproj` and `PureMac/zh-Hans.lproj` if category names/descriptions are localized.

### Phase 3 — Implement target-aware cleanup ordering

Add an orchestration service, e.g. `MaintenanceEngine`, that runs the cleanup sequence:

1. Load disk info.
2. If free >= 10%, exit `no_action_needed`.
3. Scan low-risk categories.
4. Sort candidates by risk tier and reclaim size.
5. Delete until the 10% target is reached.
6. Re-check disk free after each category or batch.
7. If still under target, run optional/aggressive categories if enabled.
8. If still under target, emit a report listing review-required candidates, not silently deleting personal/project data.

Recommended default cleanup order:

1. IDE build artifacts under `/Users/mike/Projects` (`bin`, `obj`, DerivedData, caches).
2. Language/package caches: NuGet, npm, pnpm, yarn, pip, Gradle/Maven, SwiftPM/Xcode caches.
3. App/user caches.
4. Homebrew cache.
5. Trash if explicitly enabled.
6. Time Machine purgeable/snapshot thinning if available.
7. Large-files report only.

### Phase 4 — Install a LaunchAgent-backed periodic run

Once the CLI works and has passed dry-run validation, install a user LaunchAgent such as:

- `~/Library/LaunchAgents/com.kovaforge.puremac.cleanup.plist`

Suggested behavior:

- Run every 60 minutes while disk pressure is this high, or every 3-6 hours after stable.
- Use `StartInterval` plus `RunAtLoad`.
- Invoke the CLI, not the GUI app.
- Write stdout/stderr to `~/Library/Logs/PureMac/launchd-cleanup.out.log` and `.err.log`.
- Include explicit arguments:

```bash
puremaccli clean \
  --home /Users/mike \
  --root /Users/mike/Projects \
  --min-free-percent 10 \
  --execute \
  --json \
  --log-dir /Users/mike/Library/Logs/PureMac/cleanup-runs
```

Important: do not install this until dry-run output is reviewed or the candidate set is proven safe.

### Phase 5 — Immediate host recovery strategy

Because the current free space is only `0.26%`, PureMac may not have enough space to build until some space is freed. The initial operational path should be:

1. Run dry-run scanning first, no deletion.
2. Identify the largest safe reclaim candidates under `/Users/mike/Projects`, `/Users/mike/.nuget/packages`, `/Users/mike/Library/Caches`, and `/Users/mike/.cache`.
3. If build space is insufficient, perform a very narrow manual cleanup only after candidate confirmation:
   - project `bin`/`obj` directories older than a short threshold,
   - NuGet/http/package caches if acceptable,
   - Xcode DerivedData.
4. Build the CLI.
5. Replace manual cleanup with PureMac-managed periodic cleanup.

Given the measured state, the known cache candidates total about `28G` excluding project build outputs. To hit 10%, additional reclaim is likely needed from `/Users/mike/Projects` or other large user files. The CLI should therefore produce a review report if safe automatic cleanup cannot reach the target.

### Phase 6 — Verification gates

Before enabling scheduled deletion:

1. `xcodegen generate`
2. `xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Debug build`
3. Build CLI target.
4. Run unit tests if added.
5. Run CLI dry-run:

```bash
puremaccli clean --home /Users/mike --root /Users/mike/Projects --min-free-percent 10 --dry-run --json
```

6. Review dry-run JSON for:
   - no denied roots,
   - no symlink-following deletion,
   - no arbitrary user documents,
   - expected `bin`/`obj` targeting.
7. Run execute mode on a limited root first.
8. Verify with:

```bash
df -h /Users/mike
puremaccli status --home /Users/mike --min-free-percent 10 --json
launchctl print gui/$(id -u)/com.kovaforge.puremac.cleanup
```

Success is not “cleanup ran”; success is:

- `df` shows free space >= 10%, or
- the CLI logs `partial` with a clear list of remaining review-required candidates when automatic cleanup is insufficient.

## Risks and tradeoffs

- **Risk: deleting active build outputs while an IDE/build is running.** Mitigation: age threshold, process checks for Xcode/dotnet/Visual Studio/Rider, and conservative defaults.
- **Risk: arbitrary `bin` folders are not always disposable.** Mitigation: only delete `bin`/`obj` when parent context proves a .NET/project build tree or when under explicitly allowed project roots.
- **Risk: current disk pressure may block builds.** Mitigation: start with read-only/dry-run and narrow manual reclaim if needed.
- **Risk: Full Disk Access/TCC limits visibility.** Mitigation: CLI should report inaccessible paths and scheduler should not silently mark success.
- **Risk: GUI scheduler currently appears misleading.** It can install `--scheduled-clean`, but the app currently does not parse that argument. The plan should fix this either by CLI target or explicit argument handling.

## Open decisions for McoreD

These affect deletion scope and should be decided before execute-mode scheduling:

1. Should NuGet cache (`/Users/mike/.nuget/packages`, currently ~`13G`) be considered automatically disposable?
2. Should Trash be emptied automatically, or only reported?
3. Should cleanup be allowed across all `/Users/mike/Projects`, or only KovaForge/OpenClaw/BriarForge project roots?
4. Should the periodic cadence be aggressive short-term, e.g. hourly until free >= 10%, then daily/6-hourly?

## Recommended first execution batch after plan approval

1. Implement `puremaccli` CLI with dry-run-only mode first.
2. Add developer build artifact scanner for `.NET/Visual Studio` `bin` and `obj` under `/Users/mike/Projects`.
3. Add disk-threshold orchestration and JSON proof logs.
4. Build and run dry-run.
5. Share candidate cleanup report.
6. After approval, run limited execute mode and verify `df`.
7. Install LaunchAgent only after the first execute run proves safe.

## Terminal condition

This workstream is complete when:

- PureMac provides a headless CLI or equivalent that can be scheduled without GUI interaction.
- Periodic cleanup is installed and verifiably running.
- Cleanup rules include Visual Studio/.NET/IDE `bin` and `obj` artifacts safely.
- Every run logs before/after disk state.
- Host free space is maintained at >= 10%, or the system reports that only review-required user/project data remains and automatic cleanup cannot safely reach the target.
