import SwiftUI
import UIKit
import CoreText

// MARK: - Theme: Splat3D's look on iOS
//
// Liquid Glass on iOS 26, bordered buttons and materials before it. Glass is
// for the layer that floats over content: the action bar pinned at the foot
// of a screen, the toolbars, and the overlays on the camera. Content is an
// inset grouped list, as in Settings, so its margins and corners are the
// system's. One accent, Rinse blue, fills the primary action and marks
// progress and status; other labels on glass stay monochrome. Hanken
// Grotesk sets the headlines, Martian Mono the data (scene IDs, numbers,
// sizes), and the system font everything else.
//
//   Palette ─────> the brand's colors, with Increase Contrast variants
//   TypeStyle ───> .typeStyle(.display): the bundled fonts, Dynamic Type
//   FactRow, NoticeCard ──> a list's rows and sections
//   StatusDot, StatusLabel ──> a colored dot and its text
//   .actionStyle(_:) ──> capsule buttons: primary, secondary, destructive
//   .actionBar { } ──> a screen's actions, pinned over the content
//   MoreMenu ────> a screen's rarer actions, in the toolbar
//   ToolbarSymbol, CloseButton ──> toolbar buttons: bare symbols, a sheet's close
//   .glassSurface(in:), GlassGroup ──> readouts and controls over the camera
//   .darkBars() ──> the viewer's navigation bar and toolbar
//   Mark ────────> mark G·5, for large placeholders
//
// Each helper switches on the OS once, so views never do:
//
//   iOS 26+                  iOS 17–25
//   .glassProminent    <──>  .borderedProminent   primary
//   .glass             <──>  .bordered            secondary, destructive
//   .bordered          <──>  .bordered            a button in a row (never glass)
//   safeAreaBar        <──>  safeAreaInset on .bar   the action bar
//   "info"             <──>  "info.circle"           a toolbar symbol
//   Button(role: .close) <─> Done                    closes a sheet
//   .glassEffect       <──>  .regularMaterial     overlays
//   GlassEffectContainer <─> the content alone

// MARK: - Palette

/// The brand's colors, each following the light or dark appearance and
/// Increase Contrast, and the system's grouped grounds.
enum Palette {

    /// The same colors for UIKit: SceneKit's mesh material.
    enum UI {
        // With Increase Contrast, text colors move away from the ground
        // (accent 6.0 to 8.6:1 on white, alarm 5.6 to 8.1:1), and the alarm
        // tint moves away from the alarm text on it.
        static let accent = dynamic(Shades(light: 0x0064B8, dark: 0x7AC8F5), increased: Shades(light: 0x004C8F, dark: 0xA6DCFA))
        static let onAccent = dynamic(Shades(light: 0xFFFFFF, dark: 0x0D0E10), increased: Shades(light: 0xFFFFFF, dark: 0x000000))
        /// The accent's split partner, the mark's second channel.
        static let split = dynamic(Shades(light: 0x7FB4E3, dark: 0x2F6FA8), increased: Shades(light: 0x5E9DD8, dark: 0x3D84C4))
        static let alarm = dynamic(Shades(light: 0xC52C2A, dark: 0xEE6E63), increased: Shades(light: 0x9C1C1A, dark: 0xFF968D))
        static let alarmTint = dynamic(Shades(light: 0xFBEAEA, dark: 0x2A1615), increased: Shades(light: 0xFFF2F2, dark: 0x1E0E0D))

        /// A color for light and for dark, each 0xRRGGBB.
        private struct Shades {
            let light: UInt32
            let dark: UInt32
        }

        /// A color for each appearance, and a stronger pair for Increase
        /// Contrast.
        private static func dynamic(_ standard: Shades, increased: Shades) -> UIColor {
            UIColor { traits in
                let shades = traits.accessibilityContrast == .high ? increased : standard
                return rgb(traits.userInterfaceStyle == .dark ? shades.dark : shades.light)
            }
        }

        private static func rgb(_ hex: UInt32) -> UIColor {
            let channel = { (shift: UInt32) in CGFloat((hex >> shift) & 0xFF) / 255 }
            return UIColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 1)
        }
    }

    static let accent = Color(uiColor: UI.accent)
    /// Text on an accent fill.
    static let onAccent = Color(uiColor: UI.onAccent)
    static let split = Color(uiColor: UI.split)
    static let alarm = Color(uiColor: UI.alarm)
    static let alarmTint = Color(uiColor: UI.alarmTint)

    /// The screen's ground, as in Settings.
    static let ground = Color(uiColor: .systemGroupedBackground)
    /// A card on the ground.
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    /// Where a picture will go.
    static let placeholder = Color(uiColor: .tertiarySystemFill)
    /// Finished and working: a status that needs nothing from you.
    static let done = Color(uiColor: .systemGreen)
    /// Not started.
    static let waiting = Color(uiColor: .tertiaryLabel)
}

// MARK: - Geometry

/// Lists take their margins and corners from the system. These are for what
/// floats over the camera and the viewer.
enum Theme {
    /// Space between the screen's edge and an overlay: the system's margin
    /// on a phone, as the lists have.
    static let margin: CGFloat = 16
}

// MARK: - Type

/// A text style in a bundled font: face, size and weight at the default
/// Dynamic Type size, and the system style it scales like. Everything else
/// uses the system's text styles.
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

    /// Screen headlines: Hanken at 650, tight.
    static let display = TypeStyle(face: .sans, size: 28, weight: 650, scalesLike: .title1, tracking: -0.025)
    /// A message's headline, as in the viewer.
    static let title = TypeStyle(face: .sans, size: 20, weight: 600, scalesLike: .title3, tracking: -0.02)
    /// Mono values: scene IDs, counts, sizes.
    static let data = TypeStyle(face: .mono, size: 14, weight: 400, scalesLike: .subheadline)
    /// Smaller mono values, beside footnote text.
    static let smallData = TypeStyle(face: .mono, size: 12, weight: 400, scalesLike: .caption1)

    /// `string` in this style as Text, to run inside other text: a scene ID
    /// in mono, then words in the system font.
    func text(_ string: String, at dynamicTypeSize: DynamicTypeSize) -> Text {
        let font = uiFont(at: dynamicTypeSize)
        return Text(string)
            .font(Font(font))
            .tracking(tracking * font.pointSize)
    }

    /// The font, scaled for a Dynamic Type size.
    fileprivate func uiFont(at dynamicTypeSize: DynamicTypeSize) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let scaled = UIFontMetrics(forTextStyle: scalesLike).scaledValue(for: size, compatibleWith: traits)
        return Typeface.font(face, size: scaled, weight: weight)
    }
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
        let font = style.uiFont(at: dynamicTypeSize)
        return content
            .font(Font(font))
            .tracking(style.tracking * font.pointSize)
    }
}

extension View {
    func typeStyle(_ style: TypeStyle) -> some View {
        modifier(TypeStyleModifier(style: style))
    }
}

// MARK: - Rows

/// How a fact row lays out its label and value.
enum FactLayout {
    /// The label on the left, the value on the right: "Splats   1.9M".
    case sideBySide
    /// The label, then the value under it, left-aligned: for a sentence,
    /// which reads badly right-aligned.
    case stacked
}

/// One label and value row in a list, as in Settings. A stacked row reads
/// as in Contacts: a small label over the value.
struct FactRow<Value: View>: View {
    let label: String
    var layout = FactLayout.sideBySide
    @ViewBuilder let value: Value

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            // At accessibility sizes every row stacks: side by side, label
            // and value broke mid-word.
            if layout == .stacked || dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    value
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label)
                    value
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status: a colored dot with text

enum DotState: Equatable {
    /// Finished: green.
    case done
    /// Moving: an accent ring that fills with progress, 0...1.
    case running(Double)
    /// Moving, with no measure of how far: a small spinner.
    case busy
    /// Not started: grey.
    case waiting
    /// Failed: red.
    case failed
}

struct StatusDot: View {
    let state: DotState

    /// Grows with the text, as the text beside it does.
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 10
    /// How far above the text's baseline the dot's centre sits: about half
    /// a lowercase letter's height, so the dot lines up with the first line.
    @ScaledMetric(relativeTo: .body) private var baselineOffset: CGFloat = 6

    private static let ringWidth: CGFloat = 2.5
    private static let trackOpacity = 0.25
    /// The least of the ring that shows while running, so 0% still reads
    /// as started.
    private static let minimumArc = 0.12
    /// The system spinner's side, and how much wider than a dot it shows:
    /// at a dot's size its spokes don't read.
    private static let spinnerSide: CGFloat = 20
    private static let spinnerScale: CGFloat = 1.4

    var body: some View {
        dot
            .frame(width: size, height: size)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions[VerticalAlignment.center] + baselineOffset
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var dot: some View {
        switch state {
        case .done:
            Circle().fill(Palette.done)
        case .failed:
            Circle().fill(Palette.alarm)
        case .waiting:
            Circle().fill(Palette.waiting)
        case .running(let progress):
            // A track, and the progress drawn over it from twelve o'clock.
            ZStack {
                Circle()
                    .stroke(Palette.accent.opacity(Self.trackOpacity), lineWidth: Self.ringWidth)
                Circle()
                    .trim(from: 0, to: min(max(progress, Self.minimumArc), 1))
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(Self.ringWidth / 2)
        case .busy:
            // A ring with nothing to fill sat still and read as stalled.
            ProgressView()
                .tint(Palette.accent)
                .fixedSize()
                .scaleEffect(size * Self.spinnerScale / Self.spinnerSide)
        }
    }
}

/// A dot and its text: "● Ready". The text takes the font and color around it.
struct StatusLabel: View {
    let state: DotState
    let text: String

    var body: some View {
        // By the first line, when the text wraps.
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            StatusDot(state: state)
            Text(text)
        }
    }
}

// MARK: - Notices

/// A message as a section of its own: a symbol, a title, a detail, and
/// optional actions. An alarm sits on the alarm tint.
struct NoticeCard<Actions: View>: View {

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

    private var symbol: String {
        switch tone {
        case .neutral:
            return "info.circle.fill"
        case .alarm:
            return "exclamationmark.triangle.fill"
        case .done:
            return "checkmark.circle.fill"
        }
    }

    private var symbolColor: Color {
        switch tone {
        case .neutral:
            return .secondary
        case .alarm:
            return Palette.alarm
        case .done:
            return Palette.done
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .foregroundStyle(symbolColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Text(detail)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                actions
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            // `nil` keeps the system's row background.
            .listRowBackground(tone == .alarm ? Palette.alarmTint : nil)
        }
    }
}

extension NoticeCard where Actions == EmptyView {
    init(tone: Tone, title: String, detail: String) {
        self.init(tone: tone, title: title, detail: detail) { EmptyView() }
    }
}

// MARK: - Buttons

/// What a button does, which sets its look.
enum ActionRole {
    /// The one action a screen wants you to take: the accent, filled.
    case primary
    /// Everything else.
    case secondary
    /// Deleting and discarding: red.
    case destructive
}

/// How wide a button is, which says where it sits.
enum ActionWidth {
    /// The width of its container: the actions in a screen's action bar,
    /// or over the camera. Glass on iOS 26.
    case full
    /// The width of its label: a button in a list row or on the ground.
    /// Content, so bordered on every OS, never glass.
    case fitted
}

extension View {
    /// A capsule button: glass on iOS 26, bordered before it, and bordered
    /// on every OS when fitted. Works on Button, Link and NavigationLink.
    func actionStyle(_ role: ActionRole, width: ActionWidth = .full) -> some View {
        buttonStyle(ActionButtonStyle(role: role, width: width))
    }
}

/// Rebuilds the button with a full-width label, then gives it the system's
/// glass or bordered style, so Link and NavigationLink get it too.
private struct ActionButtonStyle: PrimitiveButtonStyle {
    let role: ActionRole
    let width: ActionWidth

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            configuration.trigger()
        } label: {
            ActionLabel(label: configuration.label, role: role, width: width)
        }
        .modifier(ActionLook(role: role, width: width))
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// The label in its width and color: the accent's text color on the
/// accent, and monochrome on glass.
private struct ActionLabel<Label: View>: View {
    let label: Label
    let role: ActionRole
    let width: ActionWidth

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)
            .frame(maxWidth: width == .full ? .infinity : nil)
            .foreground(color)
    }

    /// `nil` leaves the style's color: the tint on a bordered button, red on
    /// a destructive one. Disabled, the system greys the fill and the text
    /// together, so there is no color of its own then.
    private var color: Color? {
        guard isEnabled, width == .full else {
            return nil
        }
        switch role {
        case .primary:
            return Palette.onAccent
        case .secondary:
            // Color on glass is for meaning: a secondary label is plain.
            if #available(iOS 26, *) {
                return .primary
            }
            return nil
        case .destructive:
            return nil
        }
    }
}

private extension View {
    /// A foreground color only when there is one.
    @ViewBuilder
    func foreground(_ color: Color?) -> some View {
        if let color {
            foregroundStyle(color)
        } else {
            self
        }
    }
}

/// The system style for a role and width.
private struct ActionLook: ViewModifier {
    let role: ActionRole
    let width: ActionWidth

    func body(content: Content) -> some View {
        if width == .fitted {
            content.buttonStyle(.bordered).tint(tint)
        } else {
            floating(content)
        }
    }

    /// Glass on iOS 26, bordered before it.
    @ViewBuilder
    private func floating(_ content: Content) -> some View {
        if #available(iOS 26, *) {
            switch role {
            case .primary:
                content.buttonStyle(.glassProminent).tint(Palette.accent)
            case .secondary:
                content.buttonStyle(.glass)
            case .destructive:
                content.buttonStyle(.glass).tint(Palette.alarm)
            }
        } else {
            switch role {
            case .primary:
                content.buttonStyle(.borderedProminent).tint(Palette.accent)
            case .secondary, .destructive:
                content.buttonStyle(.bordered).tint(tint)
            }
        }
    }

    private var tint: Color {
        role == .destructive ? Palette.alarm : Palette.accent
    }
}

// MARK: - Action bar

extension View {
    /// Pins a screen's actions to its foot, over the content, which scrolls
    /// under them: a bar with the scroll edge effect on iOS 26, and on the
    /// bar material before it. Holds the primary action and at most one
    /// secondary; rarer ones go in a ``MoreMenu``.
    func actionBar<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        modifier(ActionBar(actions: actions()))
    }
}

private struct ActionBar<Actions: View>: ViewModifier {
    let actions: Actions

    private static var spacing: CGFloat { 12 }
    /// Space above and below the buttons, inside the bar.
    private static var inset: CGFloat { 8 }

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .bottom) {
                stack
                    .padding(.horizontal, Theme.margin)
                    .padding(.vertical, Self.inset)
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    stack
                        .padding(.horizontal, Theme.margin)
                        .padding(.vertical, Self.inset * 1.5)
                }
                .background(.bar)
            }
        }
    }

    private var stack: some View {
        VStack(spacing: Self.spacing) {
            actions
        }
    }
}

// MARK: - More menu

/// A screen's rarer actions, such as opening the web viewer or deleting,
/// behind the toolbar's ellipsis.
struct MoreMenu<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Label("More", systemImage: ToolbarSymbol.named("ellipsis"))
        }
    }
}

// MARK: - Toolbar buttons

/// A toolbar button's symbol: bare on iOS 26, whose toolbar draws the circle
/// in glass, and circled before it. "info" is "info" or "info.circle".
enum ToolbarSymbol {
    static func named(_ name: String) -> String {
        if #available(iOS 26, *) {
            return name
        }
        return name + ".circle"
    }
}

/// Closes a sheet, from its toolbar: the system's close button, an X in
/// glass, on iOS 26, and Done before it.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .close, action: action)
        } else {
            Button("Done", action: action)
                .fontWeight(.semibold)
        }
    }
}

// MARK: - Glass surfaces

/// Whether a glass surface reacts to touch.
enum GlassInteraction {
    /// A label or readout.
    case none
    /// A control: it lights and flexes under a finger.
    case interactive
}

extension View {
    /// Liquid Glass in `shape` on iOS 26; a material, or `tint` if given, in
    /// the same shape before it. For what floats over the camera and the
    /// viewer, never for content.
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interaction: GlassInteraction = .none) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interaction: interaction))
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interaction: GlassInteraction

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else if let tint {
            content.background(tint, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }

    @available(iOS 26, *)
    private var glass: Glass {
        Glass.regular
            .tint(tint)
            .interactive(interaction == .interactive)
    }
}

/// Glass surfaces that blend into each other when close, on iOS 26. Before
/// it, just the content.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Dark bars

extension View {
    /// The navigation bar and toolbar of a screen that is always dark, such
    /// as the viewer: white titles and buttons in either appearance. On iOS
    /// 26 both stay glass over the picture; before it, they are solid black.
    func darkBars() -> some View {
        modifier(DarkBars())
    }
}

private struct DarkBars: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        } else {
            content
                .toolbarBackground(.black, for: .navigationBar, .bottomBar)
                .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
                .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        }
    }
}

// MARK: - Mark G·5

/// Mark G·5: a splat drawn as two contour rings tilted -32°, with an S of two
/// half-circles at its center, drawn twice, shifted sideways, in the accent
/// and its split partner. The channels multiply on light grounds and screen
/// on dark. Same geometry as the web's mark (64-unit box). It reads well
/// only large: the app icon, and the placeholder of a scene's picture.
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
