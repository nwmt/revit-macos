// The event tap and the gesture machine, on a thread of their own with its own run loop (spec §1, plan "Threads").
// The callback turns events into the machine's inputs and its posts into events; our own events (tagged in
// eventSourceUserData) go back to the system untouched before anything else. The machine's state is touched on this
// thread only: other threads hand work over with perform(). The tap listens to scrolling, gestures and mouse-button
// presses only: no keyboard, no mouse movement.
import AppKit
import ApplicationServices
import CoreGraphics
import TrackpadCore
import TrackpadIO

final class TapThread: @unchecked Sendable {
    private var loop: CFRunLoop!
    private var machine: GestureMachine!
    private var context = DecideContext(revits: [:])
    private var tap: CFMachPort?, tapSource: CFRunLoopSource?, ticker: CFRunLoopTimer?
    private let events = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var probeSeen = false
    private var ownDown = false                 // our middle button is down (this thread only)
    private let log: TrackpadLog
    var onDisabled: (@Sendable () -> Void)?   // macOS turned the tap off (it is on again already)

    init(log: TrackpadLog) {
        self.log = log
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            machine = GestureMachine(decide: { [unowned self] p in self.decide(p) })
            // keeps the run loop running while there is no tap
            CFRunLoopAddTimer(loop, CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "trackpad tap"; t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
    }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    private func onThread<T>(_ block: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: T?
        perform { out = block(); done.signal() }
        done.wait()
        return out!
    }

    func create() -> Bool { onThread { self.createHere() } }

    private func createHere() -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = (1 << 29) | (1 << 30)   // gesture, magnify: no public CGEventType (spec §6)
        for t: CGEventType in [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown] { mask |= 1 << t.rawValue }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(loop, src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        let tick = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + TrackpadConstants.watchdogTick,
                                                   TrackpadConstants.watchdogTick, 0, 0) { [unowned self] _ in
            _ = self.feed(.tick(ProcessInfo.processInfo.systemUptime))
        }
        CFRunLoopAddTimer(loop, tick, .commonModes)
        tap = t; tapSource = src; ticker = tick
        return true
    }

    func disable() { onThread { self.disableHere() } }

    private func disableHere() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = tapSource { CFRunLoopRemoveSource(loop, s, .commonModes) }
        if let k = ticker { CFRunLoopTimerInvalidate(k) }
        tap = nil; tapSource = nil; ticker = nil
    }

    /// The cancel, its posts (the button up) and the end of the tap in one block on this thread: no event can start a
    /// gesture in between.
    func cancelAndDisable(_ r: CancelReason) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            perform { _ = self.feed(.cancel(r)); self.disableHere(); c.resume() }
        }
    }

    func setContext(_ c: DecideContext) { perform { self.context = c } }

    /// The machine's cancel and its posts on this thread; returns when they are sent.
    func cancel(_ r: CancelReason) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            perform { _ = self.feed(.cancel(r)); c.resume() }
        }
    }

    func probePosting() async -> Bool {
        lock.withLock { probeSeen = false }
        if let e = CGEvent(scrollWheelEvent2Source: events, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) {
            e.setIntegerValueField(.eventSourceUserData, value: TrackpadConstants.eventTag)
            e.post(tap: .cghidEventTap)
        }
        let end = ProcessInfo.processInfo.systemUptime + TrackpadConstants.postingProbe
        while ProcessInfo.processInfo.systemUptime < end {
            if lock.withLock({ probeSeen }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return lock.withLock { probeSeen }
    }

    /// Called by the tap: true = let the event through.
    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            _ = feed(.cancel(.tapDisabled))
            onDisabled?()
            return true
        }
        if e.getIntegerValueField(.eventSourceUserData) == TrackpadConstants.eventTag {   // ours: untouched
            if type == .scrollWheel { lock.withLock { probeSeen = true } }
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .scrollWheel:
            return feed(.scroll(ScrollIn(continuous: e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                                         phase: Int(e.getIntegerValueField(.scrollWheelEventScrollPhase)),
                                         momentum: Int(e.getIntegerValueField(.scrollWheelEventMomentumPhase)),
                                         dx: Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                                         dy: Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                                         at: e.location, mods: mods(e.flags), time: now, ours: false)))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return feed(.mouseDown(ours: false))
        default:   // 29/30: a gesture; only a pinch is ours
            guard let ns = NSEvent(cgEvent: e), ns.type == .magnify else { return feed(.otherGesture) }
            let phase: GesturePhase
            switch ns.phase {
            case .mayBegin: phase = .mayBegin
            case .began: phase = .began
            case .ended: phase = .ended
            case .cancelled: phase = .cancelled
            default: phase = .changed
            }
            return feed(.magnify(MagnifyIn(phase: phase, amount: Double(ns.magnification), at: e.location, time: now, ours: false)))
        }
    }

    /// The machine's answer for one input; its posts go out at once. On this thread only.
    private func feed(_ i: Input) -> Bool {
        let r = machine.handle(i)
        post(r.posts)
        return r.pass
    }

    private func decide(_ p: CGPoint) -> Target? {
        let s = CGEventSourceStateID.combinedSessionState
        let buttons = Decider.userButtonsDown(left: CGEventSource.buttonState(s, button: .left),
                                              right: CGEventSource.buttonState(s, button: .right),
                                              center: CGEventSource.buttonState(s, button: .center), ownCenterDown: ownDown)
        return Decider.decide(at: p, windows: buttons ? [] : windows(), buttonsDown: buttons, context: context, log: log)
    }

    /// The windows on screen from front to back, all layers (spec §3).
    private func windows() -> [WinInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return WinInfo(pid: pid, bounds: r, alpha: w[kCGWindowAlpha as String] as? Double ?? 1,
                           layer: w[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    func post(_ posts: [Post]) {
        for p in posts {
            let e: CGEvent?
            switch p {
            case .down(let at, let m): e = mouse(.otherMouseDown, at, m); ownDown = true
            case .drag(let at, let m): e = mouse(.otherMouseDragged, at, m)
            case .up(let at, let m): e = mouse(.otherMouseUp, at, m); ownDown = false
            case .wheel(let px, let at):
                e = CGEvent(scrollWheelEvent2Source: events, units: .pixel, wheelCount: 1, wheel1: px, wheel2: 0, wheel3: 0)
                e?.location = at
            }
            guard let e else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: TrackpadConstants.eventTag)
            e.post(tap: .cghidEventTap)
        }
    }

    private func mouse(_ type: CGEventType, _ at: CGPoint, _ m: Mods) -> CGEvent? {
        let e = CGEvent(mouseEventSource: events, mouseType: type, mouseCursorPosition: at, mouseButton: .center)
        var f = CGEventFlags()
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        e?.flags = f
        return e
    }

    private func mods(_ f: CGEventFlags) -> Mods {   // Command is left out on purpose (spec §6)
        var m: Mods = []
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        return m
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<TapThread>.fromOpaque(refcon).takeUnretainedValue()
    return me.handle(type, event) ? Unmanaged.passUnretained(event) : nil
}
