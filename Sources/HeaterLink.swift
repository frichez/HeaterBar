import Foundation
import Network
import os

private let log = Logger(subsystem: "local.heaterbar", category: "link")

/// One heater's local session: the key handshake, a status subscription the
/// heater pushes to, and encrypted commands. Work runs on the link's own queue;
/// callbacks arrive on the main queue.
final class HeaterLink: @unchecked Sendable {
    let host: String
    /// The heater's "reported" state, each time it publishes one.
    var onStatus: (([String: Any]) -> Void)?
    /// Each command sent (e.g. "D03102=1"), why, and how the heater answered:
    /// "accepted", "refused: …" or "no reply". Every command beeps, so each
    /// one is accounted for in the log.
    var onCommand: ((_ description: String, _ reason: String, _ result: String) -> Void)?
    /// The heater answers for the first time, stopped answering pings
    /// (unplugged at the wall, off Wi-Fi), or answers again.
    var onReachable: ((Bool) -> Void)?

    /// A heater remembers every subscriber (address, port and token) and keeps
    /// pushing to it long after it is gone; enough stale ones and it stops
    /// publishing at all. So each heater is always reached from the same port
    /// with the same token, and a new subscription replaces the old one.
    private let localPort: UInt16
    private let statusToken: [UInt8]

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var watchdog: DispatchSourceTimer?
    private var counter: String?
    private var messageID = UInt16.random(in: .min ... .max)
    private var syncToken: [UInt8] = []
    private var pending: [[UInt8]: (Bool) -> Void] = [:]
    /// What each command in flight was and why it was sent, for `onCommand`.
    private var pendingInfo: [[UInt8]: (description: String, reason: String)] = [:]
    /// When the last status arrived on this connection; nil until the first.
    private var lastStatus: Date?
    private var syncAttempts = 0
    private var quietChecks = 0
    private var lastSync = Date.distantPast
    /// When to ask a quiet heater again, and how long the wait after that is.
    private var nextAsk = Date.distantPast
    private var askInterval: TimeInterval = 5
    /// The timer step last reported, for wiggling; see `wiggle()`. Nil while
    /// a timer runs whose step is unknown, which rules wiggling out.
    private var lastTimerStep: Int?
    /// Whether the heater was last known to be on.
    private var lastPowerOn: Bool?
    private var lastWiggle = Date.distantPast
    private var wiggling: (key: String, temporary: Int, real: Int)?
    /// A wiggle's way back that failed, sent again after each sync until the
    /// heater takes it, so no timer is left set.
    private var pendingRestore: [String: Int]?
    /// Whether the heater's current state is still unknown, at launch.
    /// Cleared by its first status.
    private var needsReport = true
    /// Pings sent since the heater last answered anything. A quiet heater is
    /// normal (some only report changes), so silence alone proves nothing.
    private var unansweredPings = 0
    private var lastPing = Date.distantPast
    /// Nil until the heater first answers or is given up on after launch.
    private var isReachable: Bool?
    private var retryAfterSync: [UUID: (values: [String: Any], reason: String, completion: (Bool) -> Void)] = [:]

    init(host: String, deviceID: String) {
        self.host = host
        let hash = deviceID.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }  // FNV-1a
        localPort = 50_000 + UInt16(hash % 10_000)
        statusToken = withUnsafeBytes(of: hash.bigEndian, Array.init)
        queue = DispatchQueue(label: "HeaterLink.\(host)")
    }

    func start() { queue.async { self.connect() } }

    /// Ends the subscription so the heater stops pushing to this port.
    func stop() {
        queue.sync {
            transmit(.request(CoAPMessage.get, path: "sys/dev/status", messageID: nextMessageID(),
                              token: statusToken, observe: true, deregister: true))
            watchdog?.cancel()
            watchdog = nil
            let connection = connection
            self.connection = nil
            // Give the datagram a moment to leave before the socket closes.
            queue.asyncAfter(deadline: .now() + 0.2) { connection?.cancel() }
        }
    }

    /// Asks for a fresh status now (the panel opened). Only a read: wiggling
    /// here made the heater beep each time the panel opened.
    func refresh() {
        queue.async { self.counter == nil ? self.sync() : self.observe() }
    }

    /// The timer step remembered from the last session, until the heater
    /// reports: 0 when none ran, nil when one ran whose step is unknown.
    func seed(timerStep: Int?, isOn: Bool?) {
        queue.async {
            if self.lastTimerStep == nil { self.lastTimerStep = timerStep }
            if self.lastPowerOn == nil { self.lastPowerOn = isOn }
        }
    }

    /// Sets values in the heater's desired state, e.g. `["D03102": 1]`.
    func send(_ values: [String: Any], reason: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            self.control(values, reason: reason) { ok in
                if ok {
                    // A wiggle before the heater reports must restore these.
                    self.lastTimerStep = values["D03110"] as? Int ?? self.lastTimerStep
                    if let power = values["D03102"] as? Int { self.lastPowerOn = power == 1 }
                }
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    private func connect() {
        counter = nil
        lastStatus = nil
        quietChecks = 0
        nextAsk = .distantPast
        askInterval = 5
        guard let previous = connection else { return open() }
        // The fixed port is only free once the old connection has let go of it;
        // opening at once fails with "address already in use".
        previous.cancel()
        connection = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.open() }
    }

    private func open() {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: NWEndpoint.Port(rawValue: localPort)!)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 5683, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, host] state in
            log.info("\(host, privacy: .public) connection \(String(describing: state), privacy: .public)")
            // Anything sent while the connection was still waiting is lost, so
            // the handshake starts once it is ready.
            if case .ready = state, let self, self.connection === connection, self.counter == nil {
                self.sync()
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
        if isReachable == nil { checkReachable() }
        if watchdog == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.checkFreshness() }
            timer.resume()
            watchdog = timer
        }
    }

    /// Heaters push changes to subscribers, but a request or a push can go
    /// missing and a subscription can lapse silently. A heater without a status
    /// yet, or quiet for a minute, is asked again (the same subscription, so
    /// nothing piles up on it), backing off from 5 to 60 seconds: slow models
    /// take 10 seconds or more to answer and jam when asked faster. Asking is a
    /// read; commands are avoided here because every one makes the heater beep.
    /// After a dozen unanswered asks the link starts over.
    private func checkFreshness() {
        guard connection != nil else { return }  // reopening
        checkReachable()
        if counter == nil {
            syncAttempts += 1
            syncAttempts.isMultiple(of: 6) ? connect() : sync()
            return
        }
        let now = Date()
        if let lastStatus, now.timeIntervalSince(lastStatus) < 60 { return }
        guard now >= nextAsk else { return }
        quietChecks += 1
        if quietChecks >= 12 {
            connect()
            return
        }
        observe()
        nextAsk = now.addingTimeInterval(askInterval)
        askInterval = min(askInterval * 2, 60)
    }

    /// A CoAP ping (an empty confirmable message) every 15 seconds: the heater
    /// answers it with a reset, silently, without touching its session or
    /// anyone else's. Four in a row unanswered (under a minute) means it is
    /// gone; fewer would let a weak Wi-Fi's lost packets raise false alarms.
    /// At launch, before the first answer, every 5 seconds and two misses, so
    /// a heater unplugged meanwhile does not show its old state for long.
    /// Counting pings, not seconds, keeps a Mac waking from sleep from calling
    /// it gone.
    private func checkReachable() {
        let now = Date()
        guard now.timeIntervalSince(lastPing) >= (isReachable == nil ? 5 : 15) else { return }
        lastPing = now
        if unansweredPings >= (isReachable == nil ? 2 : 4), isReachable != false {
            isReachable = false
            log.error("\(self.host, privacy: .public) unreachable")
            DispatchQueue.main.async { self.onReachable?(false) }
        }
        unansweredPings += 1
        transmit(CoAPMessage(kind: .confirmable, code: 0, messageID: nextMessageID(), token: []))
    }

    /// Anything from the heater proves it is there. Back after being gone, it
    /// most likely restarted and lost its key and subscription, so start over.
    private func heard() {
        unansweredPings = 0
        guard isReachable != true else { return }
        let wasGone = isReachable == false
        isReachable = true
        DispatchQueue.main.async { self.onReachable?(true) }
        guard wasGone else { return }
        log.info("\(self.host, privacy: .public) reachable again")
        // No wiggle (and no beeps) here: a Wi-Fi drop changes no setting, and
        // after a power cut the CX5120 reports by itself once it is back.
        connect()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === connection else { return }
            if let data, let message = CoAPMessage(Array(data)) { self.handle(message) }
            guard let error else {
                self.receive(on: connection)
                return
            }
            // Errors are often passing (the network is briefly "down" while
            // macOS checks Local Network access at launch), so keep listening.
            log.error("\(self.host, privacy: .public) receive failed: \(error.localizedDescription, privacy: .public)")
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.connection === connection else { return }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ message: CoAPMessage) {
        heard()
        if message.kind == .confirmable {
            transmit(CoAPMessage(kind: .acknowledgement, code: 0, messageID: message.messageID, token: []))
        }
        guard message.code != 0 else { return }
        let text = String(decoding: message.payload, as: UTF8.self)
        log.debug("\(self.host, privacy: .public) received kind \(message.kind.rawValue) code \(message.code) token \(message.token.hexString, privacy: .public) payload \(message.payload.count) bytes")
        if !syncToken.isEmpty, message.token == syncToken {
            counter = text.trimmingCharacters(in: .whitespacesAndNewlines)
            syncToken = []
            syncAttempts = 0
            lastSync = Date()
            log.info("\(self.host, privacy: .public) synced")
            subscribe()
            let queued = retryAfterSync.values
            retryAfterSync = [:]
            queued.forEach { control($0.values, reason: $0.reason, retry: false, completion: $0.completion) }
        } else if let completion = pending.removeValue(forKey: message.token) {
            let ok = message.code == CoAPMessage.content && text.contains("success")
            if ok {
                log.info("\(self.host, privacy: .public) command accepted")
            } else {
                log.error("\(self.host, privacy: .public) command refused (code \(message.code)): \(String(text.prefix(120)), privacy: .public)")
            }
            reportCommand(message.token, ok ? "accepted" : "refused: " + text.prefix(80))
            completion(ok)
        } else if var status = Self.reportedState(in: text) {
            // Any token: an earlier subscription the heater still remembers
            // carries the same news.
            // Any value: models may echo a setting differently (the CX5120
            // reports timer step 1 as 2).
            if let wiggle = wiggling, status[wiggle.key] as? Int != wiggle.real {
                status[wiggle.key] = wiggle.real  // not worth showing
                status.removeValue(forKey: "D03211")  // nor the countdown it starts
            } else {
                lastTimerStep = status["D03110"] as? Int ?? lastTimerStep
                if let power = status["D03102"] as? Int { lastPowerOn = power == 1 }
            }
            lastStatus = Date()
            needsReport = false
            quietChecks = 0
            nextAsk = .distantPast
            askInterval = 5
            log.info("\(self.host, privacy: .public) status received")
            DispatchQueue.main.async { self.onStatus?(status) }
        } else if !message.payload.isEmpty {
            log.error("\(self.host, privacy: .public) unreadable payload: \(String(text.prefix(80)), privacy: .public)")
        }
    }

    private func sync() {
        syncToken = Self.newToken()
        transmit(.request(CoAPMessage.post, path: "sys/dev/sync", messageID: nextMessageID(),
                          token: syncToken, payload: Self.newToken().hexString))
    }

    private func subscribe() {
        nextAsk = Date().addingTimeInterval(askInterval)
        observe()
        if let restore = pendingRestore {
            control(restore, reason: "wiggle (back, once the heater answered again)", retry: false) { [weak self] ok in
                if ok { self?.pendingRestore = nil }
            }
        }
        // A heater that stays silent at launch gets one wiggle so its real
        // state is known (it beeps; the user accepts it).
        let synced = lastSync
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.lastSync == synced, self.lastStatus == nil, self.needsReport else { return }
            self.wiggle()
        }
    }

    /// Some models (CX5120) publish only when a setting really changes, or when
    /// Philips' cloud asks; empty commands, and a setting sent with the value it
    /// already has, do nothing (tried 2026-10-29). So a setting is changed
    /// and straight back, and the panel never shows the detour. Each command
    /// beeps (and is likely stored by the heater), so this happens at most every
    /// five minutes, and only at launch or when the heater is back. The timer
    /// is the safe setting: should the way back fail, the heater only switches
    /// itself off in 30 minutes.
    private func wiggle() {
        guard Date().timeIntervalSince(lastWiggle) > 300 else { return }
        // Never the target: on 2026-10-29 a target change switched the
        // CX5120 on while it was off. A running timer is cancelled and set
        // again, which restarts its countdown. A heater that is off ends with
        // no timer, which has no use there.
        let change: (key: String, temporary: Int, real: Int)
        if lastPowerOn == false {
            change = ("D03110", 1, 0)
        } else if let step = lastTimerStep {
            change = ("D03110", step == 0 ? 1 : 0, step)
        } else {
            return
        }
        lastWiggle = Date()
        wiggling = change
        log.info("\(self.host, privacy: .public) wiggling \(change.key, privacy: .public) \(change.real) → \(change.temporary) → \(change.real)")
        control([change.key: change.temporary], reason: "wiggle (asks the heater to report)") { [weak self] ok in
            guard let self else { return }
            // Sent even when the first got no reply: the heater may have
            // applied it anyway (it did on 2026-10-29, leaving a timer set).
            if !ok { log.error("\(self.host, privacy: .public) wiggle got no confirmation; restoring anyway") }
            self.control([change.key: change.real], reason: "wiggle (back)") { [weak self] ok in
                if !ok {
                    log.error("\(self?.host ?? "", privacy: .public) could not restore \(change.key, privacy: .public) to \(change.real); will retry")
                    self?.pendingRestore = [change.key: change.real]
                }
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.wiggling = nil }
            }
        }
    }

    private func rejoin() {
        counter = nil
        sync()
    }

    /// Holds a command until the next sync, failing it if none comes in time.
    private func sendAfterSync(_ values: [String: Any], reason: String, completion: @escaping (Bool) -> Void) {
        let id = UUID()
        retryAfterSync[id] = (values, reason, completion)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.retryAfterSync.removeValue(forKey: id)?.completion(false)
        }
    }

    private func observe() {
        transmit(.request(CoAPMessage.get, path: "sys/dev/status", messageID: nextMessageID(),
                          token: statusToken, observe: true))
    }

    /// A heater keeps a single key, and any client that syncs (the Air+ app,
    /// another tool) replaces it; commands under the old key go unanswered. So
    /// a failed command rejoins and, with `retry`, is sent once more.
    private func control(_ values: [String: Any], reason: String, retry: Bool = true,
                         completion: @escaping (Bool) -> Void) {
        guard let counter else {
            retry ? sendAfterSync(values, reason: reason, completion: completion) : completion(false)
            return
        }
        let completion: (Bool) -> Void = { [weak self] ok in
            guard let self, !ok, retry else { return completion(ok) }
            log.error("\(self.host, privacy: .public) command failed, rejoining to retry")
            self.sendAfterSync(values, reason: reason + ", retried", completion: completion)
            self.rejoin()
        }
        let next = PhilipsCrypto.nextCounter(after: counter)
        self.counter = next
        var desired: [String: Any] = ["CommandType": "app", "DeviceId": "", "EnduserId": ""]
        desired.merge(values) { $1 }
        guard let body = try? JSONSerialization.data(withJSONObject: ["state": ["desired": desired]]),
              let encrypted = PhilipsCrypto.encrypt(String(decoding: body, as: UTF8.self), counter: next) else {
            completion(false)
            return
        }
        let token = Self.newToken()
        pending[token] = completion
        pendingInfo[token] = (values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: " "), reason)
        // Every command makes the heater beep, so each one is accounted for.
        log.info("\(self.host, privacy: .public) command \(String(decoding: body, as: UTF8.self), privacy: .public) with key \(next, privacy: .public)")
        transmit(.request(CoAPMessage.post, path: "sys/dev/control", messageID: nextMessageID(),
                          token: token, payload: encrypted))
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let completion = self.pending.removeValue(forKey: token) else { return }
            self.reportCommand(token, "no reply")
            completion(false)
        }
    }

    private func reportCommand(_ token: [UInt8], _ result: String) {
        guard let info = pendingInfo.removeValue(forKey: token) else { return }
        DispatchQueue.main.async { self.onCommand?(info.description, info.reason, result) }
    }

    private func transmit(_ message: CoAPMessage) {
        let path = message.options.filter { $0.number == 11 }.map { String(decoding: $0.value, as: UTF8.self) }
            .joined(separator: "/")
        connection?.send(content: Data(message.encoded()), completion: .contentProcessed { [host] error in
            if let error {
                log.error("\(host, privacy: .public) send \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    private func nextMessageID() -> UInt16 {
        messageID &+= 1
        return messageID
    }

    private static func newToken() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: .min ... .max) } }

    private static func reportedState(in payload: String) -> [String: Any]? {
        guard let json = PhilipsCrypto.decrypt(payload),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let state = object["state"] as? [String: Any] else { return nil }
        log.debug("status json: \(json, privacy: .public)")
        return state["reported"] as? [String: Any]
    }
}
