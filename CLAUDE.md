# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A menu-bar-only macOS utility (bundle id `com.focustrafficlight.app`, `LSUIElement=1`, no Dock icon, no main window) that restores focus to the topmost visible window after the user closes, minimizes, or hides a window. Written in pure Swift/AppKit — no third-party dependencies, no test suite, no linter config. `SPEC.md` is the authoritative behavior spec (trigger rules, edge cases, version history); keep code changes aligned with it and update it when behavior changes.

## Commands

XcodeGen project. The canonical build path (xcodegen is not installed on every machine — check first):

```
xcodegen generate
xcodebuild -project FocusTrafficLight.xcodeproj -scheme FocusTrafficLight build
```

Verified fallback that builds without XcodeGen (fill the `$(...)` placeholders in `Resources/Info.plist` or supply your own — `LSUIElement` stays true):

```
swiftc -o FocusTrafficLight \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement \
  -target arm64-apple-macos13.0 \
  Sources/*.swift
```

Tools such as JS core or C compilers may be absent or restricted in the execution environment; test scripts in `/tmp` generally work, but anything needing to run an `.app` with correct activation behavior must be launched via `open` (see "Testing gotchas" below).

Version bumps: edit `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` in `project.yml` **and** the matching `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist` (both use `$(...)` placeholders at xcodegen build time but hardcoded strings otherwise), add a `CHANGELOG.md` entry, commit as `vX.Y.Z: summary`.

## Architecture

Event flow is one-way; understanding it end-to-end requires reading three files together:

```
FocusEventMonitor (triggers)          WindowManager                FocusRecoveryEngine
  ├─ NSEvent global keyDown            onStartMonitoring    ──►   performRecoveryCheck
  │   (Cmd+W=13, Cmd+M=46, Cmd+H=4)    wires callback              1. target window gone?
  ├─ CGEvent.tapCreate leftMouse —►    FocusEventMonitor     ──►   2. (hidden kind) no visible
  │   hits AXCloseButton/AXMinimize    .onFocusCheckNeeded         windows from source app?
  │   via AXUIElementCopyElementAtPos  = FocusRecoveryEngine       3. pick topmost layer-0
  └─ per-app AXObserver (created for   .performRecoveryCheck       window in current space
      every regular app via                                        not owned by us
      NSWorkspace launch/terminate)                                4. activate that app
      destroyed/miniaturized/hidden
```

- Triggers debounce 0.2s, then the recovery check fires exactly once after a 50ms settle delay — deliberately no polling loop (see SPEC §3 and v4.0.2 in CHANGELOG). If the window is still on screen at check time, the trigger is dropped.
- Every trigger path records the target `CGWindowID` up front (key event window, AX focused window, or AX parent walk, max 4 levels); recovery compares it against `CGWindowListCopyWindowInfo` at check time to verify the window actually left the screen.
- Selection is intentionally heuristic-free: first `kCGWindowLayer == 0` window in the current Space not owned by this process. This was a fix (v4.0.1) for apps like v2rayN whose `activationPolicy` is `.accessory` but which own real windows — do not re-add size/policy filters.
- `FocusTriggerContext.Kind` names match trigger paths; `.windowHidden` is the one kind that re-checks whether the source app still has visible on-screen windows before recovering.
- `FocusEventMonitor` retains itself via `Unmanaged.passRetained` for AXObserver callbacks and `Unmanaged.passUnretained(self).toOpaque()` for the CG event tap's `userInfo` — both callbacks unwrap the pointer; keep the lifetime invariants intact when touching observer setup/teardown.
- Deliberate suppressors, each a regression fix — do not remove without a replacement:
  - `Cmd+H` (keyCode 4) cancels AX hidden-notification handling for 0.5s (system already transfers focus), `handleAXNotification`.
  - Finder AX events are skipped while Finder is frontmost (desktop Quick Look emits spurious destroy/miniaturize, v4.0.3).
  - AX destroyed/miniaturized require `pid == frontmost`; app-hidden requires `app.isHidden` actually true plus no remaining visible windows (v4.0.4 — transient menus were stealing focus).

## macOS version compatibility — known broken bits

The README says only macOS 15 is tested; the following uses private/deprecated APIs whose behavior differs per OS and degrade on macOS 26:

- `FocusRecoveryEngine.performFocus` wraps cross-app focus activation in a fallback chain: modern `activate()` first, then (after a 150ms verification that focus actually landed) `NSAppleScript` asking the target to activate itself via `tell application id "<pid>" to activate`. Background: `.activateIgnoringOtherApps` was deprecated in macOS 14 ("will have no effect") and modern `activate` calls from an LSUIElement process are routinely rejected by macOS 26; script-based self-activation is the only path that reliably transfers focus there. Any change to this chain MUST be verified on a real installed build on the target macOS version, not assumed.
- A lightweight 150ms poller detects "silent hides": apps like WeChat (F1 show/hide toggle) or QQ-style hotkeys that merely `orderOut:` all their windows without hiding the app — macOS publishes no AX notification for this (no public constant to observe), so the app watches the frontmost app's visible-window count (`kCGWindowLayer == 0` + `kCGWindowIsOnscreen`). N→0 gives focus back to the next visible app. Guards: 0.2s debounce (shared with all triggers), 0.8s silent-hide-only cooldown (to prevent panel/status-item flicker re-firing), the Cmd+H window (system has already transferred focus), skips the app itself plus Finder/locked screen. Don't "optimize" this poll back in — no event driver exists for that family of hide toggles.

## Testing gotchas (discovered 2026-09 session)

- Accessibility permission is effective-trust, not just the TCC record: ad-hoc-signed entries pin the cdhash, so any re-sign/rebuild leaves the process `AXIsProcessTrusted()=false` even while Settings shows the toggle on. Symptom in logs: "Mouse tap setup: AX trusted=false". Cure: `tccutil reset Accessibility com.focustrafficlight.app`, relaunch the app (re-triggers a clean grant), then restart it once more — the grant lands while the app is running and `AXIsProcessTrusted` does not go hot inside an already-running process.
- Running the compiled binary directly (`./FocusTrafficLight`) instead of `open`-ing it gives the process the wrong `activationPolicy` (prohibited, `-1`), which breaks `NSRunningApplication.current` and makes `activate` calls from tests meaningless — always test activation behavior with `open` on a properly signed bundle, and read results from disk (e.g. a report file) rather than stdout.
- `CGWindowListCopyWindowInfo` ordering: the app relies on z-order; when reproducing selection issues, dump layer/pid/owner/title rather than assuming WindowServer order is stable across OS versions.
- The app logs to the unified log with subsystem `com.focustrafficlight.app`; use `log show --predicate 'subsystem == "com.focustrafficlight.app"'` or `log stream` with the same predicate. `AppLogger.debug` is stripped in release builds; operational logs go through `AppLogger.info`.

## Conventions

- All logs are structured through `AppLogger` (`os_log`, subsystem `com.focustrafficlight.app`); never `print()`.
- Public API churn is aggressive here: prefer checking SDK availability on the version you're validating against (`nm -gU`, `dlsym` via a probe binary) before adopting a private symbol.
- Localization: `README.md` (en) and `README_zh.md` (zh) are kept in sync for user-facing behavior changes.
