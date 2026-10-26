// The gesture state machine (spec 2026-10-26-trackpad §6). One gesture at a time; the decision "a Revit view or not" is
// taken once, at its start, and holds to its end. Over a view, two-finger scrolling becomes a middle-button drag (Revit:
// pan; with Shift: orbit) and a pinch becomes the scroll wheel (zoom); the original events are dropped. Anything else,
// and every doubt, passes unchanged. It belongs to the event tap's thread: everything reaches it through handle().
import CoreGraphics

public struct Mods: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Mods(rawValue: 1)      // Revit: orbit
    public static let control = Mods(rawValue: 2)
    public static let option = Mods(rawValue: 4)     // Command is not passed: with Cmd → Ctrl it means nothing here
}

public enum GesturePhase: Sendable { case mayBegin, began, changed, ended, cancelled }

/// A scroll event: phase 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin, 0 none (a wheel or a driver's smooth
/// scrolling); momentum 0 none, 1 begin, 2 continue, 3 end.
public struct ScrollIn: Sendable {
    public var continuous: Bool, phase: Int, momentum: Int, dx: Double, dy: Double, at: CGPoint, mods: Mods
    public var time: Double, ours: Bool
    public init(continuous: Bool, phase: Int, momentum: Int, dx: Double, dy: Double, at: CGPoint, mods: Mods, time: Double, ours: Bool) {
        self.continuous = continuous; self.phase = phase; self.momentum = momentum; self.dx = dx; self.dy = dy
        self.at = at; self.mods = mods; self.time = time; self.ours = ours
    }
}

public struct MagnifyIn: Sendable {
    public var phase: GesturePhase, amount: Double, at: CGPoint, time: Double, ours: Bool
    public init(phase: GesturePhase, amount: Double, at: CGPoint, time: Double, ours: Bool) {
        self.phase = phase; self.amount = amount; self.at = at; self.time = time; self.ours = ours
    }
}

public enum CancelReason: Equatable, Sendable {
    case tapDisabled, permissionLost, displays, switchOff
    case targetGone(Int32), hittestFailed(Int32)    // this Revit (its Mac pid) only
    case activated(Int32)                           // the newly active process: a cancel unless it is the gesture's own
}

public enum Input: Sendable {
    case scroll(ScrollIn), magnify(MagnifyIn), otherGesture, mouseDown(ours: Bool), tick(Double), cancel(CancelReason)
}

public struct Target: Equatable, Sendable {
    public let pid: Int32
    public init(pid: Int32) { self.pid = pid }
}

public enum Post: Equatable, Sendable {
    case down(CGPoint, Mods), drag(CGPoint, Mods), up(CGPoint, Mods), wheel(Int32, CGPoint)
}

public final class GestureMachine {
    public enum State: Equatable {
        case idle, passing, panning(Target), released(Target), pinching(Target), dropping
    }

    public private(set) var state = State.idle
    private let decide: (CGPoint) -> Target?
    private var pending: Target??               // decided at "may begin", taken at "began"
    private var cur = CGPoint.zero, mods: Mods = [], last = 0.0
    private var remainder = 0.0                 // wheel pixels not sent yet
    private var dropMomentum = false            // the momentum after this gesture is ours to drop
    private var droppedEarly = false            // cancelled between "may begin" and "began": its "began" is dropped too

    public init(decide: @escaping (CGPoint) -> Target?) { self.decide = decide }

    /// pass: return the original event to the system; posts: the events to send instead (or as well).
    public func handle(_ input: Input) -> (pass: Bool, posts: [Post]) {
        switch input {
        case .scroll(let s): return s.ours ? (true, []) : scroll(s)
        case .magnify(let m): return m.ours ? (true, []) : magnify(m)
        case .otherGesture: return (true, [])
        case .mouseDown(let ours): return (true, ours ? [] : drop())
        case .tick(let t): return (true, tick(t))
        case .cancel(let r): return (true, cancel(r))
        }
    }

    private var target: Target? {
        switch state { case .panning(let t), .released(let t), .pinching(let t): return t; default: return nil }
    }

    /// Ends what we own: the button up if it is down; the rest of this gesture and its momentum are dropped.
    private func drop() -> [Post] {
        var out: [Post] = []
        if case .panning = state { out = [.up(cur, mods)] }
        guard target != nil || pendingTarget != nil else { return out }
        droppedEarly = pendingTarget != nil
        state = .dropping; pending = nil; dropMomentum = true
        return out
    }

    /// A gesture decided at "may begin" that has not begun yet.
    private var pendingTarget: Target? { if case .some(.some(let t)) = pending { return t }; return nil }

    private func cancel(_ r: CancelReason) -> [Post] {
        let t = target ?? pendingTarget
        switch r {
        case .targetGone(let p), .hittestFailed(let p): return t?.pid == p ? drop() : []
        case .activated(let p): return t != nil && t?.pid != p ? drop() : []
        default: return drop()
        }
    }

    private func tick(_ t: Double) -> [Post] {
        guard case .panning(let tg) = state, t - last >= TrackpadConstants.watchdog else { return [] }
        state = .released(tg)
        return [.up(cur, mods)]
    }

    /// The end of whatever gesture is active, before a new one starts.
    private func endActive() -> [Post] {
        var out: [Post] = []
        if case .panning = state { out = [.up(cur, mods)] }
        state = .idle; pending = nil; droppedEarly = false
        return out
    }

    private func scroll(_ s: ScrollIn) -> (Bool, [Post]) {
        if s.momentum != 0 {
            let keep = dropMomentum || state == .dropping
            if s.momentum == 3 { dropMomentum = false; if state == .dropping { state = .idle } }
            return (!keep, [])
        }
        guard s.continuous, s.phase != 0 else {   // a wheel, or smooth scrolling without phases
            switch state { case .panning, .released, .pinching: return (true, drop()); default: return (true, []) }
        }
        switch s.phase {
        case 128:
            let pre = endActive()
            dropMomentum = false
            let d = decide(s.at)
            pending = .some(d); state = d == nil ? .passing : .idle
            return (d == nil, pre)
        case 1:
            if state == .dropping && droppedEarly { return (false, []) }   // the same touch, cancelled before it began
            var pre: [Post] = []
            let d: Target?
            if let p = pending, state == .idle || state == .passing { d = p; pending = nil }
            else { pre = endActive(); d = decide(s.at) }
            dropMomentum = false
            return start(d, s, pre)
        case 2:
            switch state {
            case .passing: return (true, [])
            case .dropping: return (false, [])
            case .panning: return (false, move(s))
            case .released(let t):
                state = .panning(t); last = s.time
                return (false, [.down(cur, mods)] + move(s))
            case .idle, .pinching:   // the beginning was missed: decide now
                let pre = endActive()
                return start(decide(s.at), s, pre)
            }
        case 4, 8:
            let r: (Bool, [Post])
            switch state {
            case .panning: r = (false, [.up(cur, mods)]); dropMomentum = true
            case .released, .dropping: r = (false, []); dropMomentum = true
            case .passing: r = (true, []); dropMomentum = false
            case .idle:   // a "may begin" that never began
                let ownedPending = pending.map { $0 != nil } == true
                r = (!ownedPending, [])
            case .pinching: r = (true, [])
            }
            if case .pinching = state {} else { state = .idle; pending = nil; droppedEarly = false }
            return r
        default:
            return (true, [])
        }
    }

    private func start(_ d: Target?, _ s: ScrollIn, _ pre: [Post]) -> (Bool, [Post]) {
        guard let t = d else { state = .passing; return (true, pre) }
        state = .panning(t); cur = s.at; mods = s.mods; last = s.time; dropMomentum = true
        return (false, pre + [.down(cur, mods)] + (s.dx != 0 || s.dy != 0 ? move(s) : []))
    }

    private func move(_ s: ScrollIn) -> [Post] {
        cur = CGPoint(x: cur.x + s.dx * TrackpadConstants.panScale, y: cur.y + s.dy * TrackpadConstants.panScale)
        last = s.time
        return [.drag(cur, mods)]
    }

    private func magnify(_ m: MagnifyIn) -> (Bool, [Post]) {
        switch m.phase {
        case .mayBegin, .began:
            if m.phase == .began && state == .dropping && droppedEarly { return (false, []) }
            if m.phase == .began, let p = pending, state == .idle || state == .passing {
                pending = nil
                return pinch(p, m, [])
            }
            let pre = endActive()
            let d = decide(m.at)
            if m.phase == .mayBegin { pending = .some(d); state = d == nil ? .passing : .idle; return (d == nil, pre) }
            return pinch(d, m, pre)
        case .changed:
            switch state {
            case .passing: return (true, [])
            case .dropping: return (false, [])
            case .pinching: return (false, wheel(m))
            case .idle, .panning, .released:   // the beginning was missed
                let pre = endActive()
                let (pass, posts) = pinch(decide(m.at), m, pre)
                guard case .pinching = state else { return (pass, posts) }
                return (false, posts + wheel(m))
            }
        case .ended, .cancelled:
            let pass: Bool
            switch state { case .passing: pass = true; case .pinching, .dropping: pass = false; default: pass = true }
            switch state { case .passing, .pinching, .dropping: state = .idle; default: break }
            pending = nil
            return (pass, [])
        }
    }

    private func pinch(_ d: Target?, _ m: MagnifyIn, _ pre: [Post]) -> (Bool, [Post]) {
        guard let t = d else { state = .passing; return (true, pre) }
        state = .pinching(t); remainder = 0
        return (false, pre)
    }

    private func wheel(_ m: MagnifyIn) -> [Post] {
        remainder += m.amount * TrackpadConstants.zoomScale
        let px = remainder.rounded(.towardZero)
        guard px != 0 else { return [] }
        remainder -= px
        return [.wheel(Int32(px), m.at)]
    }
}
