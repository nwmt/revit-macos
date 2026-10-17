// Where the app's links point: the apps the engine makes in ~/Applications, the logs, the project on GitHub.
import Foundation

public enum AppLinks {
    public static func revitApp(year: Int, bottle: String, home: URL) -> URL {
        home.appending(path: "Applications").appending(path: "Revit \(year) (\(bottle)).app")
    }

    public static func viewerApp(year: Int, bottle: String, home: URL) -> URL {
        home.appending(path: "Applications").appending(path: "Revit Viewer \(year) (\(bottle)).app")
    }

    /// <data>/logs/<bottle>, or <data>/logs.
    public static func logs(data: URL, bottle: String?) -> URL {
        let l = data.appending(path: "logs")
        return bottle.map { l.appending(path: $0) } ?? l
    }

    public static func readme(repo: String) -> URL { URL(string: "https://github.com/\(repo)#readme")! }
    public static func releases(repo: String) -> URL { URL(string: "https://github.com/\(repo)/releases")! }
}
