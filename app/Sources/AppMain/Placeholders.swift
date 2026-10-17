// Windows filled by later work: the wizard, the add-ins window, the settings.
import AppCore
import SwiftUI

struct AddinsWindow: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    var body: some View { Text("Add-ins of Revit \(String(ref.year)) · \(ref.bottle)").padding().frame(width: 420) }
}

struct SettingsWindow: View {
    let app: AppModel
    let env: AppEnvironment
    var body: some View { Text("Settings").padding().frame(width: 420) }
}
