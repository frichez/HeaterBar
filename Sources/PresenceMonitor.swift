import AppKit
import CoreGraphics

/// Whether someone is at this Mac: away once the screen has been locked, or
/// the keyboard and mouse untouched, for ten minutes, and at once when the Mac
/// goes to sleep (nothing can be sent once it sleeps); back as soon as it is
/// unlocked and used again.
@MainActor
final class PresenceMonitor {
    static let awayDelay: TimeInterval = 10 * 60

    var onChange: ((_ isAway: Bool) -> Void)?
    private(set) var isAway = false

    private var isLocked = false
    private var lockedSince: Date?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAway(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    private func setLocked(_ locked: Bool) {
        isLocked = locked
        lockedSince = locked ? Date() : nil
        evaluate()
    }

    private func evaluate() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if isAway {
            // Back only when unlocked and actually used: a dark wake is not a person.
            if !isLocked && idle < 60 { setAway(false) }
        } else {
            let lockedLong = lockedSince.map { Date().timeIntervalSince($0) >= Self.awayDelay } ?? false
            if lockedLong || idle >= Self.awayDelay { setAway(true) }
        }
    }

    private func setAway(_ away: Bool) {
        guard away != isAway else { return }
        isAway = away
        onChange?(away)
    }
}
