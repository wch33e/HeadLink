import SwiftUI

enum AppearancePreference:String,CaseIterable,Identifiable {
    case system,light,dark
    var id:String { rawValue }
    var title:String { switch self { case .system:return "跟随系统"; case .light:return "浅色"; case .dark:return "深色" } }
    var colorScheme:ColorScheme? { switch self { case .system:return nil; case .light:return .light; case .dark:return .dark } }
}
private struct HeadLinkTheme:ViewModifier {
    @AppStorage("appearance") private var preference="light"
    func body(content:Content) -> some View {
        content.preferredColorScheme((AppearancePreference(rawValue:preference) ?? .light).colorScheme)
    }
}
extension View {
    func headLinkTheme() -> some View { modifier(HeadLinkTheme()) }
}
struct AppearancePicker:View {
    @AppStorage("appearance") private var preference="light"
    var body:some View {
        Picker("外观",selection:$preference) {
            ForEach(AppearancePreference.allCases) { Text(LocalizedStringKey($0.title)).tag($0.rawValue) }
        }.accessibilityIdentifier("appearanceSetting")
    }
}
