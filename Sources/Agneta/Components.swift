// Agneta's building blocks on macOS 26 Liquid Glass, with material fallbacks
// for macOS 14–15. Every interactive surface has hover and press feedback;
// motion respects Reduce Motion.
import AgnetaKit
import AppKit
import SwiftUI

// MARK: Glass

extension EnvironmentValues {
    /// Inside a dialog's frosted glass, where plain glass buttons would lose their shape.
    @Entry var onDialogGlass = false
}

private struct GlassButton: ViewModifier {
    var prominent: Bool
    @Environment(\.onDialogGlass) private var onDialogGlass

    func body(content: Content) -> some View {
        if prominent {
            // The one prominent button per surface wears the app icon's evening, quietly.
            content.buttonStyle(EveningButtonStyle())
        } else if #available(macOS 26, *) {
            if onDialogGlass {
                // A faint tint keeps the button's shape visible on frosted glass, in front and behind.
                content.buttonStyle(.glass(.regular.tint(Color.primary.opacity(0.14))))
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// A prominent button: white text on the evening's rose, drifting coral to violet left to right, with a glass sheen
/// on top and a hairline edge. Hover lifts it a little, a press settles it; disabled, it fades.
struct EveningButtonStyle: ButtonStyle {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        EveningButton(configuration: configuration, controlSize: controlSize, isEnabled: isEnabled, dark: scheme == .dark)
    }

    private struct EveningButton: View {
        let configuration: Configuration
        let controlSize: ControlSize
        let isEnabled: Bool
        let dark: Bool
        @State private var hovered = false

        var body: some View {
            let (horizontal, vertical, size): (CGFloat, CGFloat, CGFloat) = switch controlSize {
            case .mini, .small: (10, 4, 11.5)
            case .large, .extraLarge: (18, 8, 14)
            default: (14, 5.5, 13)
            }
            let shape = Capsule()
            configuration.label
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, horizontal).padding(.vertical, vertical)
                .background(shape.fill(LinearGradient(colors: Palette.buttonFill(dark: dark), startPoint: .leading, endPoint: .trailing)))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.14 : 0.2), .white.opacity(0)], startPoint: .top, endPoint: .center)))
                .overlay(shape.strokeBorder(.white.opacity(dark ? 0.18 : 0.3), lineWidth: 0.5))
                .brightness(configuration.isPressed ? -0.08 : hovered ? 0.04 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension View {
    /// A glass surface (macOS 26) or a material one (earlier).
    @ViewBuilder func glassSurface(_ shape: some Shape = RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Glass buttons (macOS 26) or bordered ones (earlier).
    func glassButton(prominent: Bool = false) -> some View { modifier(GlassButton(prominent: prominent)) }

    /// The Return-key action only when `condition` holds.
    @ViewBuilder func defaultAction(when condition: Bool) -> some View {
        if condition { self.keyboardShortcut(.defaultAction) } else { self }
    }

    func hoverHighlight(cornerRadius: CGFloat = 10) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius)) }

    /// A card on top of glass: a light frosted tint and a hairline edge. Glass on glass turns
    /// grey and opaque, so cards inside glass use this instead.
    func frostedCard(tint: Color? = nil, cornerRadius: CGFloat = 16) -> some View {
        modifier(FrostedCard(tint: tint, cornerRadius: cornerRadius))
    }
}

/// Frosted card; with Increase Contrast its edge is drawn clearly.
struct FrostedCard: ViewModifier {
    var tint: Color?
    var cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(tint.map { $0.opacity(0.18) } ?? Color.white.opacity(0.08)))
            .background(shape.fill(.ultraThinMaterial).opacity(0.55))
            .overlay(shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.45) : Color.white.opacity(0.28),
                                        lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// A soft highlight under the pointer, like rows in Control Center.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(hovered ? 0.07 : 0)))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Whole-row buttons: hover highlight, a deeper press, the pointing hand.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowButtonBody(configuration: configuration) }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0)))
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// A small round button for row actions (Stop). A frosted circle rather than glass: glass
/// inside clear glass reads as a heavy dark disc.
struct CircleIconButton: View {
    var symbol: String
    var label: String
    var size: CGFloat = 24
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.36, weight: .bold)).frame(width: size, height: size)
        }
        .buttonStyle(CircleButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct CircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CircleBody(configuration: configuration) }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovered && enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.2 : hovered ? 0.13 : 0.07)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

// MARK: Identity

/// Which service an account belongs to, as a neutral glyph in the provider's colour. The providers' own logos may
/// be used only with their permission (docs/TERMS.md), so Agneta doesn't ship them.
struct ProviderIcon: View {
    var kind: AccountKind
    var size: CGFloat = 30
    /// In a tile (rows, lists) or bare (inline beside text).
    var framed = true

    private var symbol: String {
        switch kind {
        case .claude: "asterisk"
        case .chatGPT: "sparkle"
        case .anthropicKey, .openAIKey: "key.fill"
        }
    }

    var body: some View {
        if framed { tile } else {
            Image(systemName: symbol).font(.system(size: size * 0.8, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }

    private var tile: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(Palette.glyph(kind))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.tile(kind).opacity(0.95), Palette.tile(kind).opacity(0.7)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5).blendMode(.plusLighter))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// The requesting app's own icon when its bundle is known, otherwise a quiet letter tile.
struct AppIcon: View {
    var name: String
    var identifier: String?
    var size: CGFloat = 30

    var body: some View {
        if let identifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))).resizable().frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [Color(red: 0.27, green: 0.35, blue: 0.41), Color(red: 0.1, green: 0.14, blue: 0.17)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }
}

/// Agneta's mark in a glass tile, in the app icon's evening colours.
struct MarkTile: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: Mark.image(size: size * 0.62)).renderingMode(.template)
            .foregroundStyle(LinearGradient(colors: Palette.evening.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .glassSurface(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Status

/// A breathing dot for running work; still when Reduce Motion is on.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle().fill(Palette.running).frame(width: 7, height: 7)
            .background(Circle().fill(Palette.running.opacity(0.35)).scaleEffect(pulse && !reduceMotion ? 2.4 : 1).opacity(pulse && !reduceMotion ? 0 : 0.8))
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
            .accessibilityLabel("Running")
    }
}

/// A rounded capsule label, e.g. "Sign in again".
struct StatusPill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Section title inside the panel and windows.
struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A download an engine needs: how far along, or why it failed with a way to try again.
struct DownloadStatus: View {
    var download: EngineDownload
    var retry: () -> Void

    var body: some View {
        if let problem = download.problem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(problem).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry).controlSize(.small)
            }
            .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Downloading \(download.title)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if let fraction = download.fraction { ProgressView(value: fraction).controlSize(.small) } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                Text(download.amount).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
