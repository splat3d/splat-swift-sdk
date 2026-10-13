import SwiftUI
import UIKit
import CoreText

// MARK: - Hairline: Splat3D's look
//
// The relaunch design (round 5, October 2026): paper and ink with one blue
// accent, Rinse. Ruled boxes with 3 pt corners, no shadows, no glass, no
// pills. The accent marks only what you can act on or what is moving. Type is
// Hanken Grotesk for text and headlines, and Martian Mono at 87.5% width for
// code, ids and data labels.
//
//   Palette ──> colors for light and dark
//   TypeStyle ──> .typeStyle(.body): bundled variable fonts, Dynamic Type
//   Panel, MonoLabel, Tag, StatusDot, SquareTabs, NoticeBox
//   HairlineButtonStyle: .primary (the one action), .ghost, .destructive
//   Mark, Logo: mark G·5 and the splat3D wordmark

// MARK: - Palette

/// Hairline colors. Each follows the light or dark appearance.
enum Palette {

    /// The same colors for UIKit: navigation bar appearance and SceneKit.
    enum UI {
        static let paper = dynamic(light: 0xF9FAFB, dark: 0x0D0E10)
        static let panel = dynamic(light: 0xFFFFFF, dark: 0x15171A)
        static let ink = dynamic(light: 0x16191B, dark: 0xEBEDEF)
        static let graphite = dynamic(light: 0x575B60, dark: 0x9B9FA3)
        static let faint = dynamic(light: 0x8A8E93, dark: 0x6E7276)
        static let rule = dynamic(light: 0xD9DBDD, dark: 0x292C2E)
        static let mist = dynamic(light: 0xEFF0F2, dark: 0x111214)
        static let accent = dynamic(light: 0x0064B8, dark: 0x7AC8F5)
        static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0D0E10)
        /// The accent's split partner, the mark's second channel.
        static let split = dynamic(light: 0x7FB4E3, dark: 0x2F6FA8)
        static let accentTint = dynamic(light: 0xE3EEF8, dark: 0x14212D)
        static let alarm = dynamic(light: 0xC52C2A, dark: 0xEE6E63)
        static let alarmTint = dynamic(light: 0xFBEAEA, dark: 0x2A1615)

        /// A color for each appearance, from 0xRRGGBB.
        private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
            UIColor { traits in
                rgb(traits.userInterfaceStyle == .dark ? dark : light)
            }
        }

        private static func rgb(_ hex: UInt32) -> UIColor {
            let channel = { (shift: UInt32) in CGFloat((hex >> shift) & 0xFF) / 255 }
            return UIColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 1)
        }
    }

    static let paper = Color(uiColor: UI.paper)
    static let panel = Color(uiColor: UI.panel)
    static let ink = Color(uiColor: UI.ink)
    static let graphite = Color(uiColor: UI.graphite)
    static let faint = Color(uiColor: UI.faint)
    static let rule = Color(uiColor: UI.rule)
    static let mist = Color(uiColor: UI.mist)
    static let accent = Color(uiColor: UI.accent)
    static let onAccent = Color(uiColor: UI.onAccent)
    static let split = Color(uiColor: UI.split)
    static let accentTint = Color(uiColor: UI.accentTint)
    static let alarm = Color(uiColor: UI.alarm)
    static let alarmTint = Color(uiColor: UI.alarmTint)
}

// MARK: - Geometry

enum Hairline {
    /// Corner radius of every box and button.
    static let corner: CGFloat = 3
    /// Width of a rule.
    static let rule: CGFloat = 1
    /// Horizontal page margin.
    static let margin: CGFloat = 20
    /// Smallest comfortable touch target (Apple's Human Interface Guidelines).
    static let touchTarget: CGFloat = 44

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }
}

// MARK: - Type

/// A text style: face, size and weight at the default Dynamic Type size, and
/// the system style it scales like.
struct TypeStyle {

    enum Face {
        case sans
        case mono
    }

    let face: Face
    let size: CGFloat
    /// The `wght` axis value, 100–900.
    let weight: CGFloat
    let scalesLike: UIFont.TextStyle
    /// Letter spacing, in ems.
    var tracking: CGFloat = 0
    var uppercase = false

    /// Screen headlines: upright Hanken at 650, tight.
    static let display = TypeStyle(face: .sans, size: 30, weight: 650, scalesLike: .largeTitle, tracking: -0.03)
    static let title = TypeStyle(face: .sans, size: 19, weight: 600, scalesLike: .title3, tracking: -0.02)
    static let body = TypeStyle(face: .sans, size: 16, weight: 400, scalesLike: .body)
    static let bodyStrong = TypeStyle(face: .sans, size: 16, weight: 600, scalesLike: .body)
    static let footnote = TypeStyle(face: .sans, size: 13.5, weight: 400, scalesLike: .footnote)
    static let button = TypeStyle(face: .sans, size: 15, weight: 600, scalesLike: .body)
    /// The "splat3D" wordmark beside the mark.
    static let wordmark = TypeStyle(face: .sans, size: 17, weight: 600, scalesLike: .headline, tracking: -0.02)
    /// A navigation bar's inline title.
    static let navigationTitle = TypeStyle(face: .sans, size: 17, weight: 600, scalesLike: .headline)
    /// Small uppercase mono: eyebrows, column heads, field names.
    static let label = TypeStyle(face: .mono, size: 11, weight: 500, scalesLike: .caption2, tracking: 0.06, uppercase: true)
    /// Mono values: ids, counts, sizes.
    static let data = TypeStyle(face: .mono, size: 13, weight: 400, scalesLike: .footnote)
    static let code = TypeStyle(face: .mono, size: 12, weight: 400, scalesLike: .caption1)
}

/// The bundled variable fonts, both under the SIL Open Font License (see
/// Fonts/OFL-HankenGrotesk.txt and Fonts/OFL-MartianMono.txt). If one isn't
/// registered, the system font with the same role stands in.
enum Typeface {

    /// PostScript names of the fonts' default instances.
    private static let sansName = "HankenGrotesk-Regular"
    private static let monoName = "MartianMono-SemiExpandedRegular"

    /// Martian Mono runs at 87.5% width, as on splat-3d.com.
    private static let monoWidth: CGFloat = 87.5

    /// OpenType axis tags as four-character codes.
    private static let weightAxis = NSNumber(value: 0x7767_6874) // 'wght'
    private static let widthAxis = NSNumber(value: 0x7764_7468) // 'wdth'

    private static let variationKey = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)

    static func font(_ face: TypeStyle.Face, size: CGFloat, weight: CGFloat) -> UIFont {
        let name = face == .sans ? sansName : monoName
        guard UIFont(name: name, size: size) != nil else {
            return fallback(face, size: size, weight: weight)
        }

        var axes: [NSNumber: CGFloat] = [weightAxis: weight]
        if face == .mono {
            axes[widthAxis] = monoWidth
        }
        let descriptor = UIFontDescriptor(fontAttributes: [.name: name, variationKey: axes])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// SF Pro and SF Mono at the nearest system weight.
    private static func fallback(_ face: TypeStyle.Face, size: CGFloat, weight: CGFloat) -> UIFont {
        let systemWeight: UIFont.Weight = weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular
        return face == .sans
            ? .systemFont(ofSize: size, weight: systemWeight)
            : .monospacedSystemFont(ofSize: size, weight: systemWeight)
    }
}

/// Applies a ``TypeStyle``, scaled for the environment's Dynamic Type size.
private struct TypeStyleModifier: ViewModifier {
    let style: TypeStyle

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let size = UIFontMetrics(forTextStyle: style.scalesLike).scaledValue(for: style.size, compatibleWith: traits)
        let font = Typeface.font(style.face, size: size, weight: style.weight)
        return content
            .font(Font(font))
            .tracking(style.tracking * size)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

extension View {
    func typeStyle(_ style: TypeStyle) -> some View {
        modifier(TypeStyleModifier(style: style))
    }
}

// MARK: - Surfaces and labels

/// A ruled box on the page ground: no fill, no shadow.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Hairline.shape.strokeBorder(Palette.rule, lineWidth: Hairline.rule))
    }
}

/// A hairline between rows of a ``Panel``.
struct Rule: View {
    var color = Palette.rule

    var body: some View {
        color.frame(height: Hairline.rule)
    }
}

/// Small uppercase mono label.
struct MonoLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .typeStyle(.label)
            .foregroundStyle(Palette.graphite)
    }
}

/// A ruled mono tag, for presets and flags (never a pill).
struct Tag: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .typeStyle(.label)
            .foregroundStyle(Palette.graphite)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Hairline.shape.strokeBorder(Palette.rule, lineWidth: Hairline.rule))
    }
}

/// One label and value row in a ``Panel``: "SPLATS   1.9M".
struct FactRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            // At accessibility sizes the label goes above its value: side by
            // side, labels broke mid-word ("CHARG ES").
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    MonoLabel(label)
                    value
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    MonoLabel(label)
                        .frame(minWidth: 84, alignment: .leading)
                    value
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Status: a dot with text, never a colored badge

enum DotState: Equatable {
    /// Finished: ink.
    case done
    /// Moving: an accent ring that fills with progress, 0...1.
    case running(Double)
    /// Not started: a dashed ring.
    case waiting
    /// Failed: alarm.
    case failed
}

struct StatusDot: View {
    let state: DotState

    private static let size: CGFloat = 10
    private static let ringWidth: CGFloat = 1.5
    private static let dash: [CGFloat] = [2, 2]

    var body: some View {
        dot
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var dot: some View {
        switch state {
        case .done:
            Circle().fill(Palette.ink)
        case .failed:
            Circle().fill(Palette.alarm)
        case .waiting:
            Circle().strokeBorder(Palette.graphite, style: StrokeStyle(lineWidth: Self.ringWidth, dash: Self.dash))
        case .running(let progress):
            ZStack {
                Circle().strokeBorder(Palette.accent, lineWidth: Self.ringWidth)
                ProgressWedge(progress: min(max(progress, 0), 1))
                    .fill(Palette.accent)
            }
        }
    }
}

/// A pie slice from twelve o'clock, clockwise, for ``StatusDot``.
private struct ProgressWedge: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        // In SwiftUI's flipped coordinates, clockwise: false draws clockwise.
        path.addArc(
            center: center,
            radius: rect.width / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * progress),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// A dot and its text: "● Ready".
struct StatusLabel: View {
    let state: DotState
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: state)
            Text(text)
                .typeStyle(.footnote)
                .foregroundStyle(Palette.ink)
        }
    }
}

// MARK: - Square tabs

/// Square tabs with mono labels. The selected one gets an ink border.
struct SquareTabs<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static var spacing: CGFloat { 6 }
    /// At accessibility sizes a row of four truncates "STANDARD": two a row.
    private static var accessibilityColumns: Int { 2 }
    private static var minimumScale: CGFloat { 0.8 }
    /// "STANDARD" needs 0.73 to fit half a phone's width at the largest size.
    private static var accessibilityMinimumScale: CGFloat { 0.6 }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            let column = GridItem(.flexible(), spacing: Self.spacing)
            LazyVGrid(columns: Array(repeating: column, count: Self.accessibilityColumns), spacing: Self.spacing) {
                tabs
            }
        } else {
            HStack(spacing: Self.spacing) {
                tabs
            }
        }
    }

    private var tabs: some View {
        ForEach(options, id: \.self) { option in
            let selected = option == selection
            Button {
                selection = option
            } label: {
                Text(title(option))
                    .typeStyle(.label)
                    .foregroundStyle(selected ? Palette.ink : Palette.graphite)
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? Self.accessibilityMinimumScale : Self.minimumScale)
                    .frame(maxWidth: .infinity, minHeight: Hairline.touchTarget)
                    .contentShape(Hairline.shape)
                    .overlay(Hairline.shape.strokeBorder(selected ? Palette.ink : Palette.rule, lineWidth: Hairline.rule))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

// MARK: - Buttons

struct HairlineButtonStyle: ButtonStyle {

    enum Variant {
        /// The one action a screen wants you to take: accent fill.
        case primary
        /// Everything else: a ruled box.
        case ghost
        /// A ruled box with alarm text, for deleting and discarding.
        case destructive
    }

    var variant: Variant = .primary

    @Environment(\.isEnabled) private var isEnabled

    private static let pressedOpacity = 0.8
    private static let disabledOpacity = 0.4

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeStyle(.button)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: Hairline.touchTarget)
            .padding(.horizontal, 14)
            .background(variant == .primary ? Palette.accent : Color.clear, in: Hairline.shape)
            .overlay(Hairline.shape.strokeBorder(border(pressed: configuration.isPressed), lineWidth: Hairline.rule))
            .contentShape(Hairline.shape)
            .opacity(isEnabled ? (configuration.isPressed ? Self.pressedOpacity : 1) : Self.disabledOpacity)
    }

    private var foreground: Color {
        switch variant {
        case .primary:
            return Palette.onAccent
        case .ghost:
            return Palette.ink
        case .destructive:
            return Palette.alarm
        }
    }

    private func border(pressed: Bool) -> Color {
        if variant == .primary {
            return Palette.accent
        }
        return pressed ? Palette.graphite : Palette.rule
    }
}

extension ButtonStyle where Self == HairlineButtonStyle {
    static var primary: HairlineButtonStyle { HairlineButtonStyle(variant: .primary) }
    static var ghost: HairlineButtonStyle { HairlineButtonStyle(variant: .ghost) }
    static var destructive: HairlineButtonStyle { HairlineButtonStyle(variant: .destructive) }
}

// MARK: - Notices

/// A boxed message: a title, a detail, and optional actions below.
struct NoticeBox<Actions: View>: View {

    enum Tone {
        case neutral
        case alarm
        /// An action that went through, such as a delete.
        case done
    }

    let tone: Tone
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    /// The dot says what the box is: a failure, a finished action, or news.
    private var dot: DotState {
        switch tone {
        case .neutral:
            return .waiting
        case .alarm:
            return .failed
        case .done:
            return .done
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(state: dot)
                Text(title)
                    .typeStyle(.bodyStrong)
                    .foregroundStyle(Palette.ink)
            }
            Text(detail)
                .typeStyle(.footnote)
                .foregroundStyle(Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .alarm ? Palette.alarmTint : Color.clear, in: Hairline.shape)
        .overlay(Hairline.shape.strokeBorder(tone == .alarm ? Palette.alarm.opacity(0.4) : Palette.rule, lineWidth: Hairline.rule))
    }
}

extension NoticeBox where Actions == EmptyView {
    init(tone: Tone, title: String, detail: String) {
        self.init(tone: tone, title: title, detail: detail) { EmptyView() }
    }
}

// MARK: - Mark G·5

/// Mark G·5: a splat drawn as two contour rings tilted -32°, with an S of two
/// half-circles at its center, drawn twice, shifted sideways, in the accent
/// and its split partner. The channels multiply on light grounds and screen
/// on dark. Same geometry as the web's mark (64-unit box).
struct Mark: View {

    @Environment(\.colorScheme) private var colorScheme

    private struct Ring {
        let rx: CGFloat
        let ry: CGFloat
        let width: CGFloat
        let opacity: Double
    }

    private static let box: CGFloat = 64
    private static let center = CGPoint(x: 32, y: 32)
    private static let ringTilt = Angle.degrees(-32)
    private static let rings = [
        Ring(rx: 27.5, ry: 15.5, width: 2.2, opacity: 0.36),
        Ring(rx: 19, ry: 10.7, width: 2.6, opacity: 0.7),
    ]
    private static let sWidth: CGFloat = 5.2
    /// Sideways offset of each channel.
    private static let channelSplit: CGFloat = 1.8

    /// The web's S, "M37.2 23 A6 6 0 1 0 32 32 A6 6 0 1 1 26.8 41": the top
    /// bowl runs counterclockwise around (32, 26), the bottom one clockwise
    /// around (32, 38). In SwiftUI's flipped coordinates, `clockwise: true`
    /// draws counterclockwise on screen.
    private static let sPath: Path = {
        var path = Path()
        path.addArc(center: CGPoint(x: 32, y: 26), radius: 6, startAngle: .degrees(-30), endAngle: .degrees(90), clockwise: true)
        path.addArc(center: CGPoint(x: 32, y: 38), radius: 6, startAngle: .degrees(-90), endAngle: .degrees(150), clockwise: false)
        return path
    }()

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / Self.box
            context.scaleBy(x: unit, y: unit)

            let channels: [(CGFloat, Color)] = [(-Self.channelSplit, Palette.accent), (Self.channelSplit, Palette.split)]
            for (offset, color) in channels {
                var channel = context
                channel.blendMode = colorScheme == .dark ? .screen : .multiply
                // Each channel is drawn whole, then blended onto the other.
                channel.drawLayer { layer in
                    layer.translateBy(x: offset, y: 0)
                    Self.drawRings(in: layer, color: color)
                    layer.stroke(Self.sPath, with: .color(color), style: StrokeStyle(lineWidth: Self.sWidth, lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func drawRings(in context: GraphicsContext, color: Color) {
        var tilted = context
        tilted.translateBy(x: center.x, y: center.y)
        tilted.rotate(by: ringTilt)
        for ring in rings {
            let oval = CGRect(x: -ring.rx, y: -ring.ry, width: ring.rx * 2, height: ring.ry * 2)
            tilted.stroke(Path(ellipseIn: oval), with: .color(color.opacity(ring.opacity)), lineWidth: ring.width)
        }
    }
}

/// The mark beside the "splat3D" wordmark.
struct Logo: View {
    private static let markSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            Mark()
                .frame(width: Self.markSize, height: Self.markSize)
            Text("splat3D")
                .typeStyle(.wordmark)
                .foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("splat3D")
    }
}

// MARK: - UIKit appearance

extension Hairline {
    /// The largest inline title a 44 pt bar fits: the headline's size at
    /// the first accessibility size.
    private static let inlineTitleMaximum: CGFloat = 28

    /// Navigation bars in Hairline type and colors: paper ground, a rule
    /// beneath, Hanken titles.
    static func applyNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Palette.UI.paper
        appearance.shadowColor = Palette.UI.rule
        // Titles follow Dynamic Type, as TypeStyle does in SwiftUI.
        appearance.titleTextAttributes = [
            .font: scaledFont(.navigationTitle, maximum: inlineTitleMaximum),
            .foregroundColor: Palette.UI.ink,
        ]
        appearance.largeTitleTextAttributes = [
            .font: scaledFont(.display),
            .foregroundColor: Palette.UI.ink,
        ]
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
    }

    /// A style's font at the reader's text size, at most `maximum` points.
    private static func scaledFont(_ style: TypeStyle, maximum: CGFloat? = nil) -> UIFont {
        let font = Typeface.font(style.face, size: style.size, weight: style.weight)
        let metrics = UIFontMetrics(forTextStyle: style.scalesLike)
        guard let maximum else {
            return metrics.scaledFont(for: font)
        }
        return metrics.scaledFont(for: font, maximumPointSize: maximum)
    }
}
