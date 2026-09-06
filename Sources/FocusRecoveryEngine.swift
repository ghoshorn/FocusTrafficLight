import AppKit
import CoreGraphics
import Darwin

private typealias SpaceCopyCurrentFunc = @convention(c) (Int) -> Int
private typealias CopySpacesForWindowFunc = @convention(c) (Int, Int) -> Unmanaged<CFArray>?

/// Focus recovery for explicit user window actions.
///
/// A trigger (Cmd+W / Cmd+M / traffic light click / app hide) is followed by
/// a single 50ms check that the target window has left the screen, then the
/// topmost visible app window in the current Space is activated.
final class FocusRecoveryEngine {

    private let accessibilityHelper: AccessibilityHelper
    private var lastPermissionWarnAt: TimeInterval = 0

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
    }

    func performRecoveryCheck(context: FocusTriggerContext) {
        guard accessibilityHelper.checkAccessibilityPermission() else {
            warnPermissionMissingIfNeeded()
            return
        }

        AppLogger.info(
            "Focus check triggered by \(context.kind.rawValue) — source PID=\(context.sourcePID) window=\(context.targetWindowID.map(String.init) ?? "?")"
        )

        guard targetWindowIsGone(context) else {
            AppLogger.info("Target window is still visible, skipping recovery")
            return
        }

        if context.kind == .windowHidden,
           appHasVisibleWindows(processID: context.sourcePID) {
            AppLogger.info("App still has visible windows after hidden event, skipping recovery")
            return
        }

        guard let app = findTopmostVisibleWindowApp() else {
            AppLogger.info("No visible app window to focus")
            return
        }

        AppLogger.info("Focusing: \(app.localizedName ?? "?")")
        performFocus(app: app)
    }

    /// Without the Accessibility grant nothing works, but on recent macOS the
    /// process is only re-approved for the exact binary path — an update or a
    /// rebuilt bundle silently loses previous trust. Surface that instead of
    /// failing quietly.
    private func warnPermissionMissingIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - lastPermissionWarnAt >= 10 else { return }
        lastPermissionWarnAt = now
        AppLogger.info(
            "Accessibility permission missing — focus recovery disabled. " +
            "Grant it in System Settings > Privacy & Security > Accessibility and restart the app."
        )
    }

    // MARK: - Checking the Triggered Window Left the Screen

    private func targetWindowIsGone(_ context: FocusTriggerContext) -> Bool {
        guard let windowID = context.targetWindowID, windowID > 0 else { return true }
        return !isWindowOnScreen(windowID: windowID)
    }

    private func isWindowOnScreen(windowID: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == windowID }
    }

    private func appHasVisibleWindows(processID: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return list.contains {
            ($0[kCGWindowLayer as String] as? Int) == 0 &&
            ($0[kCGWindowOwnerPID as String] as? pid_t) == processID
        }
    }

    // MARK: - Topmost Visible Window Discovery

    private func findTopmostVisibleWindowApp() -> NSRunningApplication? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for cgWindow in windowList {
            guard let layer = cgWindow[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard windowIsInCurrentSpace(windowInfo: cgWindow) else { continue }
            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID else { continue }
            guard let app = NSRunningApplication(processIdentifier: ownerPID) else { continue }

            return app
        }

        return nil
    }

    // MARK: - Focus Transfer

    private func performFocus(app: NSRunningApplication) {
        // Direct activation is unreliable across recent macOS releases:
        // `.activateIgnoringOtherApps` is a deprecated no-op since macOS 14
        // and modern `activate` calls from an LSUIElement app are routinely
        // rejected by macOS 26. Ask the target app to activate itself, which
        // macOS honours.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        app.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let focusLanded = currentPID == app.processIdentifier ||
                (currentPID != frontmostPID && currentPID != ProcessInfo.processInfo.processIdentifier)
            if focusLanded { return }

            AppLogger.info("Activation did not land, retrying via AppleScript")
            var errorInfo: NSDictionary?
            let source = "tell application id \"\(app.processIdentifier)\" to activate"
            _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            if let errorInfo = errorInfo {
                AppLogger.info("AppleScript activation failed: \(errorInfo)")
            }
        }
    }

    // MARK: - Space / CGWindow Helpers

    /// Cross-space filtering relies on private CoreGraphics symbols that are
    /// removed on macOS 26; all guarded nil paths below fail open (the window
    /// is treated as being in the current space), so the guard silently
    /// degrades instead of breaking focus recovery.
    private func getCurrentSpaceID() -> Int? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/Current/CoreGraphics", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "CGSSpaceCopyCurrent"),
              let fn = unsafeBitCast(sym, to: Optional<SpaceCopyCurrentFunc>.self) else {
            return nil
        }

        let currentSpace = fn(2)
        if currentSpace != 0 {
            return currentSpace
        }
        return nil
    }

    private func windowIsInCurrentSpace(windowInfo: [String: Any]) -> Bool {
        guard let spaceID = getCurrentSpaceID() else {
            return true
        }

        guard let windowNumber = windowInfo[kCGWindowNumber as String] as? Int else {
            return false
        }

        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/Current/CoreGraphics", RTLD_NOW) else {
            return true
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "CGSCopySpacesForWindow"),
              let fn = unsafeBitCast(sym, to: Optional<CopySpacesForWindowFunc>.self) else {
            return true
        }

        guard let spacesRef = fn(2, windowNumber) else {
            return false
        }

        let spaces = spacesRef.takeRetainedValue() as! [Int]
        return spaces.contains(spaceID)
    }
}
