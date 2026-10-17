import SwiftUI

/// Presentation only. No control timing, device state or persisted preferences live here.
enum HeadLinkUI {
    static let accent=Color(red:0.388,green:0.851,blue:0.929)
    static let canvas=Color.black
    static let inset:CGFloat=16
    static let radius:CGFloat=24
}

private struct FloatingSurface:ViewModifier {
    let radius:CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder func body(content:Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:radius))
        } else if reduceMotion {
            content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius))
        } else if #available(iOS 26.0,*) {
            content.glassEffect(.regular,in:RoundedRectangle(cornerRadius:radius))
        } else {
            content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius))
        }
    }
}

extension View {
    func floatingSurface(radius:CGFloat = HeadLinkUI.radius) -> some View { modifier(FloatingSurface(radius:radius)) }
    func headLinkList() -> some View {
        self.listStyle(.insetGrouped).environment(\.defaultMinListRowHeight,52)
    }
}

struct QuietButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration) -> some View {
        configuration.label
            .frame(minWidth:44,minHeight:44)
            .contentShape(RoundedRectangle(cornerRadius:16))
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear,in:RoundedRectangle(cornerRadius:16))
    }
}

struct SettingTitle:View {
    let title:String; let icon:String
    var body:some View {
        Label(LocalizedStringKey(title),systemImage:icon).labelStyle(.titleAndIcon)
    }
}
