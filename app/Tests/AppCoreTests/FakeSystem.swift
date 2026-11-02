// A fake of the Mac's side of the wizard (Rosetta, Homebrew, opening a page): records what was asked.
import Foundation
@testable import AppCore

struct FakeError: Error, LocalizedError { let text: String; var errorDescription: String? { text } }

@MainActor final class FakeSystem: SystemActions {
    var calls: [String] = []
    var rosettaError: String?
    var brewPath: URL?
    var brewArgs: [[String]] = []
    var opened: [URL] = []

    var holdRosetta = false                 // installRosetta waits for releaseRosetta(): one still running
    var rosettaWaiting = false
    var rosettaCalls: Int { calls.filter { $0 == "rosetta" }.count }
    private var rosettaGate: CheckedContinuation<Void, Never>?
    func releaseRosetta() { holdRosetta = false; rosettaGate?.resume(); rosettaGate = nil }

    func installRosetta() async throws {
        calls.append("rosetta")
        if holdRosetta { rosettaWaiting = true; await withCheckedContinuation { rosettaGate = $0 }; rosettaWaiting = false }
        if let e = rosettaError { throw FakeError(text: e) }
    }
    func brew() -> URL? { brewPath }
    func brewInstall(_ args: [String], log: URL) async throws { calls.append("brew"); brewArgs.append(args) }
    func open(_ url: URL) { calls.append("open"); opened.append(url) }
}
