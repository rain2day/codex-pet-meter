import Cocoa
import ApplicationServices

// MARK: - AX-based pet tracker
//
// Subscribes to Codex's pet window via AXObserver/kAXMovedNotification so the
// halo follows the pet in real-time without polling. Falls back silently if the
// user denies Accessibility permission — HaloView's animation timer will then
// poll CGWindowList instead.
final class CodexPetTracker {
    static let shared = CodexPetTracker()

    var onUpdate: ((NSRect) -> Void)?
    var isConnected: Bool { observedWindow != nil }

    private var observer: AXObserver?
    private var observedWindow: AXUIElement?
    private var observedAppPID: pid_t = 0
    private var hasPermission = false
    private var recheckTimer: Timer?

    func start(onUpdate: @escaping (NSRect) -> Void) {
        self.onUpdate = onUpdate
        ensurePermission(prompt: true)
        attachToCodex()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Periodic re-check covers: AX permission granted later, Codex pet
        // window appearing after launch delay, AX subscription going stale.
        // 1s interval gives fast self-recovery if a fast drag burst desynced
        // the AX observer.
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recheck()
        }
    }

    @discardableResult
    private func ensurePermission(prompt: Bool) -> Bool {
        let prev = hasPermission
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            hasPermission = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        } else {
            hasPermission = AXIsProcessTrusted()
        }
        if prev != hasPermission {
            debugLog("AX permission changed: \(prev) → \(hasPermission)")
        } else if prompt {
            debugLog("AX permission at launch: \(hasPermission)")
        }
        return hasPermission
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isCodex(app) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.attachToCodex() }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == observedAppPID else { return }
        teardown()
    }

    private func teardown() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        observedWindow = nil
        observedAppPID = 0
    }

    private func recheck() {
        if !hasPermission { ensurePermission(prompt: false) }
        guard let win = observedWindow else {
            traceLog("ax-recheck", "noObservedWindow attemptingAttach")
            attachToCodex()
            return
        }
        // Active re-find: even if our handle still answers, the smallest matching
        // window may have changed (e.g. Codex destroyed/recreated the pet
        // container). Compare references and resubscribe on mismatch.
        if let app = NSWorkspace.shared.runningApplications.first(where: isCodex) {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            if let freshWin = findPetWindow(axApp: axApp) {
                let isSame = CFEqual(freshWin, win)
                traceLog("ax-recheck", "handleAlive=true sameWindow=\(isSame) freshFound=true")
                if !isSame {
                    teardown()
                    attachToCodex()
                    return
                }
            } else {
                traceLog("ax-recheck", "handleAlive=true sameWindow=? freshFound=false")
            }
        } else {
            traceLog("ax-recheck", "codexNotRunning checkingLiveness")
        }
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &ref)
        if err != .success {
            traceLog("ax-recheck", "handleAlive=false err=\(err.rawValue)")
            teardown()
            attachToCodex()
        } else {
            emit(source: "recheck")
        }
    }

    private func isCodex(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.openai.codex"
    }

    private func attachToCodex() {
        guard hasPermission else {
            debugLog("attach skipped: no AX permission")
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: isCodex) else {
            debugLog("attach skipped: Codex not running")
            return
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        guard let win = findPetWindow(axApp: axApp) else {
            debugLog("attach skipped: no matching pet window in Codex pid=\(pid)")
            return
        }
        teardown()
        observedAppPID = pid
        observedWindow = win
        subscribe(window: win, app: axApp, pid: pid)
        emit(source: "attach")
        debugLog("AX attached pid=\(pid)")
    }

    private func findPetWindow(axApp: AXUIElement) -> AXUIElement? {
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return nil }
        var matches: [(AXUIElement, CGFloat)] = []
        for win in wins {
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let sv = sizeRef else { continue }
            var size = CGSize.zero
            guard CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            let sval = sv as! AXValue
            guard AXValueGetValue(sval, .cgSize, &size) else { continue }
            // Widened from 300-430 / 250-390 in case Codex slightly resizes the
            // pet container near screen edges or on different display scales.
            if size.width >= 250, size.width <= 480, size.height >= 220, size.height <= 420 {
                matches.append((win, size.width * size.height))
            }
        }
        // Prefer the smallest matching window (the pet container, not a chat panel)
        return matches.sorted(by: { $0.1 < $1.1 }).first?.0
    }

    private func subscribe(window: AXUIElement, app: AXUIElement, pid: pid_t) {
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<CodexPetTracker>.fromOpaque(refcon).takeUnretainedValue().emit(source: "callback")
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let r1 = AXObserverAddNotification(obs, window, kAXMovedNotification as CFString, refcon)
        let r2 = AXObserverAddNotification(obs, window, kAXResizedNotification as CFString, refcon)
        traceLog("ax-subscribe", "moved=\(r1.rawValue) resized=\(r2.rawValue) pid=\(pid)")
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(obs), .commonModes)
    }

    private func emit(source: String) {
        guard let win = observedWindow else { return }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef else { return }
        var pos = CGPoint.zero, size = CGSize.zero
        guard CFGetTypeID(pv) == AXValueGetTypeID(),
              CFGetTypeID(sv) == AXValueGetTypeID() else { return }
        let pval = pv as! AXValue
        let sval = sv as! AXValue
        guard AXValueGetValue(pval, .cgPoint, &pos),
              AXValueGetValue(sval, .cgSize, &size) else { return }
        // AX returns position in screen top-left coordinates (same as CGWindow).
        let rect = NSRect(origin: pos, size: size)
        traceLog("ax-fire", "src=\(source) petX=\(pos.x) petY=\(pos.y) petW=\(size.width) petH=\(size.height)")
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(rect) }
    }
}

func debugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/codex-usage-halo.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

let traceEnabled: Bool = {
    if CommandLine.arguments.contains("--trace") {
        // Truncate previous trace log on every --trace startup so each
        // reproduction session starts clean.
        try? FileManager.default.removeItem(atPath: "/tmp/codex-usage-halo-trace.log")
        return true
    }
    return false
}()

private let traceFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func traceLog(_ tag: String, _ kvs: @autoclosure () -> String) {
    guard traceEnabled else { return }
    let line = "\(traceFormatter.string(from: Date())) TRACE tag=\(tag) \(kvs())\n"
    let url = URL(fileURLWithPath: "/tmp/codex-usage-halo-trace.log")
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path),
       let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
        try? h.close()
    } else {
        try? data.write(to: url)
    }
}

struct UsageResponse: Decodable {
    struct WindowUsage: Decodable {
        let usedPercent: Double?
        let resetsAt: String?
    }

    let ok: Bool
    let session: WindowUsage?
    let weekly: WindowUsage?
}

final class HaloWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    // Disable AppKit's automatic "keep title bar visible" frame constraint so
    // the halo can follow the Codex pet all the way to (and past) screen edges
    // without being snapped back inward.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

enum DisplayMode: String {
    case pulse
    case ring
}

enum UsageMetric: String {
    case used
    case left
}

final class HaloView: NSView {
    private var sessionPercent: Double = 0
    private var weeklyPercent: Double = 0
    private var resetsAt: Date?
    private var isHovering = false
    private var animationStart = Date()
    private var animationTimer: Timer?
    private var refreshTimer: Timer?
    private var dragStartScreenPoint: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var isDragging = false
    private var followTick: Int = 0
    // Cursor-tracking mode: when user is dragging the Codex pet itself
    // (mouse-down inside Codex's pet window), we follow the cursor directly
    // instead of AX-reported window position. This bypasses Codex's edge
    // teleport behavior — Codex slides its window back into screen at edges
    // and re-renders the sprite to compensate, so the sprite stays glued to
    // the cursor while the window jumps. Tracking the cursor keeps the halo
    // glued to the visible sprite no matter how Codex moves its window.
    private var globalMouseMonitor: Any?
    private var dragCursorOffset: NSPoint?
    private let isoFormatter = ISO8601DateFormatter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addTimers()
        installGlobalMouseMonitor()
        refreshUsage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
        refreshTimer?.invalidate()
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installGlobalMouseMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown:
                self.startCursorTrackingIfOnPet()
            case .leftMouseDragged:
                self.followCursorIfTracking()
            case .leftMouseUp:
                self.endCursorTracking()
            default:
                break
            }
        }
    }

    private func startCursorTrackingIfOnPet() {
        guard let halo = window else { return }
        let cursor = NSEvent.mouseLocation  // AppKit bottom-left coords
        guard let petRectCG = HaloView.codexPetWindowRect() else { return }
        // petRectCG is in CGWindow top-left coords. Convert cursor to match.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let cursorCG = NSPoint(x: cursor.x, y: primaryHeight - cursor.y)
        guard petRectCG.contains(cursorCG) else { return }
        // Lock in the offset between cursor and halo origin at click time so
        // the relative position the user picked is preserved throughout drag.
        let haloOrigin = halo.frame.origin
        dragCursorOffset = NSPoint(x: cursor.x - haloOrigin.x, y: cursor.y - haloOrigin.y)
        traceLog("cursor-track-start",
                 "cursorX=\(cursor.x) cursorY=\(cursor.y) haloX=\(haloOrigin.x) haloY=\(haloOrigin.y) offsetX=\(dragCursorOffset!.x) offsetY=\(dragCursorOffset!.y)")
    }

    private func followCursorIfTracking() {
        guard let offset = dragCursorOffset, let halo = window else { return }
        let cursor = NSEvent.mouseLocation
        let newOrigin = NSPoint(x: cursor.x - offset.x, y: cursor.y - offset.y)
        halo.setFrameOrigin(newOrigin)
    }

    private func endCursorTracking() {
        guard dragCursorOffset != nil else { return }
        dragCursorOffset = nil
        // Auto-recalibrate so the formula-driven AX tracking that resumes now
        // computes the same position the halo is currently at (i.e. where the
        // user just dragged the sprite to). Without this, the next AX event
        // would snap the halo to the formula's pre-drag target — which may
        // have been displaced by Codex's edge teleport during the drag —
        // producing the "halo bounces away on release" symptom.
        calibrateMascotAnchorFromCurrentPosition()
        traceLog("cursor-track-end", "auto-recalibrated")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance >= 38 && distance <= 82 { return self }
        if isHovering && (sessionBadgeRect().contains(point) || weeklyBadgeRect().contains(point) || statusRect().contains(point)) {
            return self
        }
        return nil
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStartScreenPoint, let dragStartWindowOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartScreenPoint.x
        let dy = now.y - dragStartScreenPoint.y
        window.setFrameOrigin(NSPoint(x: dragStartWindowOrigin.x + dx, y: dragStartWindowOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        // If the user actually dragged the halo (>= 3 px), treat that as
        // "calibration": save the new mascot anchor as a percentage of the
        // Codex pet container. The halo's new position becomes its permanent
        // anchor that follow-tracking will preserve as the pet moves.
        let didDrag: Bool = {
            guard let start = dragStartScreenPoint else { return false }
            let now = NSEvent.mouseLocation
            return hypot(now.x - start.x, now.y - start.y) >= 3
        }()
        isDragging = false
        dragStartScreenPoint = nil
        dragStartWindowOrigin = nil
        if didDrag {
            calibrateMascotAnchorFromCurrentPosition()
        } else {
            // No drag — snap any drift back to the saved anchor.
            settleToPet()
        }
    }

    /// Reads the halo window's current center, expresses it as a percentage of
    /// the Codex pet container, and persists those percentages so that future
    /// follow-tracking centers the halo there.
    private func calibrateMascotAnchorFromCurrentPosition() {
        guard let window, let pet = Self.codexPetWindowRect() else { return }
        // Convert halo's AppKit frame back to CGWindow top-left coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let haloCenterX = window.frame.midX
        let haloCenterY_appkit = window.frame.midY
        let haloCenterY_cg = primaryHeight - haloCenterY_appkit
        guard pet.width > 0, pet.height > 0 else { return }
        let pctX = (haloCenterX - pet.origin.x) / pet.width
        let pctY = (haloCenterY_cg - pet.origin.y) / pet.height
        // Sanity clamp — refuse outlandish values.
        let clampedX = min(2.0, max(-1.0, pctX))
        let clampedY = min(2.0, max(-1.0, pctY))
        UserDefaults.standard.set(clampedX, forKey: "mascotPercentX")
        UserDefaults.standard.set(clampedY, forKey: "mascotPercentY")
        debugLog("calibrated mascot anchor pctX=\(clampedX) pctY=\(clampedY)")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let session = displayPercent(sessionPercent)
        let weekly = displayPercent(weeklyPercent)
        let sessionColor = NSColor(calibratedRed: 0.30, green: 0.91, blue: 0.82, alpha: 1)
        let weeklyColor = NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.31, alpha: 1)
        drawRing(context: context, center: center, radius: 61, width: 7.5, percent: session, color: sessionColor)
        drawRing(context: context, center: center, radius: 47, width: 6.0, percent: weekly, color: weeklyColor)
        if displayMode == .pulse {
            drawPulse(context: context, center: center, radius: 61, percent: session, color: sessionColor, size: 15, phaseOffset: 0)
            drawPulse(context: context, center: center, radius: 47, percent: weekly, color: weeklyColor, size: 11, phaseOffset: 0.6)
        }

        if isHovering {
            drawBadge(text: "\(Int(round(session)))%", rect: sessionBadgeRect(), color: NSColor(calibratedRed: 0.30, green: 0.91, blue: 0.82, alpha: 0.48))
            drawBadge(text: "\(Int(round(weekly)))%", rect: weeklyBadgeRect(), color: NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.31, alpha: 0.48))
            drawBadge(text: resetLabel(), rect: statusRect(), color: NSColor(white: 1, alpha: 0.22), fontSize: 11)
        }
    }

    func reloadSettings() {
        needsDisplay = true
    }

    private func addTimers() {
        // 30Hz: orb animation redraw + adaptive polling.
        //   AX off → poll every tick (30Hz, full speed).
        //   AX on  → poll every 8th tick (~4Hz) as a safety net for missed
        //            AX notifications (e.g. coalesced during very fast drags).
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            self.followTick &+= 1
            let interval = CodexPetTracker.shared.isConnected ? 8 : 1
            if self.followTick % interval == 0 {
                let rect = HaloView.codexPetWindowRect()
                let rectStr = rect.map { "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)" } ?? "-"
                traceLog("poll-tick", "tick=\(self.followTick) result=\(rect == nil ? "nil" : "ok") rect=\(rectStr) axConnected=\(CodexPetTracker.shared.isConnected)")
                self.followCodexPetIfPossible()
            }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    /// Called by `CodexPetTracker` whenever the Codex pet window moves/resizes.
    /// `petRect` is the Codex pet container in screen top-left coordinates.
    func applyPetWindowRect(_ petRect: NSRect) {
        guard !isDragging, let window else { return }
        // Cursor-tracking takes precedence — while user drags pet, halo
        // follows cursor directly (see installGlobalMouseMonitor). AX-driven
        // updates are silenced to avoid fighting Codex's edge teleports.
        if dragCursorOffset != nil { return }
        let target = Self.haloRect(forPetWindow: petRect)

        // Convert CGWindow top-left target → AppKit bottom-left absolute frame.
        // Using absolute positioning (no delta math) eliminates drift during
        // fast drags, where CGWindowList snapshots of the halo's own position
        // would otherwise lag reality and accumulate error.
        let targetFrame = Self.cgWindowRectToAppKit(target)
        let current = window.frame
        let distance = hypot(targetFrame.origin.x - current.origin.x,
                             targetFrame.origin.y - current.origin.y)

        let action = distance < 0.5 ? "skip" : "snap"
        traceLog("apply", "petX=\(petRect.origin.x) petY=\(petRect.origin.y) petW=\(petRect.width) petH=\(petRect.height) curX=\(current.origin.x) curY=\(current.origin.y) tgtX=\(targetFrame.origin.x) tgtY=\(targetFrame.origin.y) dist=\(Int(distance)) act=\(action)")

        if action == "skip" { return }

        // Always snap to absolute target. Direct setFrame is pixel-perfect
        // and zero-latency. Codex's pet self-teleports at screen edges still
        // cause halo to jump (because we faithfully follow), but that's
        // Codex's behavior, not ours — user must decide whether to live with
        // it or add a teleport-rejection layer.
        window.setFrame(targetFrame, display: false)

        // Read the actual frame back asynchronously. Useful while --trace is
        // on for verifying no AppKit clamping is happening on this code path.
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            traceLog("setframe-after",
                     "reqX=\(targetFrame.origin.x) reqY=\(targetFrame.origin.y) actX=\(w.frame.origin.x) actY=\(w.frame.origin.y) act=\(action)")
        }
    }

    /// Convert a CGWindow-space rect (top-left origin) to an AppKit-space rect
    /// (bottom-left origin) using the primary screen as anchor.
    static func cgWindowRectToAppKit(_ rect: NSRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let appkitY = primaryHeight - rect.origin.y - rect.height
        return NSRect(x: rect.origin.x, y: appkitY, width: rect.width, height: rect.height)
    }

    private func refreshUsage() {
        guard let url = URL(string: "http://127.0.0.1:43741/api/usage") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data), usage.ok else { return }
            DispatchQueue.main.async {
                self.sessionPercent = Self.clamp(usage.session?.usedPercent ?? 0)
                self.weeklyPercent = Self.clamp(usage.weekly?.usedPercent ?? 0)
                if let resetsAt = usage.session?.resetsAt {
                    self.resetsAt = self.isoFormatter.date(from: resetsAt)
                }
                self.needsDisplay = true
            }
        }.resume()
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private var displayMode: DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .pulse
    }

    private var usageMetric: UsageMetric {
        UsageMetric(rawValue: UserDefaults.standard.string(forKey: "usageMetric") ?? "") ?? .used
    }

    private func displayPercent(_ usedPercent: Double) -> Double {
        switch usageMetric {
        case .used:
            return usedPercent
        case .left:
            return Self.clamp(100 - usedPercent)
        }
    }

    private func drawRing(context: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, percent: Double, color: NSColor) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(width)
        context.setShadow(offset: .zero, blur: 10, color: color.withAlphaComponent(0.58).cgColor)
        context.setStrokeColor(color.cgColor)
        let start = CGFloat.pi / 2
        let end = start - CGFloat.pi * 2 * CGFloat(percent / 100)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        context.strokePath()
        context.restoreGState()
    }

    private func drawPulse(context: CGContext, center: CGPoint, radius: CGFloat, percent: Double, color: NSColor, size: CGFloat, phaseOffset: TimeInterval) {
        let elapsed = Date().timeIntervalSince(animationStart) + phaseOffset

        // The wave runs along the SAME arc as the static ring fill: from 12
        // o'clock clockwise for `percent` of the full circle. New beats
        // emerge at the leading edge (the percent endpoint, where the orb
        // used to live) and scroll back toward the start (top).
        let percentClamped = max(0.0, min(100.0, percent)) / 100.0
        guard percentClamped > 0.005 else { return }  // nothing to draw at ~0%

        let cycle: TimeInterval = 1.2
        let arcSpan: CGFloat = CGFloat(percentClamped) * .pi * 2
        let startAngle: CGFloat = .pi / 2  // top of the ring (matches drawRing)
        // Beat density: ~45° of arc per heartbeat. scrollDuration scales with
        // arcSpan so the wavelength stays visually constant regardless of %.
        let wavelength: CGFloat = .pi / 4
        let beatsVisible = max(1.0, Double(arcSpan / wavelength))
        let scrollDuration: TimeInterval = beatsVisible * cycle
        // Sampling density: ~1 sample per 3° of arc, with a sane minimum.
        let pointsCount = max(20, Int(arcSpan * 180 / .pi / 3))
        let amp: CGFloat = size * 1.6

        @inline(__always) func envelope(_ phase: Double) -> Double {
            let p = 0.35 * exp(-pow((phase - 0.07) * 22, 2))
            let r = 1.00 * exp(-pow((phase - 0.25) * 22, 2))
            let s = 0.55 * exp(-pow((phase - 0.35) * 22, 2))
            let t = 0.45 * exp(-pow((phase - 0.62) * 14, 2))
            return p + r - s + t
        }

        var points: [CGPoint] = []
        points.reserveCapacity(pointsCount + 1)
        for i in 0...pointsCount {
            let frac = Double(i) / Double(pointsCount)        // 0 (top, oldest) .. 1 (percent endpoint, newest)
            let pointAngle = startAngle - arcSpan * CGFloat(frac)
            let timeOffset = -(1.0 - frac) * scrollDuration
            let t = elapsed + timeOffset
            var raw = t.truncatingRemainder(dividingBy: cycle) / cycle
            if raw < 0 { raw += 1 }
            let displacement = CGFloat(envelope(raw)) * amp
            let r = radius + displacement
            points.append(CGPoint(x: center.x + cos(pointAngle) * r,
                                  y: center.y + sin(pointAngle) * r))
        }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(1.8)
        context.setStrokeColor(color.cgColor)
        context.setShadow(offset: .zero, blur: 6,
                          color: color.withAlphaComponent(0.55).cgColor)
        context.beginPath()
        context.move(to: points[0])
        for p in points.dropFirst() {
            context.addLine(to: p)
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawBadge(text: String, rect: NSRect, color: NSColor, fontSize: CGFloat = 14) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 0.06, alpha: 0.78).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let textRect = rect.insetBy(dx: 5, dy: (rect.height - fontSize - 3) / 2)
        NSString(string: text).draw(in: textRect, withAttributes: attrs)
    }

    private func sessionBadgeRect() -> NSRect {
        NSRect(x: bounds.midX - 27, y: bounds.maxY - 32, width: 54, height: 27)
    }

    private func weeklyBadgeRect() -> NSRect {
        NSRect(x: bounds.maxX - 64, y: 34, width: 58, height: 27)
    }

    private func statusRect() -> NSRect {
        NSRect(x: bounds.midX - 48, y: 2, width: 96, height: 22)
    }

    private func resetLabel() -> String {
        guard let resetsAt else { return "5h reset" }
        let seconds = max(0, resetsAt.timeIntervalSinceNow)
        if seconds >= 3600 {
            return "5h reset in \(Int(ceil(seconds / 3600)))h"
        }
        return "5h reset in \(max(1, Int(ceil(seconds / 60))))m"
    }

    private func persistWindowFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "haloWindowFrame")
    }

    private func followCodexPetIfPossible() {
        guard let petRect = Self.codexPetWindowRect() else { return }
        applyPetWindowRect(petRect)
    }

    private func settleToPet() {
        followCodexPetIfPossible()
        for delay in [0.08, 0.25, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.followCodexPetIfPossible()
            }
        }
    }

    static func haloRect(forPetWindow rect: NSRect) -> NSRect {
        // Per-user calibrated mascot anchor (set by dragging the halo onto the
        // pet sprite). Falls back to factory defaults if not yet calibrated.
        let defaults = UserDefaults.standard
        let pctX = defaults.object(forKey: "mascotPercentX") as? Double ?? 0.817
        let pctY = defaults.object(forKey: "mascotPercentY") as? Double ?? 0.670
        let mascotCenterX = rect.origin.x + rect.width * CGFloat(pctX)
        let mascotCenterY = rect.origin.y + rect.height * CGFloat(pctY)
        return NSRect(x: mascotCenterX - 85, y: mascotCenterY - 85, width: 170, height: 170)
    }

    static func codexPetWindowRect() -> NSRect? {
        let candidates = windowBounds(owner: "Codex")
            .filter { item in
                item.layer == 3 &&
                item.rect.width >= 250 &&
                item.rect.width <= 480 &&
                item.rect.height >= 220 &&
                item.rect.height <= 420
            }
        return candidates.sorted(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }).first?.rect
    }

    private static func codexPetHaloBounds() -> NSRect? {
        guard let petRect = codexPetWindowRect() else { return nil }
        return haloRect(forPetWindow: petRect)
    }

    private static func haloWindowBounds() -> (rect: NSRect, layer: Int, name: String)? {
        windowBounds(owner: "Codex Pet Meter").first ?? windowBounds(owner: "Codex Usage Halo").first
    }

    private static func windowBounds(owner: String) -> [(rect: NSRect, layer: Int, name: String)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerName as String] as? String) == owner,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }
            let x = CGFloat((bounds["X"] as? NSNumber)?.doubleValue ?? 0)
            let y = CGFloat((bounds["Y"] as? NSNumber)?.doubleValue ?? 0)
            let width = CGFloat((bounds["Width"] as? NSNumber)?.doubleValue ?? 0)
            let height = CGFloat((bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
            guard width > 1, height > 1 else { return nil }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let name = window[kCGWindowName as String] as? String ?? ""
            return (NSRect(x: x, y: y, width: width, height: height), layer, name)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: HaloWindow?
    private var statusItem: NSStatusItem?
    private weak var haloView: HaloView?
    private var pulseModeItem: NSMenuItem?
    private var ringModeItem: NSMenuItem?
    private var usedMetricItem: NSMenuItem?
    private var leftMetricItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching args=\(CommandLine.arguments)")
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--reset-position") {
            UserDefaults.standard.removeObject(forKey: "haloWindowFrame")
            UserDefaults.standard.removeObject(forKey: "haloFollowOffset")
        }
        createStatusItem()
        createWindow()
        // Real-time pet tracking via Accessibility API. Requires user grant
        // (System Settings → Privacy & Security → Accessibility). Falls back to
        // 30Hz CGWindowList polling if denied.
        CodexPetTracker.shared.start { [weak self] petRect in
            self?.haloView?.applyPetWindowRect(petRect)
        }
    }

    private func createWindow() {
        let defaultFrame = Self.defaultWindowFrame()
        let stored = UserDefaults.standard.string(forKey: "haloWindowFrame").map(NSRectFromString)
        let frame = stored?.isEmpty == false ? stored! : defaultFrame
        debugLog("createWindow frame=\(NSStringFromRect(frame))")
        let panel = HaloWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Codex Pet Meter"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.acceptsMouseMovedEvents = true
        let view = HaloView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        haloView = view
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        window = panel
        debugLog("window ordered isVisible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame))")
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.image = Self.statusIcon()
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "Codex Pet Meter", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let pulseItem = NSMenuItem(title: "Pulse motion", action: #selector(setPulseMode), keyEquivalent: "")
        let ringItem = NSMenuItem(title: "Ring only", action: #selector(setRingMode), keyEquivalent: "")
        menu.addItem(pulseItem)
        menu.addItem(ringItem)
        menu.addItem(.separator())

        let usedItem = NSMenuItem(title: "Show used", action: #selector(setUsedMetric), keyEquivalent: "")
        let leftItem = NSMenuItem(title: "Show left", action: #selector(setLeftMetric), keyEquivalent: "")
        menu.addItem(usedItem)
        menu.addItem(leftItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Show meter", action: #selector(showHalo), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset position", action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset calibration", action: #selector(resetCalibration), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        pulseModeItem = pulseItem
        ringModeItem = ringItem
        usedMetricItem = usedItem
        leftMetricItem = leftItem
        updateMenuState()
    }

    @objc private func showHalo() {
        window?.orderFrontRegardless()
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "haloWindowFrame")
        UserDefaults.standard.removeObject(forKey: "haloFollowOffset")
        window?.setFrame(Self.defaultWindowFrame(), display: true)
        window?.orderFrontRegardless()
    }

    @objc private func resetCalibration() {
        UserDefaults.standard.removeObject(forKey: "mascotPercentX")
        UserDefaults.standard.removeObject(forKey: "mascotPercentY")
        haloView?.reloadSettings()
    }

    @objc private func setPulseMode() {
        UserDefaults.standard.set(DisplayMode.pulse.rawValue, forKey: "displayMode")
        updateSettings()
    }

    @objc private func setRingMode() {
        UserDefaults.standard.set(DisplayMode.ring.rawValue, forKey: "displayMode")
        updateSettings()
    }

    @objc private func setUsedMetric() {
        UserDefaults.standard.set(UsageMetric.used.rawValue, forKey: "usageMetric")
        updateSettings()
    }

    @objc private func setLeftMetric() {
        UserDefaults.standard.set(UsageMetric.left.rawValue, forKey: "usageMetric")
        updateSettings()
    }

    private func updateSettings() {
        updateMenuState()
        haloView?.reloadSettings()
    }

    private func updateMenuState() {
        let mode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .pulse
        let metric = UsageMetric(rawValue: UserDefaults.standard.string(forKey: "usageMetric") ?? "") ?? .used
        pulseModeItem?.state = mode == .pulse ? .on : .off
        ringModeItem?.state = mode == .ring ? .on : .off
        usedMetricItem?.state = metric == .used ? .on : .off
        leftMetricItem?.state = metric == .left ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func defaultWindowFrame() -> NSRect {
        let size = NSSize(width: 170, height: 170)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        context.setLineCap(.round)
        context.setLineWidth(2)
        context.setStrokeColor(NSColor(calibratedRed: 0.30, green: 0.91, blue: 0.82, alpha: 1).cgColor)
        context.addArc(center: CGPoint(x: 10, y: 9), radius: 6.5, startAngle: CGFloat.pi / 2, endAngle: CGFloat.pi / 2 - CGFloat.pi * 1.45, clockwise: true)
        context.strokePath()
        context.setLineWidth(1.7)
        context.setStrokeColor(NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.31, alpha: 1).cgColor)
        context.addArc(center: CGPoint(x: 10, y: 9), radius: 4.0, startAngle: CGFloat.pi / 2, endAngle: CGFloat.pi / 2 - CGFloat.pi * 1.0, clockwise: true)
        context.strokePath()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
