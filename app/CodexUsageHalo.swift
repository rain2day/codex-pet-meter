import Cocoa

// MARK: - Codex state readers
//
// File-based backend. Codex itself maintains:
//   ~/.codex/.codex-global-state.json  — pet open/closed + sprite bounds
//   ~/.codex/auth.json                 — OAuth tokens for live usage API
//
// Two readers poll those files (and the OpenAI usage endpoint) on their own
// schedule and fan results out via callbacks. The view layer is unchanged.
//
// Why files instead of Accessibility API: Codex's Electron pet window slides
// inward at screen edges and re-renders the sprite at a compensating offset
// (so the sprite stays glued to the cursor while the window jumps). AX
// reports the WINDOW position, not the SPRITE — so AX-based tracking would
// see the halo "bounce away" at edges. Codex's own state file already
// publishes the sprite's logical rect, so we read that directly. Bonus:
// no Accessibility permission required, no calibration needed, no edge-case
// cursor-tracking workaround.

private let petPollInterval: TimeInterval = 0.1
private let usagePollInterval: TimeInterval = 60
private let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"  // OpenAI's public Codex client id
private let usageEndpoint = "https://chatgpt.com/backend-api/wham/usage"
private let refreshEndpoint = "https://auth.openai.com/oauth/token"

private func codexHomePath() -> String {
    if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envHome.isEmpty {
        return envHome
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
}

private func cgFloat(_ value: Any?) -> CGFloat? {
    if let n = value as? NSNumber { return CGFloat(truncating: n) }
    if let d = value as? Double { return CGFloat(d) }
    if let i = value as? Int { return CGFloat(i) }
    return nil
}

// Reads ~/.codex/.codex-global-state.json on a fast timer and emits the
// current sprite rect (in CGWindow top-left screen coords) — or nil when
// the pet is hidden. Only emits when the rect changes, to avoid redrawing
// on every poll.
final class CodexStateReader {
    static let shared = CodexStateReader()

    var onPetUpdate: ((NSRect?) -> Void)?

    private let stateFilePath: String
    private var timer: Timer?
    private var lastRect: NSRect?
    private var lastWasOpen: Bool?

    init() {
        stateFilePath = codexHomePath() + "/.codex-global-state.json"
    }

    func start(onPetUpdate: @escaping (NSRect?) -> Void) {
        self.onPetUpdate = onPetUpdate
        timer = Timer.scheduledTimer(withTimeInterval: petPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()  // immediate first read
    }

    private func poll() {
        let snapshot = readSpriteRect()
        // Edge-trigger: only emit on change.
        let isOpen = (snapshot != nil)
        if isOpen == lastWasOpen, snapshot == lastRect { return }
        lastRect = snapshot
        lastWasOpen = isOpen
        let sendRect = snapshot
        DispatchQueue.main.async { [weak self] in self?.onPetUpdate?(sendRect) }
    }

    private func readSpriteRect() -> NSRect? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let isOpen: Bool = {
            if let b = root["electron-avatar-overlay-open"] as? Bool { return b }
            if let n = root["electron-avatar-overlay-open"] as? NSNumber { return n.boolValue }
            return false
        }()
        guard isOpen,
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = cgFloat(bounds["x"]),
              let y = cgFloat(bounds["y"]),
              let mascot = bounds["mascot"] as? [String: Any],
              let mLeft = cgFloat(mascot["left"]),
              let mTop = cgFloat(mascot["top"]),
              let mWidth = cgFloat(mascot["width"]),
              let mHeight = cgFloat(mascot["height"]) else {
            return nil
        }
        return NSRect(x: x + mLeft, y: y + mTop, width: mWidth, height: mHeight)
    }
}

// Fetches usage data directly from chatgpt.com/backend-api/wham/usage using
// the access token from ~/.codex/auth.json. Refreshes the token via OAuth
// on 401/403. Polls every 60 seconds. Result is fanned out via callback.
final class CodexUsageReader {
    static let shared = CodexUsageReader()

    /// Callback args: session %, weekly %, session resetsAt date.
    var onUsageUpdate: ((Double, Double, Date?) -> Void)?

    private let authFilePath: String
    private var timer: Timer?

    init() {
        authFilePath = codexHomePath() + "/auth.json"
    }

    func start(onUsageUpdate: @escaping (Double, Double, Date?) -> Void) {
        self.onUsageUpdate = onUsageUpdate
        timer = Timer.scheduledTimer(withTimeInterval: usagePollInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        fetch()  // immediate first read
    }

    private func fetch() {
        guard let auth = readAuth(),
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return
        }
        request(accessToken: accessToken, accountId: tokens["account_id"] as? String, retry: true)
    }

    private func readAuth() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func request(accessToken: String, accountId: String?, retry: Bool) {
        guard let url = URL(string: usageEndpoint) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("CodexPetMeter", forHTTPHeaderField: "User-Agent")
        if let accountId { req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (status == 401 || status == 403) && retry {
                self.refreshTokenAndRetry()
                return
            }
            guard status >= 200, status < 300, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            self.parseAndEmit(json)
        }.resume()
    }

    private func refreshTokenAndRetry() {
        guard var auth = readAuth(),
              var tokens = auth["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String,
              let url = URL(string: refreshEndpoint) else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&client_id=\(oauthClientID)&refresh_token=\(refreshToken)"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
                return
            }
            tokens["access_token"] = newAccess
            if let newRefresh = json["refresh_token"] as? String { tokens["refresh_token"] = newRefresh }
            if let newId = json["id_token"] as? String { tokens["id_token"] = newId }
            auth["tokens"] = tokens
            auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            if let serialized = try? JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted]) {
                try? serialized.write(to: URL(fileURLWithPath: self.authFilePath))
            }
            self.request(accessToken: newAccess, accountId: tokens["account_id"] as? String, retry: false)
        }.resume()
    }

    private func parseAndEmit(_ json: [String: Any]) {
        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]
        let primary = rateLimit["primary_window"] as? [String: Any] ?? rateLimit["primary"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any] ?? rateLimit["secondary"] as? [String: Any]

        let session = clamp((primary?["used_percent"] as? NSNumber)?.doubleValue ?? 0)
        let weekly = clamp((secondary?["used_percent"] as? NSNumber)?.doubleValue ?? 0)
        let resetsAt = parseReset(primary)
        debugLog("usage session=\(session)% weekly=\(weekly)% resetsAt=\(resetsAt?.description ?? "nil")")

        DispatchQueue.main.async { [weak self] in
            self?.onUsageUpdate?(session, weekly, resetsAt)
        }
    }

    private func parseReset(_ window: [String: Any]?) -> Date? {
        guard let window else { return nil }
        if let resetAt = window["reset_at"] as? NSNumber {
            return Date(timeIntervalSince1970: resetAt.doubleValue)
        }
        if let resetAfter = window["reset_after_seconds"] as? NSNumber {
            return Date(timeIntervalSinceNow: resetAfter.doubleValue)
        }
        return nil
    }

    private func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
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

enum Formation: String {
    case stacked  // two concentric rings (session outer, weekly inner)
    case split    // single radius split into halves: session right, weekly left
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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addTimers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
        refreshTimer?.invalidate()
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

    /// Halo is no longer draggable — its position is determined entirely by
    /// the sprite rect from CodexStateReader. Mouse-down absorbs the click so
    /// it doesn't fall through.
    override func mouseDown(with event: NSEvent) { /* no-op */ }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let session = displayPercent(sessionPercent)
        let weekly = displayPercent(weeklyPercent)
        let sessionColor = Self.sessionColor()
        let weeklyColor = Self.weeklyColor()

        switch formation {
        case .stacked:
            // Concentric: session outer (radius 61), weekly inner (radius 47)
            drawRing(context: context, center: center, radius: 61, width: 7.5, percent: session, color: sessionColor)
            drawRing(context: context, center: center, radius: 47, width: 6.0, percent: weekly, color: weeklyColor)
            if displayMode == .pulse {
                drawPulse(context: context, center: center, radius: 61, percent: session, color: sessionColor, size: 15, phaseOffset: 0)
                drawPulse(context: context, center: center, radius: 47, percent: weekly, color: weeklyColor, size: 11, phaseOffset: 0.6)
            }
        case .split:
            // Vertically bisected, both rings share one radius. Both fill in
            // CCW direction so they grow AWAY from each other:
            //   Session: right half — starts at 6 o'clock, fills bottom→top
            //            (CCW reaches 12 o'clock at 100%).
            //   Weekly:  left half  — starts at 12 o'clock, fills top→bottom
            //            (CCW reaches 6 o'clock at 100%).
            // At low percentages the two arcs sit on opposite quadrants, so
            // the "split" reading is unmistakable instead of two arcs both
            // clustered near the top.
            let r: CGFloat = 56
            drawRing(context: context, center: center, radius: r, width: 7.0, percent: session, color: sessionColor,
                     startAngle: -.pi / 2, maxSweep: .pi, clockwise: false)
            drawRing(context: context, center: center, radius: r, width: 7.0, percent: weekly, color: weeklyColor,
                     startAngle: .pi / 2, maxSweep: .pi, clockwise: false)
            if displayMode == .pulse {
                drawPulse(context: context, center: center, radius: r, percent: session, color: sessionColor, size: 13, phaseOffset: 0,
                          startAngle: -.pi / 2, maxSweep: .pi, clockwise: false)
                drawPulse(context: context, center: center, radius: r, percent: weekly, color: weeklyColor, size: 13, phaseOffset: 0.6,
                          startAngle: .pi / 2, maxSweep: .pi, clockwise: false)
            }
        }

        if isHovering {
            drawBadge(text: "\(Int(round(session)))%", rect: sessionBadgeRect(), color: sessionColor.withAlphaComponent(0.48))
            drawBadge(text: "\(Int(round(weekly)))%", rect: weeklyBadgeRect(), color: weeklyColor.withAlphaComponent(0.48))
            drawBadge(text: resetLabel(), rect: statusRect(), color: NSColor(white: 1, alpha: 0.22), fontSize: 11)
        }
    }

    static let defaultSessionColor = NSColor(calibratedRed: 0.30, green: 0.91, blue: 0.82, alpha: 1)
    static let defaultWeeklyColor  = NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.31, alpha: 1)

    static func sessionColor() -> NSColor {
        loadColor(forKey: "sessionColor", default: defaultSessionColor)
    }
    static func weeklyColor() -> NSColor {
        loadColor(forKey: "weeklyColor", default: defaultWeeklyColor)
    }

    private static func loadColor(forKey key: String, default fallback: NSColor) -> NSColor {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 4 else {
            return fallback
        }
        return NSColor(calibratedRed: CGFloat(arr[0]), green: CGFloat(arr[1]),
                       blue: CGFloat(arr[2]), alpha: CGFloat(arr[3]))
    }

    static func saveColor(_ color: NSColor, forKey key: String) {
        let c = color.usingColorSpace(.genericRGB) ?? color
        UserDefaults.standard.set(
            [Double(c.redComponent), Double(c.greenComponent),
             Double(c.blueComponent), Double(c.alphaComponent)],
            forKey: key)
    }

    func reloadSettings() {
        needsDisplay = true
    }

    private func addTimers() {
        // 30Hz redraw — drives the EKG pulse animation. Pet-position updates
        // and usage refreshes are handled by CodexStateReader / CodexUsageReader.
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    /// File-backend entry: position the halo so it centers on the pet sprite.
    /// `spriteRect` is the sprite in CGWindow top-left screen coords (or nil
    /// when the pet is hidden).
    func applySpriteRect(_ spriteRect: NSRect?) {
        guard let window else { return }
        guard let spriteRect else {
            // Pet hidden — slide the halo offscreen by hiding the window.
            window.orderOut(nil)
            return
        }
        if !window.isVisible { window.orderFrontRegardless() }

        // Halo center = sprite center. No calibration, no formula — Codex
        // tells us the sprite's exact rect, so we just align centers.
        let centerXcg = spriteRect.midX
        let centerYcg = spriteRect.midY
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let centerYappkit = primaryHeight - centerYcg
        let halfW = window.frame.width / 2
        let halfH = window.frame.height / 2
        let targetFrame = NSRect(x: centerXcg - halfW,
                                 y: centerYappkit - halfH,
                                 width: window.frame.width,
                                 height: window.frame.height)
        let current = window.frame
        let distance = hypot(targetFrame.origin.x - current.origin.x,
                             targetFrame.origin.y - current.origin.y)
        if distance < 0.5 { return }
        window.setFrame(targetFrame, display: false)
    }

    /// File-backend entry: usage-data update from `CodexUsageReader`.
    func applyUsage(session: Double, weekly: Double, resetsAt: Date?) {
        sessionPercent = session
        weeklyPercent = weekly
        if let resetsAt { self.resetsAt = resetsAt }
        needsDisplay = true
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private var displayMode: DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .pulse
    }

    private var formation: Formation {
        Formation(rawValue: UserDefaults.standard.string(forKey: "formation") ?? "") ?? .stacked
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

    private func drawRing(context: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, percent: Double, color: NSColor, startAngle: CGFloat = .pi / 2, maxSweep: CGFloat = .pi * 2, clockwise: Bool = true) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(width)
        context.setShadow(offset: .zero, blur: 10, color: color.withAlphaComponent(0.58).cgColor)
        context.setStrokeColor(color.cgColor)
        let sweep = maxSweep * CGFloat(percent / 100)
        let end = clockwise ? startAngle - sweep : startAngle + sweep
        context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: end, clockwise: clockwise)
        context.strokePath()
        context.restoreGState()
    }

    private func drawPulse(context: CGContext, center: CGPoint, radius: CGFloat, percent: Double, color: NSColor, size: CGFloat, phaseOffset: TimeInterval, startAngle: CGFloat = .pi / 2, maxSweep: CGFloat = .pi * 2, clockwise: Bool = true) {
        let elapsed = Date().timeIntervalSince(animationStart) + phaseOffset

        // The wave runs along the SAME arc as the static ring fill: from
        // `startAngle` for `percent` of `maxSweep`. New beats emerge at the
        // leading edge (the percent endpoint, where the orb used to live)
        // and scroll back toward the start.
        let percentClamped = max(0.0, min(100.0, percent)) / 100.0
        guard percentClamped > 0.005 else { return }  // nothing to draw at ~0%

        let cycle: TimeInterval = 1.2
        let arcSpan: CGFloat = CGFloat(percentClamped) * maxSweep
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
            let frac = Double(i) / Double(pointsCount)        // 0 (oldest, at startAngle) .. 1 (newest, at percent endpoint)
            let pointAngle = clockwise
                ? startAngle - arcSpan * CGFloat(frac)
                : startAngle + arcSpan * CGFloat(frac)
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
        guard let resetsAt else { return "—" }
        let total = max(0, Int(resetsAt.timeIntervalSinceNow))
        if total == 0 { return "Resetting" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: HaloWindow?
    private var statusItem: NSStatusItem?
    private weak var haloView: HaloView?
    private var pulseModeItem: NSMenuItem?
    private var stackedFormationItem: NSMenuItem?
    private var splitFormationItem: NSMenuItem?
    private var ringModeItem: NSMenuItem?
    private var usedMetricItem: NSMenuItem?
    private var leftMetricItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching args=\(CommandLine.arguments)")
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        createWindow()
        // File-backend tracking: poll Codex's own state file for sprite rect
        // and OAuth-fetch usage from the upstream API every minute. No
        // Accessibility permission, no calibration, no helper server needed.
        CodexStateReader.shared.start { [weak self] spriteRect in
            self?.haloView?.applySpriteRect(spriteRect)
        }
        CodexUsageReader.shared.start { [weak self] session, weekly, resetsAt in
            self?.haloView?.applyUsage(session: session, weekly: weekly, resetsAt: resetsAt)
        }
    }

    private func createWindow() {
        // Initial frame is irrelevant — the file reader repositions the halo
        // onto the pet sprite within 100ms of launch.
        let frame = Self.defaultWindowFrame()
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

        let stackedItem = NSMenuItem(title: "Stacked rings", action: #selector(setStackedFormation), keyEquivalent: "")
        let splitItem = NSMenuItem(title: "Split rings (week ◐ session)", action: #selector(setSplitFormation), keyEquivalent: "")
        menu.addItem(stackedItem)
        menu.addItem(splitItem)
        menu.addItem(.separator())

        let usedItem = NSMenuItem(title: "Show used", action: #selector(setUsedMetric), keyEquivalent: "")
        let leftItem = NSMenuItem(title: "Show left", action: #selector(setLeftMetric), keyEquivalent: "")
        menu.addItem(usedItem)
        menu.addItem(leftItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Session ring color…", action: #selector(pickSessionColor), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Weekly ring color…", action: #selector(pickWeeklyColor), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset colors", action: #selector(resetColors), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Show meter", action: #selector(showHalo), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        pulseModeItem = pulseItem
        ringModeItem = ringItem
        stackedFormationItem = stackedItem
        splitFormationItem = splitItem
        usedMetricItem = usedItem
        leftMetricItem = leftItem
        updateMenuState()
    }

    @objc private func showHalo() {
        window?.orderFrontRegardless()
    }


    // Color customization. NSColorPanel is shared app-wide; we route its color
    // changes to either the session or weekly key based on which menu item the
    // user clicked last. NSApp.activate brings the (LSUIElement) accessory app
    // forward so the panel actually accepts input.
    private var colorPickTarget: String?

    @objc private func pickSessionColor() {
        presentColorPanel(targetKey: "sessionColor", current: HaloView.sessionColor())
    }

    @objc private func pickWeeklyColor() {
        presentColorPanel(targetKey: "weeklyColor", current: HaloView.weeklyColor())
    }

    private func presentColorPanel(targetKey: String, current: NSColor) {
        colorPickTarget = targetKey
        let panel = NSColorPanel.shared
        panel.color = current
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.showsAlpha = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func colorPicked(_ sender: NSColorPanel) {
        guard let key = colorPickTarget else { return }
        HaloView.saveColor(sender.color, forKey: key)
        haloView?.reloadSettings()
    }

    @objc private func resetColors() {
        UserDefaults.standard.removeObject(forKey: "sessionColor")
        UserDefaults.standard.removeObject(forKey: "weeklyColor")
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

    @objc private func setStackedFormation() {
        UserDefaults.standard.set(Formation.stacked.rawValue, forKey: "formation")
        updateSettings()
    }

    @objc private func setSplitFormation() {
        UserDefaults.standard.set(Formation.split.rawValue, forKey: "formation")
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
        let formation = Formation(rawValue: UserDefaults.standard.string(forKey: "formation") ?? "") ?? .stacked
        pulseModeItem?.state = mode == .pulse ? .on : .off
        ringModeItem?.state = mode == .ring ? .on : .off
        usedMetricItem?.state = metric == .used ? .on : .off
        leftMetricItem?.state = metric == .left ? .on : .off
        stackedFormationItem?.state = formation == .stacked ? .on : .off
        splitFormationItem?.state = formation == .split ? .on : .off
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
        // Pure-black strokes paired with isTemplate = true so macOS auto-tints
        // the icon: white in dark menu bar, black in light menu bar, and
        // appropriate inverted color when the menu is highlighted.
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(2)
        context.addArc(center: CGPoint(x: 10, y: 9), radius: 6.5,
                       startAngle: CGFloat.pi / 2,
                       endAngle: CGFloat.pi / 2 - CGFloat.pi * 1.45,
                       clockwise: true)
        context.strokePath()
        context.setLineWidth(1.7)
        context.addArc(center: CGPoint(x: 10, y: 9), radius: 4.0,
                       startAngle: CGFloat.pi / 2,
                       endAngle: CGFloat.pi / 2 - CGFloat.pi * 1.0,
                       clockwise: true)
        context.strokePath()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
