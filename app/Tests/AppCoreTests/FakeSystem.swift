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

    func installRosetta() async throws {
        calls.append("rosetta")
        if let e = rosettaError { throw FakeError(text: e) }
    }
    func brew() -> URL? { brewPath }
    func brewInstall(_ args: [String], log: URL) async throws { calls.append("brew"); brewArgs.append(args) }
    func open(_ url: URL) { calls.append("open"); opened.append(url) }
}
