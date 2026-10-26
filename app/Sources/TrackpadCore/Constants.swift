// The trackpad gestures' numbers, in one place (spec 2026-10-26-trackpad §4, §6, §7).
import Foundation

public enum TrackpadConstants {
    public static let panScale = 1.0                 // points of drag per point of scrolling
    public static let zoomScale = 600.0              // wheel pixels per unit of magnification
    public static let hitTimeout = 0.150             // a hittest answer, from writing the request
    public static let watchdog = 2.0                 // a pan without events lets the middle button go
    public static let watchdogTick = 0.5
    public static let helloTimeout = 10.0
    public static let restartInterval = 10.0         // hittest and the helper start again at most this often
    public static let failuresToError = 3            // in a row
    public static let tapDisablesToError = 5         // more than this many within tapDisableWindow: error
    public static let tapDisableWindow = 60.0
    public static let maxLine = 4096                 // bytes of one protocol line
    public static let permissionCheck = 2.0
    public static let displayRetry = 1.0, displayRetries = 10
    public static let statusRetries: [Double] = [2, 5, 10]
    public static let postingProbe = 1.0             // the helper's own test event must come back within this
    public static let eventTag: Int64 = 0x52565450   // "RVTP" in eventSourceUserData: our own posted events
}
