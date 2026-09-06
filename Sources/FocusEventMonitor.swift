import AppKit
import ApplicationServices
import CoreGraphics

/// A single user-initiated window close/minimize action.
struct FocusTriggerContext {
    enum Kind: String {
        case closeWindow = "Cmd+W"
        case minimizeWindow = "Cmd+M"
        case closeButton = "Close Button"
        case minimizeButton = "Minimize Button"
        case windowHidden = "Window Hidden"
    }

    let kind: Kind
    let sourcePID: pid_t
    let targetWindowID: Int?
}

/// V4 event source: keyboard shortcuts, traffic light clicks, and app-hide
/// notifications from apps with their own hide shortcuts (WeChat, QQ, Feishu...).
///
/// Explicit user actions can schedule focus recovery:
///   - Cmd+W closes a window
///   - Cmd+M minimizes a window
///   - a real mouse click on the red close / yellow minimize button
///   - a frontmost app hides itself or removes all of its traffic-light
///     windows through an app-specific shortcut
final class FocusEventMonitor {

    private struct TrafficLightHit {
        let kind: FocusTriggerContext.Kind
        let pid: pid_t
        let windowID: Int?
    }

    private var globalEventMonitor: Any?
    private var mouseEventTap: CFMachPort?
    private var mouseTapRunLoop: CFRunLoop?
    private var mouseTapContext: UnsafeMutableRawPointer?
    private var mouseTapThread: Thread?
    private var isMonitoring = false

    // Background poller for "silent hide": some apps (WeChat's F1 toggle, QQ,
    // custom close-panel shortcuts) OrderOut their windows without posting any
    // AX notification — there is no AX event we can listen for. Poll
    // CGWindowList to notice that the frontmost app has suddenly lost all of
    // its visible windows and recover focus.
    private var hidePollTimer: Timer?
    private var lastFrontVisibleWindowCount: [pid_t: Int] = [:]
    private var lastHiddenRecoveryAt: TimeInterval = 0

    private var observers: [pid_t: (observer: AXObserver, runLoopSource: CFRunLoopSource, retainedSelf: UnsafeMutableRawPointer)] = [:]
    private var lastCmdHAt: TimeInterval = 0

    private let settleDelay: TimeInterval = 0.05
    private let debounceInterval: TimeInterval = 0.2
    private var lastTriggerAt: TimeInterval = 0

    /// Called shortly after the user closes/minimizes a window.
    var onFocusCheckNeeded: ((FocusTriggerContext) -> Void)?

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
        }

        startMouseEventTap()
        observeRunningApplications()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        startHidePolling()

        AppLogger.info("Focus event sources started (Cmd+W / Cmd+M / traffic lights / app hide / silent hide)")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopHidePolling()
        removeAllObservers()
        stopMouseEventTap()

        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    // MARK: - Keyboard Events

    private func handleKeyDown(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command), !event.isARepeat else { return }

        if event.keyCode == 4 {
            lastCmdHAt = Date().timeIntervalSince1970
        }

        let kind: FocusTriggerContext.Kind
        switch event.keyCode {
        case 13: kind = .closeWindow
        case 46: kind = .minimizeWindow
        default: return
        }

        guard canTriggerNow() else { return }

        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let windowID = event.windowNumber != 0 ? event.windowNumber : frontmostWindowID()

        schedule(
            FocusTriggerContext(
                kind: kind,
                sourcePID: pid,
                targetWindowID: windowID
            )
        )
    }

    // MARK: - Mouse Events (Traffic Light Clicks)

    private func startMouseEventTap() {
        guard mouseEventTap == nil else { return }

        AppLogger.info(
            "Mouse tap setup: AX trusted=\(AXIsProcessTrusted()) tapExists=\(mouseEventTap != nil)"
        )

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .leftMouseDown,
                  let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<FocusEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleMouseDown(at: event.location)
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
            callback: callback,
            userInfo: selfPtr
        ) else {
            AppLogger.info("Traffic light mouse tap unavailable (Accessibility or Input Monitoring permission needed)")
            return
        }
        AppLogger.info("Traffic light mouse tap created")

        let tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mouseEventTap = tap
        mouseTapContext = selfPtr

        mouseTapThread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.mouseTapRunLoop = runLoop
            CFRunLoopAddSource(runLoop, tapSource, .defaultMode)
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, tapSource, .defaultMode)
            self?.mouseTapRunLoop = nil
        }
        mouseTapThread?.name = "FocusTrafficLight.MouseTap"
        mouseTapThread?.start()
        AppLogger.info("Traffic light mouse tap thread starting")
    }

    private func stopMouseEventTap() {
        if let tap = mouseEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            mouseEventTap = nil
        }
        if let runLoop = mouseTapRunLoop {
            CFRunLoopStop(runLoop)
        }
        if let context = mouseTapContext {
            _ = Unmanaged<FocusEventMonitor>.fromOpaque(context)
            mouseTapContext = nil
        }
    }

    private func handleMouseDown(at point: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            self?.handleMouseDownOnMain(at: point)
        }
    }

    private func handleMouseDownOnMain(at point: CGPoint) {
        guard let hit = trafficLightHit(at: point) else {
            AppLogger.info("Mouse down at \(Int(point.x)),\(Int(point.y)) did not hit a traffic light")
            return
        }
        guard canTriggerNow() else { return }

        AppLogger.info(
            "Traffic light clicked: \(hit.kind.rawValue) PID=\(hit.pid) (\(NSRunningApplication(processIdentifier: hit.pid)?.localizedName ?? "?"))"
        )

        schedule(
            FocusTriggerContext(
                kind: hit.kind,
                sourcePID: hit.pid,
                targetWindowID: hit.windowID
            )
        )
    }

    /// Returns the close/minimize button under the click point, if any.
    ///
    /// AX exposes traffic lights as `AXCloseButton` / `AXMinimizeButton`
    /// children of the window. Some apps wrap them one level deep, so walk up
    /// a few parents before giving up. This never falls back to generic
    /// `AXButton` hits, keeping clicks inside web content and custom UI inert.
    private func trafficLightHit(at point: CGPoint) -> TrafficLightHit? {
        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hitElement = hit else {
            return nil
        }

        var element = hitElement
        for _ in 0..<4 {
            if let kind = trafficLightKind(of: element) {
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success,
                      pid != 0,
                      pid != ProcessInfo.processInfo.processIdentifier else {
                    return nil
                }
                return TrafficLightHit(
                    kind: kind,
                    pid: pid,
                    windowID: windowID(of: element)
                )
            }

            guard let parent = parent(of: element) else { break }
            element = parent
        }

        return nil
    }

    private func trafficLightKind(of element: AXUIElement) -> FocusTriggerContext.Kind? {
        let subrole = attribute(of: element, key: kAXSubroleAttribute as CFString) as? String
        let role = attribute(of: element, key: kAXRoleAttribute as CFString) as? String

        if subrole == kAXCloseButtonSubrole as String || role == kAXCloseButtonAttribute as String {
            return .closeButton
        }
        if subrole == kAXMinimizeButtonSubrole as String || role == kAXMinimizeButtonAttribute as String {
            return .minimizeButton
        }
        return nil
    }

    private func frontmostWindowID() -> Int? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value as! AXUIElement? else {
            return nil
        }
        return windowID(of: window)
    }

    private func windowID(of element: AXUIElement) -> Int? {
        var current = element
        for _ in 0..<4 {
            if (attribute(of: current, key: kAXRoleAttribute as CFString) as? String) == kAXWindowRole as String {
                return attribute(of: current, key: "AXCGWindowID" as CFString) as? Int
            }
            guard let parent = parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    private func canTriggerNow() -> Bool {
        let now = Date().timeIntervalSince1970
        guard now - lastTriggerAt >= debounceInterval else { return false }
        lastTriggerAt = now
        return true
    }

    private func schedule(_ context: FocusTriggerContext) {
        AppLogger.info(
            "Focus trigger queued: \(context.kind.rawValue) PID=\(context.sourcePID) window=\(context.targetWindowID.map(String.init) ?? "?")"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            self?.onFocusCheckNeeded?(context)
        }
    }

    // MARK: - App Hide Notifications (WeChat / QQ / Feishu style shortcuts)

    private func observeRunningApplications() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observeApp(app)
        }
    }

    @objc private func applicationDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else {
            return
        }
        observeApp(app)
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        removeObserver(for: app.processIdentifier)
    }

    // MARK: - Silent Hide Detection (WeChat / QQ custom hide shortcuts)

    /// Some apps (WeChat's F1 show/hide toggle, QQ quick-hide, similar
    /// app-specific shortcuts) just `orderOut:` their windows. The app is
    /// neither `.hidden` nor minimized — its visible windows are only gone —
    /// and no AX notification is posted for that, so macOS never moves focus
    /// and the frontmost slot stays dead until the user clicks something.
    /// Poll CGWindowList to catch the visible-window-count being yanked to
    /// zero and synthesize a "Window Hidden" trigger.
    private func startHidePolling() {
        guard hidePollTimer == nil else { return }
        hidePollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.pollFrontVisibleWindows()
        }
        // Timers need not be exact; tolerate slack so the system can coalesce
        // us with other timers and save energy.
        hidePollTimer?.tolerance = 0.06
    }

    private func stopHidePolling() {
        hidePollTimer?.invalidate()
        hidePollTimer = nil
        lastFrontVisibleWindowCount.removeAll()
    }

    private func deviceLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    private func pollFrontVisibleWindows() {
        guard !deviceLocked() else {
            lastFrontVisibleWindowCount.removeAll()
            return
        }

        guard let front = NSWorkspace.shared.frontmostApplication,
              front.activationPolicy == .regular,
              !front.isHidden,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              front.bundleIdentifier != "com.apple.finder" else {
            lastFrontVisibleWindowCount.removeAll()
            return
        }

        let pid = front.processIdentifier
        let count = visibleWindowCount(processID: pid)
        let prev = lastFrontVisibleWindowCount[pid] ?? count
        lastFrontVisibleWindowCount[pid] = count

        // Only the 1->0 (or N->0 if the app only had one window) drop at the
        // right moment is a silent hide; we are not interested in anything
        // going back up (that is not a hide) and we do not want to re-fire.
        guard prev > 0, count == 0 else { return }

        let now = Date().timeIntervalSince1970
        // Do not double-combat macOS's own Cmd+H transfer.
        if now - lastCmdHAt < 0.5 { return }
        // Status-item windows, panels without models, etc. can flap a
        // transient 1->0; throttle any repeated "silent hide" recoveries.
        if now - lastHiddenRecoveryAt < 0.8 { return }
        // If a keyboard/mouse/AX trigger just fired, that path already covers
        // this transition — do not stack a second recovery on top. Check this
        // last: canTriggerNow() consumes a debounce slot as a side effect.
        if !canTriggerNow() { return }

        lastHiddenRecoveryAt = now
        AppLogger.info(
            "Silent-hide detected: \(front.localizedName ?? "?") PID=\(pid) windows \(prev)->0"
        )
        schedule(
            FocusTriggerContext(
                kind: .windowHidden,
                sourcePID: pid,
                targetWindowID: nil
            )
        )
    }

    private func visibleWindowCount(processID: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return -1
        }
        var count = 0
        for cgWindow in list {
            guard (cgWindow[kCGWindowLayer as String] as? Int) == 0,
                  (cgWindow[kCGWindowOwnerPID as String] as? pid_t) == processID else {
                continue
            }
            count += 1
        }
        return count
    }

    // MARK: - Per-app AX Observers

    private func observeApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<FocusEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleAXNotification(element: element, name: notification as String)
        }

        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer = observer else {
            return
        }

        let retainedSelf = Unmanaged.passRetained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        let notifications: [CFString] = [
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXApplicationHiddenNotification as CFString
        ]

        var registered = 0
        for name in notifications {
            if AXObserverAddNotification(observer, appElement, name, retainedSelf) == .success {
                registered += 1
            }
        }
        guard registered > 0 else {
            _ = Unmanaged<FocusEventMonitor>.fromOpaque(retainedSelf)
            return
        }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        observers[pid] = (observer, runLoopSource, retainedSelf)
    }

    private func removeObserver(for pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), entry.runLoopSource, .defaultMode)
        _ = Unmanaged<FocusEventMonitor>.fromOpaque(entry.retainedSelf)
    }

    private func removeAllObservers() {
        for (pid, _) in observers {
            removeObserver(for: pid)
        }
        observers.removeAll()
    }

    private func handleAXNotification(element: AXUIElement, name: String) {
        guard name == kAXUIElementDestroyedNotification as String ||
              name == kAXWindowMiniaturizedNotification as String ||
              name == kAXApplicationHiddenNotification as String else {
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != 0,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let now = Date().timeIntervalSince1970
        if now - lastCmdHAt < 0.5 {
            // Cmd+H is already handled by macOS; the app-hide notification it
            // produces would only race the system's own focus transfer.
            return
        }

        if name == kAXApplicationHiddenNotification as String {
            guard let hiddenApp = NSRunningApplication(processIdentifier: pid),
                  hiddenApp.isHidden else {
                AppLogger.info(
                    "Skip AX \(name) — PID=\(pid) is not actually hidden"
                )
                return
            }
        }

        if name != kAXApplicationHiddenNotification as String {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            guard pid == frontmostPID else {
                AppLogger.info(
                    "Skip AX \(name) — PID=\(pid) not frontmost (\(frontmostPID))"
                )
                return
            }

            // Desktop Quick Look emits window destroy/minimize events from
            // Finder before the preview panel appears; they are not real
            // close/minimize actions.
            if let app = NSRunningApplication(processIdentifier: pid),
               app.bundleIdentifier == "com.apple.finder" {
                AppLogger.info("Skip Finder AX \(name) — Quick Look suppression")
                return
            }
        }

        AppLogger.info(
            "AX hide event: \(name) PID=\(pid) (\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"))"
        )

        let context = FocusTriggerContext(
            kind: .windowHidden,
            sourcePID: pid,
            targetWindowID: windowID(of: element)
        )
        schedule(context)
    }

    private func attribute(of element: AXUIElement, key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
            return nil
        }
        return value
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let parent = value else {
            return nil
        }
        return parent as! AXUIElement? ?? nil
    }
}
