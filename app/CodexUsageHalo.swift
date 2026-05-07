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
private let claudeUsagePollInterval: TimeInterval = 5 * 60
private let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"  // OpenAI's public Codex client id
private let usageEndpoint = "https://chatgpt.com/backend-api/wham/usage"
private let refreshEndpoint = "https://auth.openai.com/oauth/token"
private let claudeUsageEndpoint = "https://api.anthropic.com/api/oauth/usage"
private let claudePromoClockEndpoint = "https://promoclock.co/api/status"
private let claudeOAuthBetaHeader = "oauth-2025-04-20"
private let claudeCredentialService = "Claude Code-credentials"
private let fallbackClaudeCodeUserAgent = "claude-code/2.1.128"
private let claudeRefreshEndpoint = "https://platform.claude.com/v1/oauth/token"
private let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let claudeOAuthScopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
private let claudeRefreshBuffer: TimeInterval = 5 * 60

private func appSupportPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.rainsday.codex-pet-meter")
        .path
}

private func legacyOpenUsageCachePath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.sunstory.openusage/usage-api-cache.json")
        .path
}

private func codexHomePath() -> String {
    if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envHome.isEmpty {
        return envHome
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
}

private func claudeConfigDirPath() -> String {
    if let envHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !envHome.isEmpty {
        return envHome
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
}

private func claudeCodeUserAgent() -> String {
    let versionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path) else {
        return fallbackClaudeCodeUserAgent
    }
    let versions = names.filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
    guard let latest = versions.max(by: compareVersionStrings) else {
        return fallbackClaudeCodeUserAgent
    }
    return "claude-code/\(latest)"
}

private func compareVersionStrings(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.split(separator: ".").compactMap { Int($0) }
    let right = rhs.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(left.count, right.count) {
        let a = i < left.count ? left[i] : 0
        let b = i < right.count ? right[i] : 0
        if a != b { return a < b }
    }
    return false
}

private func cgFloat(_ value: Any?) -> CGFloat? {
    if let n = value as? NSNumber { return CGFloat(truncating: n) }
    if let d = value as? Double { return CGFloat(d) }
    if let i = value as? Int { return CGFloat(i) }
    return nil
}

enum UsageSource: String {
    case codex
    case claude
    case combined
}

struct ProviderUsage {
    let id: String
    let label: String
    let session: Double
    let weekly: Double
    let sessionResetsAt: Date?
    let weeklyResetsAt: Date?
    let plan: String?
    let peakStatus: String?
}

struct UsageSnapshot {
    let session: Double
    let weekly: Double
    let resetsAt: Date?
    let providerLabel: String
    let plan: String?
    let providers: [ProviderUsage]
}

private enum ClaudeCredentialSource {
    case env
    case file
    case keychain
}

private struct ClaudeCredentialBundle {
    var oauth: [String: Any]
    var fullData: [String: Any]
    let source: ClaudeCredentialSource
    let serviceName: String?
    let inferenceOnly: Bool
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
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: petPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()  // immediate first read
    }

    func refreshNow() {
        lastRect = nil
        lastWasOpen = nil
        poll()
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

// Fetches usage data directly from Codex and Claude's local OAuth credentials.
// Codex reads ~/.codex/auth.json and refreshes on 401/403. Claude reads the
// standard ~/.claude/.credentials.json file or the Claude Code macOS Keychain
// item, then calls Anthropic's OAuth usage endpoint with provider-specific
// throttling and backoff.
// Result is fanned out via callback.
final class CodexUsageReader {
    static let shared = CodexUsageReader()

    var onUsageUpdate: ((UsageSnapshot) -> Void)?

    private let authFilePath: String
    private let claudeCredentialsPath: String
    private let usageCachePath: String
    private let legacyUsageCachePath: String
    private var timer: Timer?
    private let snapshotLock = NSLock()
    private var lastCodexSnapshot: (snapshot: UsageSnapshot, date: Date)?
    private var lastClaudeSnapshot: (snapshot: UsageSnapshot, date: Date)?
    private let providerSnapshotStaleAfter: TimeInterval = 2 * 60 * 60
    private let defaultClaudeUsageBackoff: TimeInterval = 5 * 60
    private let defaultClaudeRefreshBackoff: TimeInterval = 60 * 60
    private let maxClaudeRefreshBackoff: TimeInterval = 4 * 60 * 60
    private let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoWithoutFractionalSeconds = ISO8601DateFormatter()

    init() {
        authFilePath = codexHomePath() + "/auth.json"
        claudeCredentialsPath = claudeConfigDirPath() + "/.credentials.json"
        usageCachePath = appSupportPath() + "/usage-cache.json"
        legacyUsageCachePath = legacyOpenUsageCachePath()
        loadPersistedSnapshots()
    }

    func start(onUsageUpdate: @escaping (UsageSnapshot) -> Void) {
        self.onUsageUpdate = onUsageUpdate
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: usagePollInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        fetch()  // immediate first read
    }

    func fetchNow() {
        fetch()
    }

    private func fetch() {
        let source = currentUsageSource()

        switch source {
        case .codex:
            fetchCodexUsage { [weak self] snapshot in
                guard let self, let snapshot else { return }
                self.remember(snapshot)
                self.emit(snapshot)
            }
        case .claude:
            fetchClaudeUsage { [weak self] snapshot in
                guard let self, let snapshot else { return }
                self.remember(snapshot)
                self.emit(snapshot)
            }
        case .combined:
            let group = DispatchGroup()
            let lock = NSLock()
            var codex: UsageSnapshot?
            var claude: UsageSnapshot?

            group.enter()
            fetchCodexUsage { snapshot in
                lock.lock()
                codex = snapshot
                lock.unlock()
                group.leave()
            }

            group.enter()
            fetchClaudeUsage { snapshot in
                lock.lock()
                claude = snapshot
                lock.unlock()
                group.leave()
            }

            group.notify(queue: .global(qos: .utility)) { [weak self] in
                guard let self else { return }
                if let codex { self.remember(codex) }
                if let claude { self.remember(claude) }
                let effectiveCodex = codex ?? self.latestCachedSnapshot(id: "codex")
                let effectiveClaude = claude ?? self.latestCachedSnapshot(id: "claude")
                guard let snapshot = self.combine(codex: effectiveCodex, claude: effectiveClaude) else {
                    debugLog("usage combined skipped partial codex=\(codex != nil) claude=\(claude != nil)")
                    return
                }
                self.emit(snapshot)
            }
        }
    }

    private func currentUsageSource() -> UsageSource {
        UsageSource(rawValue: UserDefaults.standard.string(forKey: "usageSource") ?? "") ?? .combined
    }

    private func remember(_ snapshot: UsageSnapshot) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let now = Date()
        switch snapshot.providers.first?.id {
        case "codex":
            lastCodexSnapshot = (snapshot, now)
            persist(snapshot)
        case "claude":
            lastClaudeSnapshot = (snapshot, now)
            persist(snapshot)
        default:
            for provider in snapshot.providers {
                let providerSnapshot = UsageSnapshot(
                    session: provider.session,
                    weekly: provider.weekly,
                    resetsAt: provider.sessionResetsAt,
                    providerLabel: provider.label,
                    plan: provider.plan,
                    providers: [provider]
                )
                if provider.id == "codex" {
                    lastCodexSnapshot = (providerSnapshot, now)
                    persist(providerSnapshot)
                }
                if provider.id == "claude" {
                    lastClaudeSnapshot = (providerSnapshot, now)
                    persist(providerSnapshot)
                }
            }
        }
    }

    private func latestCachedSnapshot(id: String) -> UsageSnapshot? {
        snapshotLock.lock()
        let entry = id == "codex" ? lastCodexSnapshot : lastClaudeSnapshot
        let snapshot = entry.flatMap {
            Date().timeIntervalSince($0.date) <= providerSnapshotStaleAfter ? $0.snapshot : nil
        }
        snapshotLock.unlock()
        if let snapshot {
            return expirePastWindows(in: snapshot)
        }

        if let legacy = readLegacyOpenUsageSnapshots()[id] {
            let normalized = expirePastWindows(in: legacy)
            remember(normalized)
            return normalized
        }
        return nil
    }

    private func expirePastWindows(in snapshot: UsageSnapshot) -> UsageSnapshot {
        let now = Date()
        let providers = snapshot.providers.map { provider in
            ProviderUsage(
                id: provider.id,
                label: provider.label,
                session: provider.sessionResetsAt.map { $0 <= now } == true ? 0 : provider.session,
                weekly: provider.weeklyResetsAt.map { $0 <= now } == true ? 0 : provider.weekly,
                sessionResetsAt: provider.sessionResetsAt.map { $0 <= now } == true ? nil : provider.sessionResetsAt,
                weeklyResetsAt: provider.weeklyResetsAt.map { $0 <= now } == true ? nil : provider.weeklyResetsAt,
                plan: provider.plan,
                peakStatus: provider.peakStatus
            )
        }
        let session = providers.map(\.session).max() ?? 0
        let weekly = providers.map(\.weekly).max() ?? 0
        let providerLabel = providers.count == 1 ? (providers.first?.label ?? snapshot.providerLabel) : snapshot.providerLabel
        let reset = providers.max { $0.session < $1.session }?.sessionResetsAt
        return UsageSnapshot(
            session: session,
            weekly: weekly,
            resetsAt: reset,
            providerLabel: providerLabel,
            plan: snapshot.plan,
            providers: providers
        )
    }

    private func loadPersistedSnapshots() {
        let loaded = readPersistedSnapshots(from: usageCachePath)
        let legacy = loaded.isEmpty ? readLegacyOpenUsageSnapshots() : [:]
        let snapshots = loaded.isEmpty ? legacy : loaded
        guard !snapshots.isEmpty else { return }
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let now = Date()
        if let codex = snapshots["codex"] { lastCodexSnapshot = (codex, now) }
        if let claude = snapshots["claude"] { lastClaudeSnapshot = (claude, now) }
        if loaded.isEmpty {
            snapshots.values.forEach(persist)
        }
    }

    private func readPersistedSnapshots(from path: String) -> [String: UsageSnapshot] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any] else {
            return [:]
        }
        var snapshots: [String: UsageSnapshot] = [:]
        for (id, value) in providers {
            guard let provider = value as? [String: Any],
                  let label = provider["label"] as? String else {
                continue
            }
            let session = clamp(number(provider["session"]) ?? 0)
            let weekly = clamp(number(provider["weekly"]) ?? 0)
            let sessionResetsAt = (provider["sessionResetsAt"] as? String).flatMap(parseIsoDate)
            let weeklyResetsAt = (provider["weeklyResetsAt"] as? String).flatMap(parseIsoDate)
            let usage = ProviderUsage(
                id: id,
                label: label,
                session: session,
                weekly: weekly,
                sessionResetsAt: sessionResetsAt,
                weeklyResetsAt: weeklyResetsAt,
                plan: provider["plan"] as? String,
                peakStatus: provider["peakStatus"] as? String
            )
            snapshots[id] = UsageSnapshot(
                session: session,
                weekly: weekly,
                resetsAt: sessionResetsAt,
                providerLabel: label,
                plan: usage.plan,
                providers: [usage]
            )
        }
        return snapshots
    }

    private func readLegacyOpenUsageSnapshots() -> [String: UsageSnapshot] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: legacyUsageCachePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = root["snapshots"] as? [String: Any] else {
            return [:]
        }
        return [
            "codex": parseLegacyOpenUsageProvider(snapshots["codex"] as? [String: Any]),
            "claude": parseLegacyOpenUsageProvider(snapshots["claude"] as? [String: Any])
        ].compactMapValues { $0 }
    }

    private func parseLegacyOpenUsageProvider(_ provider: [String: Any]?) -> UsageSnapshot? {
        guard let provider,
              let lines = provider["lines"] as? [[String: Any]] else {
            return nil
        }
        let session = legacyProgressLine(named: "session", in: lines)
        let weekly = legacyProgressLine(named: "weekly", in: lines)
        guard session.percent != nil || weekly.percent != nil else { return nil }
        let label = provider["displayName"] as? String ?? provider["providerId"] as? String ?? "Usage"
        let id = provider["providerId"] as? String ?? label.lowercased()
        let usage = ProviderUsage(
            id: id,
            label: label,
            session: clamp(session.percent ?? 0),
            weekly: clamp(weekly.percent ?? 0),
            sessionResetsAt: session.resetsAt,
            weeklyResetsAt: weekly.resetsAt,
            plan: provider["plan"] as? String,
            peakStatus: nil
        )
        return UsageSnapshot(
            session: usage.session,
            weekly: usage.weekly,
            resetsAt: usage.sessionResetsAt,
            providerLabel: label,
            plan: usage.plan,
            providers: [usage]
        )
    }

    private func legacyProgressLine(named target: String, in lines: [[String: Any]]) -> (percent: Double?, resetsAt: Date?) {
        for line in lines {
            guard (line["type"] as? String) == "progress",
                  let label = (line["label"] as? String)?.lowercased(),
                  label == target else {
                continue
            }
            let used = number(line["used"])
            let limit = number(line["limit"])
            let percent: Double?
            if let used, let limit, limit > 0 {
                percent = used / limit * 100
            } else {
                percent = used
            }
            return (percent, (line["resetsAt"] as? String).flatMap(parseIsoDate))
        }
        return (nil, nil)
    }

    private func persist(_ snapshot: UsageSnapshot) {
        guard let provider = snapshot.providers.first else { return }
        let url = URL(fileURLWithPath: usageCachePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }
        var providers = root["providers"] as? [String: Any] ?? [:]
        var encodedProvider: [String: Any] = [
            "label": provider.label,
            "session": provider.session,
            "weekly": provider.weekly,
            "cachedAt": isoWithFractionalSeconds.string(from: Date())
        ]
        if let sessionResetsAt = provider.sessionResetsAt {
            encodedProvider["sessionResetsAt"] = isoWithFractionalSeconds.string(from: sessionResetsAt)
        }
        if let weeklyResetsAt = provider.weeklyResetsAt {
            encodedProvider["weeklyResetsAt"] = isoWithFractionalSeconds.string(from: weeklyResetsAt)
        }
        if let plan = provider.plan {
            encodedProvider["plan"] = plan
        }
        if let peakStatus = provider.peakStatus {
            encodedProvider["peakStatus"] = peakStatus
        }
        providers[provider.id] = encodedProvider
        root["version"] = 1
        root["providers"] = providers
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func readAuth() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func fetchCodexUsage(completion: @escaping (UsageSnapshot?) -> Void) {
        guard let auth = readAuth(),
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            completion(nil)
            return
        }
        request(accessToken: accessToken, accountId: tokens["account_id"] as? String, retry: true, completion: completion)
    }

    private func request(accessToken: String, accountId: String?, retry: Bool, completion: @escaping (UsageSnapshot?) -> Void) {
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
                self.refreshTokenAndRetry(completion: completion)
                return
            }
            guard status >= 200, status < 300, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(self.parseCodexUsage(json))
        }.resume()
    }

    private func refreshTokenAndRetry(completion: @escaping (UsageSnapshot?) -> Void) {
        guard var auth = readAuth(),
              var tokens = auth["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String,
              let url = URL(string: refreshEndpoint) else {
            completion(nil)
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
                completion(nil)
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
            self.request(accessToken: newAccess, accountId: tokens["account_id"] as? String, retry: false, completion: completion)
        }.resume()
    }

    private func fetchClaudeUsage(completion: @escaping (UsageSnapshot?) -> Void) {
        if let backoffUntil = claudeBackoffUntil(), Date() < backoffUntil {
            debugLog("usage claude usage skipped reason=backoff seconds=\(Int(backoffUntil.timeIntervalSinceNow))")
            completion(nil)
            return
        }
        if let lastRequestAt = claudeLastRequestAt(),
           Date().timeIntervalSince(lastRequestAt) < claudeUsagePollInterval {
            completion(nil)
            return
        }
        guard let credentials = readClaudeCredentials() else {
            completion(nil)
            return
        }

        let tokenIsExpired = claudeAccessTokenIsExpired(credentials.oauth)
        let tokenNeedsRefresh = claudeAccessTokenNeedsRefresh(credentials.oauth)
        if tokenNeedsRefresh {
            if credentials.inferenceOnly {
                if tokenIsExpired {
                    debugLog("usage claude usage skipped reason=expired-env-token")
                    completion(nil)
                    return
                }
            } else if let refreshBackoffUntil = claudeRefreshBackoffUntil(), Date() < refreshBackoffUntil {
                if tokenIsExpired {
                    debugLog("usage claude refresh skipped reason=backoff expired=true seconds=\(Int(refreshBackoffUntil.timeIntervalSinceNow))")
                    completion(nil)
                    return
                }
                debugLog("usage claude refresh skipped reason=backoff expired=false seconds=\(Int(refreshBackoffUntil.timeIntervalSinceNow))")
            } else {
                refreshClaudeToken(credentials) { [weak self] refreshed in
                    guard let self else { return }
                    if let refreshed {
                        self.requestClaudeUsage(credentials: refreshed, completion: completion)
                        return
                    }
                    if tokenIsExpired {
                        debugLog("usage claude usage skipped reason=expired-token refresh=false")
                        completion(nil)
                        return
                    }
                    self.requestClaudeUsage(credentials: credentials, completion: completion)
                }
                return
            }
        } else {
            clearClaudeRefreshBackoff()
        }

        if tokenIsExpired {
            debugLog("usage claude usage skipped reason=expired-token")
            completion(nil)
            return
        }

        requestClaudeUsage(credentials: credentials, completion: completion)
    }

    private func requestClaudeUsage(credentials: ClaudeCredentialBundle, retryRefresh: Bool = true, completion: @escaping (UsageSnapshot?) -> Void) {
        guard let accessToken = credentials.oauth["accessToken"] as? String ?? credentials.oauth["access_token"] as? String,
              let url = URL(string: claudeUsageEndpoint) else {
            completion(nil)
            return
        }

        saveClaudeLastRequestAt(Date())
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(claudeOAuthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(claudeCodeUserAgent(), forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0
            if status == 429 {
                self.setClaudeBackoff(from: httpResponse)
                completion(nil)
                return
            }
            if (status == 401 || status == 403), retryRefresh, !credentials.inferenceOnly {
                if let refreshBackoffUntil = self.claudeRefreshBackoffUntil(), Date() < refreshBackoffUntil {
                    debugLog("usage claude refresh skipped reason=backoff after-auth-failure seconds=\(Int(refreshBackoffUntil.timeIntervalSinceNow))")
                    completion(nil)
                    return
                }
                self.refreshClaudeToken(credentials) { refreshed in
                    guard let refreshed else {
                        completion(nil)
                        return
                    }
                    self.requestClaudeUsage(credentials: refreshed, retryRefresh: false, completion: completion)
                }
                return
            }
            guard status >= 200, status < 300, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if status != 0 {
                    debugLog("usage claude usage failed status=\(status)")
                }
                completion(nil)
                return
            }
            self.clearClaudeBackoff()
            self.fetchClaudePeakStatus { peakStatus in
                completion(self.parseClaudeUsage(json, oauth: credentials.oauth, peakStatus: peakStatus))
            }
        }.resume()
    }

    private func claudeAccessTokenNeedsRefresh(_ oauth: [String: Any]) -> Bool {
        guard let expiresAt = claudeAccessTokenExpiryDate(oauth) else { return false }
        return expiresAt.timeIntervalSinceNow <= claudeRefreshBuffer
    }

    private func claudeAccessTokenIsExpired(_ oauth: [String: Any]) -> Bool {
        guard let expiresAt = claudeAccessTokenExpiryDate(oauth) else { return false }
        return expiresAt.timeIntervalSinceNow <= 0
    }

    private func claudeAccessTokenExpiryDate(_ oauth: [String: Any]) -> Date? {
        guard let expiresAt = number(oauth["expiresAt"]) else { return nil }
        let seconds = expiresAt > 10_000_000_000 ? expiresAt / 1000 : expiresAt
        return Date(timeIntervalSince1970: seconds)
    }

    private func refreshClaudeToken(_ credentials: ClaudeCredentialBundle, completion: @escaping (ClaudeCredentialBundle?) -> Void) {
        guard !credentials.inferenceOnly,
              let refreshToken = credentials.oauth["refreshToken"] as? String,
              let url = URL(string: claudeRefreshEndpoint) else {
            completion(nil)
            return
        }

        saveClaudeLastRequestAt(Date())
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeOAuthClientID,
            "scope": claudeOAuthScopes,
        ])

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0
            guard status >= 200, status < 300,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                if status == 429 {
                    self.setClaudeRefreshBackoff(from: httpResponse)
                }
                debugLog("usage claude refresh failed status=\(status)")
                completion(nil)
                return
            }

            var refreshed = credentials
            refreshed.oauth["accessToken"] = newAccessToken
            if let newRefreshToken = json["refresh_token"] as? String {
                refreshed.oauth["refreshToken"] = newRefreshToken
            }
            if let expiresIn = self.number(json["expires_in"]) {
                refreshed.oauth["expiresAt"] = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
            }
            refreshed.fullData["claudeAiOauth"] = refreshed.oauth

            if self.persistClaudeCredentials(refreshed) {
                debugLog("usage claude refresh succeeded source=\(refreshed.source)")
            } else {
                debugLog("usage claude refresh succeeded persist=false")
            }
            self.clearClaudeRefreshBackoff()
            completion(refreshed)
        }.resume()
    }

    private func setClaudeRefreshBackoff(from response: HTTPURLResponse?) {
        let retryAfter = response?.value(forHTTPHeaderField: "Retry-After").flatMap(retryAfterSeconds)
        let failureCount = UserDefaults.standard.integer(forKey: "claudeRefreshFailureCount") + 1
        let exponent = min(failureCount - 1, 12)
        let exponential = min(maxClaudeRefreshBackoff, defaultClaudeRefreshBackoff * pow(2, Double(exponent)))
        let interval = retryAfter ?? exponential
        let seconds = max(60, interval)
        UserDefaults.standard.set(failureCount, forKey: "claudeRefreshFailureCount")
        UserDefaults.standard.set(Date(timeIntervalSinceNow: seconds), forKey: "claudeRefreshBackoffUntil")
        debugLog("usage claude refresh backoff seconds=\(Int(seconds)) status=429 failures=\(failureCount)")
    }

    private func setClaudeBackoff(from response: HTTPURLResponse?) {
        let retryAfter = response?.value(forHTTPHeaderField: "Retry-After").flatMap(retryAfterSeconds)
        let interval = retryAfter ?? defaultClaudeUsageBackoff
        UserDefaults.standard.set(Date(timeIntervalSinceNow: max(60, interval)), forKey: "claudeBackoffUntil")
        debugLog("usage claude backoff seconds=\(Int(max(60, interval))) status=429")
    }

    private func claudeRefreshBackoffUntil() -> Date? {
        UserDefaults.standard.object(forKey: "claudeRefreshBackoffUntil") as? Date
    }

    private func clearClaudeRefreshBackoff() {
        UserDefaults.standard.removeObject(forKey: "claudeRefreshBackoffUntil")
        UserDefaults.standard.removeObject(forKey: "claudeRefreshFailureCount")
    }

    private func retryAfterSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds >= 0 {
            return seconds
        }
        if let date = HTTPDateFormatter.shared.date(from: trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func claudeLastRequestAt() -> Date? {
        UserDefaults.standard.object(forKey: "claudeLastRequestAt") as? Date
    }

    private func saveClaudeLastRequestAt(_ date: Date) {
        UserDefaults.standard.set(date, forKey: "claudeLastRequestAt")
    }

    private func claudeBackoffUntil() -> Date? {
        UserDefaults.standard.object(forKey: "claudeBackoffUntil") as? Date
    }

    private func clearClaudeBackoff() {
        UserDefaults.standard.removeObject(forKey: "claudeBackoffUntil")
    }

    private func fetchClaudePeakStatus(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: claudePromoClockEndpoint) else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 2.5)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status >= 200, status < 300,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(self.parseClaudePeakStatus(json))
        }.resume()
    }

    private func parseClaudePeakStatus(_ json: [String: Any]) -> String? {
        if (json["isPeak"] as? Bool) == true { return "Peak" }
        if (json["isOffPeak"] as? Bool) == true || (json["isWeekend"] as? Bool) == true { return "Off-Peak" }
        let status = (json["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if status == "peak" { return "Peak" }
        if status == "off_peak" || status == "off-peak" || status == "weekend" { return "Off-Peak" }
        return nil
    }

    private func readClaudeCredentials() -> ClaudeCredentialBundle? {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            let oauth = ["accessToken": token]
            return ClaudeCredentialBundle(
                oauth: oauth,
                fullData: ["claudeAiOauth": oauth],
                source: .env,
                serviceName: nil,
                inferenceOnly: true
            )
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeCredentialsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = claudeOauth(from: json) {
            return ClaudeCredentialBundle(
                oauth: oauth,
                fullData: json,
                source: .file,
                serviceName: nil,
                inferenceOnly: false
            )
        }
        return readClaudeCredentialsFromKeychain()
    }

    private func readClaudeCredentialsFromKeychain() -> ClaudeCredentialBundle? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", claudeCredentialService, "-w"]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = claudeOauth(from: json) else {
            return nil
        }
        return ClaudeCredentialBundle(
            oauth: oauth,
            fullData: json,
            source: .keychain,
            serviceName: claudeCredentialService,
            inferenceOnly: false
        )
    }

    private func claudeOauth(from credentials: [String: Any]) -> [String: Any]? {
        if let oauth = credentials["claudeAiOauth"] as? [String: Any] { return oauth }
        if credentials["accessToken"] != nil || credentials["access_token"] != nil { return credentials }
        return nil
    }

    private func persistClaudeCredentials(_ credentials: ClaudeCredentialBundle) -> Bool {
        guard !credentials.inferenceOnly,
              let data = try? JSONSerialization.data(withJSONObject: credentials.fullData, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }

        switch credentials.source {
        case .env:
            return false
        case .file:
            return (try? text.write(to: URL(fileURLWithPath: claudeCredentialsPath), atomically: true, encoding: .utf8)) != nil
        case .keychain:
            guard let serviceName = credentials.serviceName else { return false }
            return writeClaudeCredentialsToKeychain(serviceName: serviceName, text: text)
        }
    }

    private func writeClaudeCredentialsToKeychain(serviceName: String, text: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-U",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w", text,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func parseClaudeUsage(_ json: [String: Any], oauth: [String: Any], peakStatus: String?) -> UsageSnapshot? {
        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]
        let fallbackWeekly = [
            json["seven_day_sonnet"] as? [String: Any],
            json["seven_day_opus"] as? [String: Any]
        ].compactMap { $0 }.max { (number($0["utilization"]) ?? 0) < (number($1["utilization"]) ?? 0) }
        let weeklyBucket = sevenDay ?? fallbackWeekly

        let session = clamp(number(fiveHour?["utilization"]) ?? 0)
        let weekly = clamp(number(weeklyBucket?["utilization"]) ?? 0)
        guard fiveHour != nil || weeklyBucket != nil else { return nil }

        let plan = [oauth["subscriptionType"] as? String, oauth["rateLimitTier"] as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        let providerUsage = ProviderUsage(
            id: "claude",
            label: "Claude",
            session: session,
            weekly: weekly,
            sessionResetsAt: parseClaudeReset(fiveHour),
            weeklyResetsAt: parseClaudeReset(weeklyBucket),
            plan: plan.isEmpty ? nil : plan,
            peakStatus: peakStatus
        )
        return UsageSnapshot(
            session: providerUsage.session,
            weekly: providerUsage.weekly,
            resetsAt: providerUsage.sessionResetsAt,
            providerLabel: "Claude",
            plan: providerUsage.plan,
            providers: [providerUsage]
        )
    }

    private func parseClaudeReset(_ bucket: [String: Any]?) -> Date? {
        (bucket?["resets_at"] as? String).flatMap(parseIsoDate)
    }

    private func combine(codex: UsageSnapshot?, claude: UsageSnapshot?) -> UsageSnapshot? {
        guard codex != nil || claude != nil else { return nil }
        let sessionWinner = maxSnapshot(codex, claude, keyPath: \.session)
        return UsageSnapshot(
            session: max(codex?.session ?? 0, claude?.session ?? 0),
            weekly: max(codex?.weekly ?? 0, claude?.weekly ?? 0),
            resetsAt: sessionWinner?.resetsAt,
            providerLabel: "Combined",
            plan: [codex?.providerLabel, claude?.providerLabel].compactMap { $0 }.joined(separator: " + "),
            providers: [codex?.providers, claude?.providers].compactMap { $0 }.flatMap { $0 }
        )
    }

    private func maxSnapshot(_ a: UsageSnapshot?, _ b: UsageSnapshot?, keyPath: KeyPath<UsageSnapshot, Double>) -> UsageSnapshot? {
        guard let a else { return b }
        guard let b else { return a }
        return a[keyPath: keyPath] >= b[keyPath: keyPath] ? a : b
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private func parseIsoDate(_ value: String) -> Date? {
        isoWithFractionalSeconds.date(from: value) ?? isoWithoutFractionalSeconds.date(from: value)
    }

    private func emit(_ snapshot: UsageSnapshot) {
        let providerDebug = snapshot.providers
            .map { "\($0.label):S\($0.session)% W\($0.weekly)% P\($0.peakStatus ?? "-")" }
            .joined(separator: ",")
        debugLog("usage source=\(snapshot.providerLabel) session=\(snapshot.session)% weekly=\(snapshot.weekly)% resetsAt=\(snapshot.resetsAt?.description ?? "nil") providers=[\(providerDebug)]")
        DispatchQueue.main.async { [weak self] in
            self?.onUsageUpdate?(snapshot)
        }
    }

    private func parseCodexUsage(_ json: [String: Any]) -> UsageSnapshot {
        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]
        let primary = rateLimit["primary_window"] as? [String: Any] ?? rateLimit["primary"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any] ?? rateLimit["secondary"] as? [String: Any]

        let session = clamp((primary?["used_percent"] as? NSNumber)?.doubleValue ?? 0)
        let weekly = clamp((secondary?["used_percent"] as? NSNumber)?.doubleValue ?? 0)
        let resetsAt = parseReset(primary)
        let provider = ProviderUsage(
            id: "codex",
            label: "Codex",
            session: session,
            weekly: weekly,
            sessionResetsAt: resetsAt,
            weeklyResetsAt: parseReset(secondary),
            plan: nil,
            peakStatus: nil
        )
        return UsageSnapshot(session: session, weekly: weekly, resetsAt: resetsAt, providerLabel: "Codex", plan: nil, providers: [provider])
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

final class HTTPDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

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

enum ResetWindow: String {
    case fiveHour
    case sevenDay
}

final class HaloView: NSView {
    private var sessionPercent: Double = 0
    private var weeklyPercent: Double = 0
    private var resetsAt: Date?
    private var providerLabel = "Codex"
    private var planLabel: String?
    private var providerUsages: [ProviderUsage] = []
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
        if isHovering && (sessionBadgeRect().contains(point) || weeklyBadgeRect().contains(point) || statusRect().contains(point) || providerDetailRect().contains(point)) {
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

        if isCombinedView {
            drawProviderHalfRings(context: context, center: center, pulseSession: displayMode == .pulse)
        } else {
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
        }

        if isHovering {
            if isCombinedView && (displayMode == .ring || displayMode == .pulse) {
                drawProviderRingHoverPanels(context: context)
            } else if isCombinedView {
                drawProviderDetailPanel(context: context)
            } else {
                drawBadge(text: "\(Int(round(session)))%", rect: sessionBadgeRect(), color: sessionColor.withAlphaComponent(0.48))
                drawBadge(text: "\(Int(round(weekly)))%", rect: weeklyBadgeRect(), color: weeklyColor.withAlphaComponent(0.48))
            }
            if !(isCombinedView && (displayMode == .ring || displayMode == .pulse)) {
                drawBadge(text: resetLabel(), rect: statusRect(), color: NSColor(white: 1, alpha: 0.22), fontSize: 11)
            }
        }
    }

    static let defaultSessionColor = NSColor(calibratedRed: 0.30, green: 0.91, blue: 0.82, alpha: 1)
    static let defaultWeeklyColor  = NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.31, alpha: 1)
    static let warningCodexColor = NSColor(calibratedRed: 0.24, green: 0.96, blue: 0.82, alpha: 1)
    static let warningClaudeColor = NSColor(calibratedRed: 0.68, green: 0.42, blue: 1.00, alpha: 1)
    static let warningWeeklyColor = NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.20, alpha: 1)

    static func sessionColor() -> NSColor {
        loadColor(forKey: "sessionColor", default: defaultSessionColor)
    }
    static func weeklyColor() -> NSColor {
        loadColor(forKey: "weeklyColor", default: defaultWeeklyColor)
    }
    static func codexRingColor() -> NSColor {
        loadColor(forKey: "codexRingColor", default: warningCodexColor)
    }
    static func claudeRingColor() -> NSColor {
        loadColor(forKey: "claudeRingColor", default: warningClaudeColor)
    }
    static func codexWeeklyColor() -> NSColor {
        loadColor(forKey: "codexWeeklyColor", default: defaultWeeklyColor)
    }
    static func claudeWeeklyColor() -> NSColor {
        loadColor(forKey: "claudeWeeklyColor", default: defaultWeeklyColor)
    }
    static func codexResetColor() -> NSColor {
        loadColor(forKey: "codexResetColor", default: codexRingColor())
    }
    static func claudeResetColor() -> NSColor {
        loadColor(forKey: "claudeResetColor", default: claudeRingColor())
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
    func applyUsage(_ snapshot: UsageSnapshot) {
        sessionPercent = snapshot.session
        weeklyPercent = snapshot.weekly
        resetsAt = snapshot.resetsAt
        providerLabel = snapshot.providerLabel
        planLabel = snapshot.plan
        providerUsages = snapshot.providers
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

    private var resetWindow: ResetWindow {
        ResetWindow(rawValue: UserDefaults.standard.string(forKey: "resetWindow") ?? "") ?? .fiveHour
    }

    private var isCombinedView: Bool {
        (UsageSource(rawValue: UserDefaults.standard.string(forKey: "usageSource") ?? "") ?? .combined) == .combined
            && providerUsages.count > 1
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
        let alpha = lowPercentFadeAlpha(percent)
        let strokeColor = color.withAlphaComponent(alpha)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(width)
        context.setShadow(offset: .zero, blur: 10, color: color.withAlphaComponent(0.58 * alpha).cgColor)
        context.setStrokeColor(strokeColor.cgColor)
        let sweep = maxSweep * CGFloat(percent / 100)
        let end = clockwise ? startAngle - sweep : startAngle + sweep
        context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: end, clockwise: clockwise)
        context.strokePath()
        context.restoreGState()
    }

    private func drawProviderHalfRings(context: CGContext, center: CGPoint, pulseSession: Bool) {
        let providers = orderedProviders()
        let codex = providers.first { $0.id.lowercased().hasPrefix("codex") }
        let claude = providers.first { $0.id.lowercased().hasPrefix("claude") }
        let codexSession = displayPercent(codex?.session ?? sessionPercent)
        let claudeSession = displayPercent(claude?.session ?? (isCombinedView ? 0 : sessionPercent))
        let codexWeekly = displayPercent(codex?.weekly ?? weeklyPercent)
        let claudeWeekly = displayPercent(claude?.weekly ?? (isCombinedView ? 0 : weeklyPercent))

        drawProviderHalfRing(
            context: context,
            center: center,
            side: .left,
            session: codexSession,
            weekly: codexWeekly,
            sessionColor: Self.codexRingColor(),
            weeklyColor: Self.codexWeeklyColor(),
            resetColor: Self.codexResetColor(),
            resetsAt: codex.flatMap(selectedResetDate),
            pulseSession: pulseSession,
            phaseOffset: 0
        )
        drawProviderHalfRing(
            context: context,
            center: center,
            side: .right,
            session: claudeSession,
            weekly: claudeWeekly,
            sessionColor: Self.claudeRingColor(),
            weeklyColor: Self.claudeWeeklyColor(),
            resetColor: Self.claudeResetColor(),
            resetsAt: claude.flatMap(selectedResetDate),
            pulseSession: pulseSession,
            phaseOffset: 0.48
        )
    }

    private enum RingSide {
        case left
        case right
    }

    private func drawProviderHalfRing(context: CGContext, center: CGPoint, side: RingSide, session: Double, weekly: Double, sessionColor: NSColor, weeklyColor: NSColor, resetColor: NSColor, resetsAt: Date?, pulseSession: Bool, phaseOffset: TimeInterval) {
        let radius: CGFloat = 58
        let resetRadius: CGFloat = 47
        let sessionWidth: CGFloat = 12
        let weeklyWidth: CGFloat = 6
        let gapAngle: CGFloat = .pi / 24
        let startAngle: CGFloat = side == .right ? .pi / 2 - gapAngle : .pi / 2 + gapAngle
        let maxSweep: CGFloat = .pi - gapAngle * 2
        let clockwise = side == .right

        drawRing(context: context,
                 center: center,
                 radius: radius,
                 width: sessionWidth,
                 percent: session,
                 color: sessionColor.withAlphaComponent(0.76),
                 startAngle: startAngle,
                 maxSweep: maxSweep,
                 clockwise: clockwise)
        if pulseSession {
            drawPulse(context: context,
                      center: center,
                      radius: radius,
                      percent: session,
                      color: sessionColor,
                      size: 13,
                      phaseOffset: phaseOffset,
                      startAngle: startAngle,
                      maxSweep: maxSweep,
                      clockwise: clockwise)
        }
        drawRing(context: context,
                 center: center,
                 radius: radius,
                 width: weeklyWidth,
                 percent: weekly,
                 color: weeklyColor,
                 startAngle: startAngle,
                 maxSweep: maxSweep,
                 clockwise: clockwise)
        if let resetPercent = resetPercent(resetsAt: resetsAt) {
            drawResetLine(context: context,
                          center: center,
                          radius: resetRadius,
                          percent: resetPercent,
                          color: resetColor,
                          startAngle: startAngle,
                          maxSweep: maxSweep,
                          clockwise: clockwise)
        }
    }

    private func resetPercent(resetsAt: Date?) -> Double? {
        guard let resetsAt else { return nil }
        return Self.clamp(resetsAt.timeIntervalSinceNow / resetWindowDuration * 100)
    }

    private var resetWindowDuration: TimeInterval {
        switch resetWindow {
        case .fiveHour:
            return 5 * 60 * 60
        case .sevenDay:
            return 7 * 24 * 60 * 60
        }
    }

    private func selectedResetDate(_ provider: ProviderUsage) -> Date? {
        switch resetWindow {
        case .fiveHour:
            return provider.sessionResetsAt
        case .sevenDay:
            return provider.weeklyResetsAt
        }
    }

    private func selectedOverallResetDate() -> Date? {
        guard !providerUsages.isEmpty else { return resetsAt }
        if providerUsages.count == 1 { return selectedResetDate(providerUsages[0]) }
        let winner: ProviderUsage?
        switch resetWindow {
        case .fiveHour:
            winner = providerUsages.max { $0.session < $1.session }
        case .sevenDay:
            winner = providerUsages.max { $0.weekly < $1.weekly }
        }
        return winner.flatMap(selectedResetDate)
    }

    private func drawResetLine(context: CGContext, center: CGPoint, radius: CGFloat, percent: Double, color: NSColor, startAngle: CGFloat, maxSweep: CGFloat, clockwise: Bool) {
        guard percent > 0.5 else { return }
        let alpha = lowPercentFadeAlpha(percent, stable: 0.78)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(1.4)
        context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        let sweep = maxSweep * CGFloat(percent / 100)
        let end = clockwise ? startAngle - sweep : startAngle + sweep
        context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: end, clockwise: clockwise)
        context.strokePath()
        context.restoreGState()
    }

    private func lowPercentFadeAlpha(_ percent: Double, stable: CGFloat = 1) -> CGFloat {
        guard percent < 30 else { return stable }
        let phase = (sin(Date().timeIntervalSince(animationStart) * .pi * 2 / 1.35) + 1) / 2
        return stable * (0.18 + CGFloat(phase) * 0.62)
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

    private func drawProviderChips(context: CGContext) {
        let providers = orderedProviders()
        guard providers.count >= 2 else { return }
        let chipSize = NSSize(width: 44, height: 52)
        let y = bounds.midY - chipSize.height / 2
        let left = NSRect(x: 7, y: y, width: chipSize.width, height: chipSize.height)
        let right = NSRect(x: bounds.maxX - chipSize.width - 7, y: y, width: chipSize.width, height: chipSize.height)
        drawProviderChip(providers[0], rect: left)
        drawProviderChip(providers[1], rect: right)
    }

    private func drawProviderChip(_ provider: ProviderUsage, rect: NSRect) {
        let color = providerColor(provider)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.03, alpha: 0.52).setFill()
        path.fill()
        color.withAlphaComponent(0.58).setStroke()
        path.lineWidth = 1
        path.stroke()

        let title = provider.id.lowercased().hasPrefix("claude") ? "CL" : "CX"
        drawMiniText(title, rect: NSRect(x: rect.minX, y: rect.maxY - 18, width: rect.width, height: 13),
                     color: NSColor.white.withAlphaComponent(0.92), fontSize: 10, weight: .bold)

        drawMiniBar(value: displayPercent(provider.session), rect: NSRect(x: rect.minX + 8, y: rect.minY + 24, width: rect.width - 16, height: 5), color: color)
        drawMiniBar(value: displayPercent(provider.weekly), rect: NSRect(x: rect.minX + 8, y: rect.minY + 13, width: rect.width - 16, height: 5), color: Self.weeklyColor())
        drawMiniText("\(Int(round(displayPercent(provider.session))))", rect: NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 10),
                     color: NSColor.white.withAlphaComponent(0.82), fontSize: 8, weight: .semibold)
    }

    private func drawMiniBar(value: Double, rect: NSRect, color: NSColor) {
        let bg = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.white.withAlphaComponent(0.14).setFill()
        bg.fill()
        let fillWidth = max(rect.height, rect.width * CGFloat(Self.clamp(value) / 100))
        let fill = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height),
                                xRadius: rect.height / 2,
                                yRadius: rect.height / 2)
        color.withAlphaComponent(0.95).setFill()
        fill.fill()
    }

    private func drawProviderDetailPanel(context: CGContext) {
        let providers = orderedProviders()
        guard !providers.isEmpty else { return }
        let rect = providerDetailRect()
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.025, alpha: 0.84).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let rowHeight: CGFloat = 21
        for (index, provider) in providers.prefix(2).enumerated() {
            let y = rect.maxY - 24 - CGFloat(index) * rowHeight
            let marker = NSBezierPath(ovalIn: NSRect(x: rect.minX + 10, y: y + 4, width: 7, height: 7))
            providerColor(provider).setFill()
            marker.fill()
            drawMiniText(provider.label, rect: NSRect(x: rect.minX + 22, y: y, width: 50, height: 15),
                         color: .white, fontSize: 10, weight: .semibold, alignment: .left)
            drawMiniText("S \(Int(round(displayPercent(provider.session))))%", rect: NSRect(x: rect.minX + 78, y: y, width: 44, height: 15),
                         color: providerColor(provider), fontSize: 10, weight: .bold, alignment: .left)
            if let peakStatus = provider.peakStatus, let peakColor = peakStatusColor(peakStatus) {
                drawPeakDot(center: CGPoint(x: rect.minX + 121, y: y + 7), color: peakColor)
            }
            drawMiniText("W \(Int(round(displayPercent(provider.weekly))))%", rect: NSRect(x: rect.minX + 126, y: y, width: 44, height: 15),
                         color: Self.weeklyColor(), fontSize: 10, weight: .bold, alignment: .left)
        }
    }

    private func drawProviderRingHoverPanels(context: CGContext) {
        let providers = orderedProviders()
        let codex = providers.first { $0.id.lowercased().hasPrefix("codex") }
        let claude = providers.first { $0.id.lowercased().hasPrefix("claude") }
        if let codex {
            let session = displayPercent(codex.session)
            let weekly = displayPercent(codex.weekly)
            let width = ringProviderPanelWidth(session: session, weekly: weekly, peakStatus: codex.peakStatus)
            drawRingProviderPanel(
                title: "Codex",
                session: session,
                weekly: weekly,
                peakStatus: codex.peakStatus,
                rect: NSRect(x: bounds.midX - width - 4, y: 8, width: width, height: 46),
                color: Self.codexRingColor(),
                weeklyColor: Self.codexWeeklyColor()
            )
        }
        if let claude {
            let session = displayPercent(claude.session)
            let weekly = displayPercent(claude.weekly)
            let width = ringProviderPanelWidth(session: session, weekly: weekly, peakStatus: claude.peakStatus)
            drawRingProviderPanel(
                title: "Claude",
                session: session,
                weekly: weekly,
                peakStatus: claude.peakStatus,
                rect: NSRect(x: bounds.midX + 4, y: 8, width: width, height: 46),
                color: Self.claudeRingColor(),
                weeklyColor: Self.claudeWeeklyColor()
            )
        }
    }

    private func ringProviderPanelWidth(session: Double, weekly: Double, peakStatus: String?) -> CGFloat {
        let sessionText = "\(Int(round(session)))%" as NSString
        let weeklyText = "W \(Int(round(weekly)))%" as NSString
        let sessionWidth = sessionText.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .bold),
        ]).width
        let weeklyWidth = weeklyText.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        ]).width
        return ceil(max(sessionWidth, weeklyWidth + (peakStatus == nil ? 0 : 7)) + 14)
    }

    private func drawRingProviderPanel(title: String, session: Double, weekly: Double, peakStatus: String?, rect: NSRect, color: NSColor, weeklyColor: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.02, alpha: 0.62).setFill()
        path.fill()
        color.withAlphaComponent(0.34).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawMiniText("\(Int(round(session)))%", rect: NSRect(x: rect.minX + 8, y: rect.minY + 18, width: rect.width - 12, height: 23),
                     color: color, fontSize: 19, weight: .bold, alignment: .left)
        if let peakStatus, let peakColor = peakStatusColor(peakStatus) {
            drawPeakDot(center: CGPoint(x: rect.maxX - 44, y: rect.minY + 12.5), color: peakColor)
        }
        drawMiniText("W \(Int(round(weekly)))%", rect: NSRect(x: rect.minX + 8, y: rect.minY + 7, width: rect.width - 12, height: 12),
                     color: weeklyColor.withAlphaComponent(0.92), fontSize: 10, weight: .semibold, alignment: .right)
    }

    private func drawPeakDot(center: CGPoint, color: NSColor) {
        let shadow = NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        color.withAlphaComponent(0.2).setFill()
        shadow.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
        color.withAlphaComponent(0.95).setFill()
        dot.fill()
    }

    private func peakStatusColor(_ peakStatus: String) -> NSColor? {
        if peakStatus == "Peak" {
            return NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        }
        if peakStatus == "Off-Peak" {
            return NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.46, alpha: 1)
        }
        return nil
    }

    private func drawMiniText(_ text: String, rect: NSRect, color: NSColor, fontSize: CGFloat, weight: NSFont.Weight, alignment: NSTextAlignment = .center) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        NSString(string: text).draw(in: rect, withAttributes: attrs)
    }

    private func orderedProviders() -> [ProviderUsage] {
        providerUsages.sorted { a, b in
            if a.id == "codex" { return true }
            if b.id == "codex" { return false }
            return a.label < b.label
        }
    }

    private func providerColor(_ provider: ProviderUsage) -> NSColor {
        if provider.id.lowercased().hasPrefix("claude") {
            return NSColor(calibratedRed: 0.68, green: 0.42, blue: 1.00, alpha: 1)
        }
        return Self.sessionColor()
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
        NSRect(x: bounds.midX - 66, y: 2, width: 132, height: 22)
    }

    private func providerDetailRect() -> NSRect {
        NSRect(x: bounds.midX - 88, y: bounds.maxY - 60, width: 176, height: 48)
    }

    private func resetLabel() -> String {
        let prefix = providerLabel.isEmpty ? "" : "\(providerLabel) "
        guard let resetsAt = selectedOverallResetDate() else { return prefix + "—" }
        let total = max(0, Int(resetsAt.timeIntervalSinceNow))
        if total == 0 { return prefix + "Resetting" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(prefix)\(h)h \(m)m" }
        if m > 0 { return "\(prefix)\(m)m \(s)s" }
        return "\(prefix)\(s)s"
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
    private var fiveHourResetItem: NSMenuItem?
    private var sevenDayResetItem: NSMenuItem?
    private var codexSourceItem: NSMenuItem?
    private var claudeSourceItem: NSMenuItem?
    private var combinedSourceItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching args=\(CommandLine.arguments)")
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        createWindow()
        // File-backend tracking: poll Codex's own state file for sprite rect
        // and OAuth-fetch usage from the upstream APIs. No
        // Accessibility permission, no calibration, no helper server needed.
        CodexStateReader.shared.start { [weak self] spriteRect in
            self?.haloView?.applySpriteRect(spriteRect)
        }
        CodexUsageReader.shared.start { [weak self] snapshot in
            self?.haloView?.applyUsage(snapshot)
        }
        installWakeObservers()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func installWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        debugLog("systemDidWake name=\(notification.name.rawValue)")
        CodexStateReader.shared.refreshNow()
        CodexUsageReader.shared.fetchNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            CodexStateReader.shared.refreshNow()
            CodexUsageReader.shared.fetchNow()
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
        let displayMenu = NSMenu()
        displayMenu.addItem(pulseItem)
        displayMenu.addItem(ringItem)
        let displayItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let codexItem = NSMenuItem(title: "Source: Codex", action: #selector(setCodexSource), keyEquivalent: "")
        let claudeItem = NSMenuItem(title: "Source: Claude", action: #selector(setClaudeSource), keyEquivalent: "")
        let combinedItem = NSMenuItem(title: "Source: Combined", action: #selector(setCombinedSource), keyEquivalent: "")
        let usedItem = NSMenuItem(title: "Show used", action: #selector(setUsedMetric), keyEquivalent: "")
        let leftItem = NSMenuItem(title: "Show left", action: #selector(setLeftMetric), keyEquivalent: "")
        let fiveHourResetItem = NSMenuItem(title: "Reset: 5 hour", action: #selector(setFiveHourResetWindow), keyEquivalent: "")
        let sevenDayResetItem = NSMenuItem(title: "Reset: 7 day", action: #selector(setSevenDayResetWindow), keyEquivalent: "")
        let dataMenu = NSMenu()
        dataMenu.addItem(combinedItem)
        dataMenu.addItem(codexItem)
        dataMenu.addItem(claudeItem)
        dataMenu.addItem(.separator())
        dataMenu.addItem(usedItem)
        dataMenu.addItem(leftItem)
        dataMenu.addItem(.separator())
        dataMenu.addItem(fiveHourResetItem)
        dataMenu.addItem(sevenDayResetItem)
        let dataItem = NSMenuItem(title: "Data", action: nil, keyEquivalent: "")
        dataItem.submenu = dataMenu
        menu.addItem(dataItem)
        menu.addItem(.separator())

        let colorsMenu = NSMenu()
        colorsMenu.addItem(NSMenuItem(title: "Codex session color…", action: #selector(pickCodexRingColor), keyEquivalent: ""))
        colorsMenu.addItem(NSMenuItem(title: "Codex weekly color…", action: #selector(pickCodexWeeklyColor), keyEquivalent: ""))
        colorsMenu.addItem(NSMenuItem(title: "Codex reset color…", action: #selector(pickCodexResetColor), keyEquivalent: ""))
        colorsMenu.addItem(.separator())
        colorsMenu.addItem(NSMenuItem(title: "Claude session color…", action: #selector(pickClaudeRingColor), keyEquivalent: ""))
        colorsMenu.addItem(NSMenuItem(title: "Claude weekly color…", action: #selector(pickClaudeWeeklyColor), keyEquivalent: ""))
        colorsMenu.addItem(NSMenuItem(title: "Claude reset color…", action: #selector(pickClaudeResetColor), keyEquivalent: ""))
        colorsMenu.addItem(.separator())
        colorsMenu.addItem(NSMenuItem(title: "General session color…", action: #selector(pickSessionColor), keyEquivalent: ""))
        colorsMenu.addItem(NSMenuItem(title: "General weekly color…", action: #selector(pickWeeklyColor), keyEquivalent: ""))
        colorsMenu.addItem(.separator())
        colorsMenu.addItem(NSMenuItem(title: "Reset colors", action: #selector(resetColors), keyEquivalent: ""))
        let colorsItem = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
        colorsItem.submenu = colorsMenu
        menu.addItem(colorsItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Show meter", action: #selector(showHalo), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        pulseModeItem = pulseItem
        ringModeItem = ringItem
        usedMetricItem = usedItem
        leftMetricItem = leftItem
        self.fiveHourResetItem = fiveHourResetItem
        self.sevenDayResetItem = sevenDayResetItem
        codexSourceItem = codexItem
        claudeSourceItem = claudeItem
        combinedSourceItem = combinedItem
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

    @objc private func pickCodexRingColor() {
        presentColorPanel(targetKey: "codexRingColor", current: HaloView.codexRingColor())
    }

    @objc private func pickClaudeRingColor() {
        presentColorPanel(targetKey: "claudeRingColor", current: HaloView.claudeRingColor())
    }

    @objc private func pickCodexWeeklyColor() {
        presentColorPanel(targetKey: "codexWeeklyColor", current: HaloView.codexWeeklyColor())
    }

    @objc private func pickClaudeWeeklyColor() {
        presentColorPanel(targetKey: "claudeWeeklyColor", current: HaloView.claudeWeeklyColor())
    }

    @objc private func pickCodexResetColor() {
        presentColorPanel(targetKey: "codexResetColor", current: HaloView.codexResetColor())
    }

    @objc private func pickClaudeResetColor() {
        presentColorPanel(targetKey: "claudeResetColor", current: HaloView.claudeResetColor())
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
        UserDefaults.standard.removeObject(forKey: "codexRingColor")
        UserDefaults.standard.removeObject(forKey: "claudeRingColor")
        UserDefaults.standard.removeObject(forKey: "codexWeeklyColor")
        UserDefaults.standard.removeObject(forKey: "claudeWeeklyColor")
        UserDefaults.standard.removeObject(forKey: "codexResetColor")
        UserDefaults.standard.removeObject(forKey: "claudeResetColor")
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

    @objc private func setFiveHourResetWindow() {
        UserDefaults.standard.set(ResetWindow.fiveHour.rawValue, forKey: "resetWindow")
        updateSettings()
    }

    @objc private func setSevenDayResetWindow() {
        UserDefaults.standard.set(ResetWindow.sevenDay.rawValue, forKey: "resetWindow")
        updateSettings()
    }

    @objc private func setCodexSource() {
        UserDefaults.standard.set(UsageSource.codex.rawValue, forKey: "usageSource")
        updateSettings(refreshUsage: true)
    }

    @objc private func setClaudeSource() {
        UserDefaults.standard.set(UsageSource.claude.rawValue, forKey: "usageSource")
        updateSettings(refreshUsage: true)
    }

    @objc private func setCombinedSource() {
        UserDefaults.standard.set(UsageSource.combined.rawValue, forKey: "usageSource")
        updateSettings(refreshUsage: true)
    }

    private func updateSettings(refreshUsage: Bool = false) {
        updateMenuState()
        haloView?.reloadSettings()
        if refreshUsage {
            CodexUsageReader.shared.fetchNow()
        }
    }

    private func updateMenuState() {
        let mode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .pulse
        let metric = UsageMetric(rawValue: UserDefaults.standard.string(forKey: "usageMetric") ?? "") ?? .used
        let source = UsageSource(rawValue: UserDefaults.standard.string(forKey: "usageSource") ?? "") ?? .combined
        let resetWindow = ResetWindow(rawValue: UserDefaults.standard.string(forKey: "resetWindow") ?? "") ?? .fiveHour
        pulseModeItem?.state = mode == .pulse ? .on : .off
        ringModeItem?.state = mode == .ring ? .on : .off
        usedMetricItem?.state = metric == .used ? .on : .off
        leftMetricItem?.state = metric == .left ? .on : .off
        fiveHourResetItem?.state = resetWindow == .fiveHour ? .on : .off
        sevenDayResetItem?.state = resetWindow == .sevenDay ? .on : .off
        codexSourceItem?.state = source == .codex ? .on : .off
        claudeSourceItem?.state = source == .claude ? .on : .off
        combinedSourceItem?.state = source == .combined ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func defaultWindowFrame() -> NSRect {
        let size = NSSize(width: 250, height: 220)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func statusIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "status-icon", withExtension: "png"),
           let generatedIcon = NSImage(contentsOf: url) {
            generatedIcon.size = NSSize(width: 20, height: 18)
            generatedIcon.isTemplate = false
            return generatedIcon
        }

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
