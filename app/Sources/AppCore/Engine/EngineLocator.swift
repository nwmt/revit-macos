// Where the engine is: APP_ENGINE (a revit script: dev, the demo) wins, else the copy inside the app's bundle.
import Foundation

public enum EngineLocator {
    public static func find(resources: URL?, env: [String: String]) -> URL? {
        if let p = env["APP_ENGINE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        guard let r = resources?.appending(path: "engine/revit"), FileManager.default.fileExists(atPath: r.path) else { return nil }
        return r
    }
}
