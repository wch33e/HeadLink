import SwiftUI

/// Presentation only. No control timing, device state or persisted preferences live here.
enum HeadLinkUI {
    static let accent=Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.388,green:0.851,blue:0.929,alpha:1) : UIColor(red:0,green:0.40,blue:0.49,alpha:1) })
    static let onAccent=Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    static let warning=Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? .systemOrange : UIColor(red:0.55,green:0.28,blue:0,alpha:1) })
    static let group=Color(uiColor:.secondarySystemBackground)
    static let canvas=Color(uiColor:.systemBackground)
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
        self.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HeadLinkUI.canvas).environment(\.defaultMinListRowHeight,52)
    }
}

struct QuietButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label
            .frame(minWidth:44,minHeight:44)
            .contentShape(RoundedRectangle(cornerRadius:16))
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear,in:RoundedRectangle(cornerRadius:16))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct SettingTitle:View {
    let title:String; let icon:String
    var body:some View {
        Label(LocalizedStringKey(title),systemImage:icon).labelStyle(.titleAndIcon)
    }
}

private struct PrimaryControlLabel:ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicType
    func body(content:Content) -> some View {
        content.labelStyle(CompactPrimaryLabelStyle()).font(.callout.weight(.medium))
            .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth:.infinity,minHeight:44)
    }
}
private struct CompactPrimaryLabelStyle:LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicType
    func makeBody(configuration:Configuration) -> some View {
        if dynamicType.isAccessibilitySize { configuration.title }
        else { VStack(spacing:4) { configuration.icon; configuration.title } }
    }
}
extension View { func primaryControlLabel() -> some View { modifier(PrimaryControlLabel()) } }
