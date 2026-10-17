// What the wizard asks of the Mac itself rather than of the engine: Rosetta (with the administrator's password),
// Homebrew for CrossOver, opening a web page. The app's implementation is MacSystemActions; the tests fake it.
import Foundation

@MainActor public protocol SystemActions {
    /// softwareupdate --install-rosetta --agree-to-license, with administrator privileges.
    func installRosetta() async throws
    /// /opt/homebrew/bin/brew, else /usr/local/bin/brew, when executable.
    func brew() -> URL?
    /// brew <args>, its output to log.
    func brewInstall(_ args: [String], log: URL) async throws
    func open(_ url: URL)
}
