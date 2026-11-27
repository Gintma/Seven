import AppKit
import SwiftUI

/// Seven的设计规则：字号、间距、圆角、动效与图标尺寸的唯一来源。
/// 浮窗（AppKit）与设置、历史（SwiftUI）都从这里取值；其他文件不要直接写字号或时长数字。
/// 原则：
/// 1. 内容是主角，工具退后：原文与结果用“内容”字号，按钮与耗时用次要色。
/// 2. 交互强调色表示状态（钉住、成功、选中、焦点），错误和警告使用各自的语义色。品牌及功能图标可使用独立识别色。
/// 3. 动效只回答“点上了吗”与“状态变了吗”。
enum Design {
    enum Onboarding {
        static let contentSize = NSSize(width: 480, height: 440)
        static let welcomeFont = Font.system(size: 22, weight: .semibold)
        static let appIconSize: CGFloat = 120
        static let eyeResponse: TimeInterval = 0.10
        static let headResponse: TimeInterval = 0.24
        static let rowIconWidth: CGFloat = 22
        static let primaryLabelWidth: CGFloat = 84
    }

    /// 权限引导浮窗的度量，按授权页内容列贴附。
    enum PermissionGuide {
        static let width: CGFloat = 420
        static let sidebarWidth: CGFloat = 230
        static let minimumWidth: CGFloat = 240
        static let radius: CGFloat = 18
        static let cardRadius: CGFloat = 16
        static let cardInset: CGFloat = 6
        static let headerSpacing: CGFloat = 3
        static let contentSpacing: CGFloat = 6
        static let cardHeight: CGFloat = 48
        static let iconSize: CGFloat = 32
        static let headingFont = Font.system(size: 14)
        static let actionFont = Font.system(size: 15, weight: .semibold)
        static let closeFont = Font.system(size: 15, weight: .semibold)
        static let dragLabelFont = Font.system(size: 8, weight: .light)
        static let launchDuration: TimeInterval = 0.72
        static let wiggleAngle: Double = 12
        static let wiggleStep: TimeInterval = 0.22
    }

    // MARK: 排版

    enum Text {
        /// 历史正文段落内的附加行距，独立于视图之间的布局间距。
        static let bodyLineSpacing: CGFloat = 4

        /// 原文、每张卡片的结果、历史正文。
        case content
        /// 卡片标题、语言名：与 label 同字号，字重轻一档，让原文与结果更突出。
        case title
        /// 键帽等需要实体感的标签。
        case label
        /// 设置行常规标题和值：13pt regular，不继承标签的半粗字重。
        case settingsRow
        /// 词典分组、错误与操作说明。
        case body
        /// 词典辅助信息：12pt中等字重。
        case dictionaryAuxiliary
        /// 双语例句正文：14pt常规字重。
        case dictionaryExample
        /// 耗时、字数、例句、标签等注记。
        case note
        /// 需要对齐的数字：耗时、字数。
        case noteDigits
        case bodyDigits
        /// 诊断日志等等宽文本。
        case code
        /// 词典词头。
        case headword
        case sectionTitle
        case settingsPageTitle

        var size: CGFloat {
            switch self {
            case .content: return 16
            case .dictionaryExample: return 14
            case .settingsPageTitle: return 15
            case .title, .label, .settingsRow: return 13
            case .body, .bodyDigits, .dictionaryAuxiliary: return 12
            case .note, .noteDigits, .code: return 11
            case .headword: return 20
            case .sectionTitle: return 17
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .title, .dictionaryAuxiliary: return .medium
            case .label, .headword, .sectionTitle: return .semibold
            case .settingsPageTitle: return .bold
            case .bodyDigits: return .medium
            default: return .regular
            }
        }

        var nsFont: NSFont {
            switch self {
            case .noteDigits, .bodyDigits: return .monospacedDigitSystemFont(ofSize: size, weight: weight)
            case .code: return .monospacedSystemFont(ofSize: size, weight: weight)
            default: return .systemFont(ofSize: size, weight: weight)
            }
        }

        var font: Font {
            switch self {
            case .noteDigits, .bodyDigits: return .system(size: size, weight: swiftUIWeight).monospacedDigit()
            case .code: return .system(size: size, weight: swiftUIWeight, design: .monospaced)
            default: return .system(size: size, weight: swiftUIWeight)
            }
        }

        private var swiftUIWeight: Font.Weight {
            switch weight {
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            default: return .regular
            }
        }
    }

    // MARK: 布局：视图节奏与原生对齐分层

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        /// 区块内部的左右边距：输入框、卡片、提示里的文字都从这里开始，左边缘对齐。
        static let blockInset: CGFloat = m
        /// 区块右侧图标按钮距边缘的距离；按钮自带约 5 的留白，视觉上与 blockInset 对称。
        static let iconButtonEdge: CGFloat = s
    }

    /// macOS 原生表单的对齐度量，不按节奏刻度取整；设置页与历史窗口共用。
    enum Layout {
        static let dividerWidth: CGFloat = 1
        static let pageInset: CGFloat = 20
        static let cardInset: CGFloat = 10
    }

    enum History {
        static let windowSize = NSSize(width: 860, height: 600)
        static let minimumSize = NSSize(width: 720, height: 500)
        static let sidebarMinimum: CGFloat = 220
        static let sidebarIdeal: CGFloat = 250
        static let sidebarMaximum: CGFloat = 320
    }

    /// 词典音标行：为原生朗读按钮保留可点击区域，换行后仍与音标对齐。
    enum Dictionary {
        static let pronunciationButtonSize: CGFloat = 26
        static let pronunciationIndent = Space.xl
    }

    /// 设置页布局；服务面板外边距按原生 grouped Form 的实际卡片边缘对齐。
    enum ShortcutRecorder {
        static let width:CGFloat=280
        static let keycapsHeight:CGFloat=34
        static let shakeDistance:CGFloat=6
    }

    enum Settings {
        static let toolbarKeyWidth: CGFloat = 100
        static let toolbarVisibilityWidth: CGFloat = 48

        /// 原生主题菜单中的色样图标尺寸。
        static let themeSwatchWidth: CGFloat = 24
        static let themeSwatchHeight: CGFloat = 16

        /// 首选语言式原生紧凑列表行高。
        static let commonLanguageRowHeight: CGFloat = 24
        static let commonLanguageDescriptionHeight: CGFloat = 36
        static let commonLanguageActionsHeight: CGFloat = 28
        static let languageAdditionWidth: CGFloat = 516
        static let languageAdditionHeight: CGFloat = 400
        /// 对齐系统添加首选语言弹窗的边距、区块间距与普通列表文字缩进。
        static let languageAdditionInset: CGFloat = 20
        static let languageAdditionHeaderSpacing: CGFloat = 8
        /// 操作按钮上下对称的留白。
        static let languageAdditionActionsSpacing: CGFloat = 14
        static let languageAdditionRowInset: CGFloat = 14
        static let languageAdditionButtonLabelWidth: CGFloat = 46
        static let languageSearchWidth: CGFloat = 160
        /// 界面语言名称列从列表宽度的 40% 处开始。
        static let commonLanguageNativeColumnRatio: CGFloat = 0.4
        /// 原生 grouped Form 卡片的行内左右留白。
        static let commonLanguageCardInset = Layout.cardInset
        static let pageHorizontalInset = Layout.pageInset
        /// 统一工具栏在导航项外侧已留出 8pt。
        static let toolbarTitleLeadingPadding = pageHorizontalInset - Space.s
        /// 保留 grouped Form 顶部的 4pt 留白。
        static let formTopMarginAdjustment = -Space.l
        static let providerGridWidth: CGFloat = 320
        static let secondaryListWidth: CGFloat = 220
        static let secondaryRowHeight: CGFloat = 32
        static let listActionSize: CGFloat = 48
        static let controlHeight: CGFloat = 24
        /// 提示词编辑框为原三行默认高度的两倍，固定高度，内容在框内滚动。
        static let promptEditorHeight: CGFloat = 112
        static let segmentedThumbInset: CGFloat = 1
        static let actionRowHeight: CGFloat = 28
        static var rowFont: Font { Design.Text.settingsRow.font }
        static var groupFont: Font { Design.Text.label.font }
        static var groupNSFont: NSFont { Design.Text.label.nsFont }
        static var controlFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular)) }
        static var controlTextFont: Font { Font(controlFont) }
        static let logMinimumHeight: CGFloat = 240
        /// 关于页的现有应用图标展示尺寸。
        static let aboutIconSize: CGFloat = 80
        /// 侧栏功能图标的连续圆角方块及内部符号。
        static let sidebarIconSize: CGFloat = 20
        static let sidebarIconRadius: CGFloat = 5.5
        static let sidebarIconBorderWidth: CGFloat = 0.5
        static let sidebarSymbolSize: CGFloat = 12
        /// 放大图形较窄的书本和图钉，保持与其他符号的视觉重量接近。
        static let sidebarLargeSymbolSize: CGFloat = 13
        static let sidebarIconShadowRadius: CGFloat = 1.2
        static let sidebarIconShadowOffset: CGFloat = 1
        static let navigationWidth: CGFloat = 180
        static let windowWidth: CGFloat = 820
        static let minimumHeight: CGFloat = 560
        static let maximumHeight: CGFloat = 900
        static let sliderWidth: CGFloat = 180
        static let valueWidth: CGFloat = 120
    }

    /// 截图遮罩与选区边框的视觉参数。
    enum ScreenshotCapture {
        static let maskFill = NSColor.black.withAlphaComponent(0.5)
        static let borderWidth: CGFloat = 1
        static let cornerWidth: CGFloat = 3
        static let cornerMinimumSize: CGFloat = 20
        static let cornerOutside: CGFloat = 2
        static let cornerInside: CGFloat = 15
        /// 截图提示使用深色卡片与白色键帽。
        static let hintEdgeInset: CGFloat = 20
        static let hintHoverDistance: CGFloat = 12
        static let hintWidth: CGFloat = 208
        static let hintInset: CGFloat = 12
        static let hintRowHeight: CGFloat = 28
        static let hintTitleHeight: CGFloat = 20
        static let hintTitleSpacing: CGFloat = 8
        static let hintRadius: CGFloat = 12
        static let hintKeySize: CGFloat = 22
        static let hintKeyRadius: CGFloat = 5
        static let hintKeyGap: CGFloat = 12
        static let hintFill = NSColor(deviceRed: 0.10, green: 0.13, blue: 0.15, alpha: 0.88)
        static let hintBorder = NSColor.white.withAlphaComponent(0.18)
        static let hintText = NSColor.white
        static let hintKeyFill = NSColor(deviceWhite: 0.96, alpha: 1)
        static let hintKeyText = NSColor(deviceWhite: 0.12, alpha: 1)
        static let hintTitleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let hintBodyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let hintKeyFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    }

    /// 放大镜的采样和网格尺寸，仅用于框选预览。
    enum ScreenshotMagnifier {
        static let size: CGFloat = 120
        static let distance: CGFloat = 10
        static let sizeAndDistance: CGFloat = 130
        static let crosshairAxis: CGFloat = 58
        static let crosshairGapStart: CGFloat = 55
        static let crosshairGapEnd: CGFloat = 60
        static let crosshairWidth: CGFloat = 5
        static let labelLight = NSColor.white
        static let labelDark = NSColor.black
        static let sampleSide: CGFloat = 12
        static let sampleRadius: CGFloat = 6
        static let gridStep: CGFloat = 5
        static let gridOffset: CGFloat = 0.5
        static let gridColor = NSColor.gray.withAlphaComponent(0.25)
        static let outerLineWidth: CGFloat = 2
        static let centerLineWidth: CGFloat = 1
        static let centerBoxSide: CGFloat = 6.5
        static let smallFont = NSFont.systemFont(ofSize: 8)
        static let outerInset: CGFloat = 1
        static let outerSide: CGFloat = 118
        static let centerOrigin: CGFloat = 54.5
    }

    /// 长截图采集时选区外的整图预览。
    enum ScreenshotShadow {
        static let blur:CGFloat=12
        static let offset=NSSize(width:0,height:-3)
        static let inset:CGFloat=39
        static let defaultOpacity:Double=0.25
        static func color(rgb:Int,alpha:Double)->NSColor {NSColor(srgbRed:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255,alpha:alpha)}
    }
    enum ScreenshotSave { static let jpegBackground = NSColor.white }

    enum ScreenshotPin {
        /// 透明对齐留白，让Retina钉图可在整数窗口坐标内移动一个物理像素。
        static let drawingInset: CGFloat = 1
        static let menuHintPosition: CGFloat = 210
        static let menuFont = NSFont.menuFont(ofSize: 13)
        static let closeSize: CGFloat = 20
        static let closeSymbolSize: CGFloat = 12
        static let closeInset: CGFloat = 4
        static let textWidth: CGFloat = 480
        static let textInset: CGFloat = 20
    }

    enum ScreenshotScroll {
        static let previewWidth: CGFloat = 200
        static let previewHeight: CGFloat = 640
        /// 容器可用高度不足时改放选区内，避免挤成横向窄条。
        static let minimumPreviewSpace: CGFloat = 120
        static let minimumPreviewWidth: CGFloat = 160
        /// 已成功定位的采集视口；仅绘在预览上，不进入原图。
        static let viewportLineWidth: CGFloat = 1
        static let viewportCornerWidth: CGFloat = 2
        static let viewportCornerLength: CGFloat = 8
        /// 居中编辑预留上下工具条，不缩小最终导出像素。
        static let editorInset: CGFloat = 96
    }

    /// 本机 OCR 结果窗口：语言栏、原图对照与文字编辑的最小可用尺寸。
    enum OCR {
        static let windowSize = NSSize(width: 760, height: 560)
        static let comparisonSize = NSSize(width: 1040, height: 680)
        // 两种视图共用最小窗口；容纳两栏和留白，切换时不改变窗口外框。
        static let minimumSize = NSSize(width: minimumPanelWidth * 2 + Design.Space.m + Design.Space.l * 2, height: 360)
        /// 原图与文字区共用下限；可容纳文字区底部的图标和语言按钮。
        static let minimumPanelWidth: CGFloat = 320
        static let minimumZoom: CGFloat = 0.05
        static let maximumZoom: CGFloat = 16
        static let wheelZoomSensitivity: CGFloat = 0.04
        static let preciseZoomSensitivity: CGFloat = 0.005
        static let languageHeight: CGFloat = 32
        static let actionSize: CGFloat = 28
        static let topBarHeight: CGFloat = 32
        static let topPanelGap: CGFloat = 4
        static let bottomActionsInset: CGFloat = 8
        static let languageHorizontalInset: CGFloat = 12
        static let minimumTextHeight: CGFloat = 160
    }

    enum ScreenshotEditor {
        /// 截图主工具栏与当前工具选项栏的统一外观。
        static let toolbarButtonSize: CGFloat = 28
        static let toolbarSymbolSize: CGFloat = 17
        static let toolbarButtonRadius: CGFloat = 8
        static let toolbarRadius: CGFloat = 14
        static let toolbarItemSpacing: CGFloat = 4
        static let toolbarBarInset: CGFloat = 6
        static let toolbarOptionsSpacing: CGFloat = 12
        static let toolbarControlHeight: CGFloat = 24
        /// 次级工具条固定高度，选项多少只影响宽度。
        static let toolbarOptionsHeight: CGFloat = 40
        /// 选区左上方的紧凑宽高／比例面板。
        static let sizeToolbarHeight = toolbarOptionsHeight * 0.6
        static let sizeControlHeight: CGFloat = 16
        static let sizeFieldWidth: CGFloat = 48
        static let sizeRatioMinimumWidth: CGFloat = 14
        /// 补偿原生菜单箭头右侧的不可见边距，使两侧可见留白平衡。
        static let sizeRatioTrailingInset: CGFloat = 5
        static let sizeFieldRadius: CGFloat = 4
        static let sizeSymbolSize: CGFloat = 12
        static let sizeToolbarRadius: CGFloat = 7
        static let sizeSliderWidth: CGFloat = 64
        static let sizeDividerHeight: CGFloat = 12
        static let annotationNumberFontRatio: CGFloat = 0.8
        static let annotationMarkerGap: CGFloat = 12
        static let highlighterOpacity: CGFloat = 0.35
        static let highlighterRadius: CGFloat = 3
        static let highlighterTextPadding: CGFloat = 2
        /// 荧光笔空心笔刷指针：白色外边、黑色内边，保持透明中心。
        static let highlighterCursorWidth: CGFloat = 10
        static let highlighterCursorMinimumHeight: CGFloat = 14
        static let highlighterCursorBlackWidth: CGFloat = 2
        static let highlighterCursorWhiteWidth: CGFloat = 1
        static let toolbarSliderWidth: CGFloat = 84
        static let toolbarOptionSegmentWidth: CGFloat = 28
        static let toolbarGlyphLineWidth: CGFloat = 1.5
        static let toolbarSwatchSize: CGFloat = 18
        static let toolbarTrackHeight: CGFloat = 3
        static let valueBubbleHorizontalInset: CGFloat = 12
        static let valueBubbleVerticalInset: CGFloat = 10
        static let toolbarDividerWidth: CGFloat = 1
        static let toolbarDividerHeight: CGFloat = 24
        static let annotationLineWidth: CGFloat = 2
        static let annotationDotRatio: CGFloat = 0.22
        static let annotationNumberRatio: CGFloat = 0.525
        static let annotationTextGap: CGFloat = 12
        static let defaultFocusOpacity: CGFloat = 0.5
        static let defaultFillOpacity: CGFloat = 0.25
        static let defaultCornerRadius: CGFloat = 8
        static let maximumCornerRadius: CGFloat = 80
        static let handleSize: CGFloat = 8
        static let textSize: CGFloat = 18
        /// 图片标注专用的默认红色。
        static let defaultStrokeColor = NSColor.red
        static func restoredColor(_ rgba: [Double]) -> NSColor {
            guard rgba.count == 4 else { return defaultStrokeColor }
            return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        static func font(size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
        static func serialFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
        /// CustomView scrollWheel: 的原始不透明度下限。
        static let minimumPinOpacity: CGFloat = 0.1
        /// 原 DefaultPreferences sizeOfPinFillet=8。
        static let handleFill = NSColor.white
        static let highlightFill = NSColor.black
    }

    /// 通用滑动分段控件：固定内容，只有选中背景移动。
    enum Segmented {
        /// 两档显式度量：设置行与 24pt 原生控件对齐，截图工具条保持原有 28pt。
        enum Size {
            case compact, regular
            var height: CGFloat { self == .compact ? Settings.controlHeight : Segmented.height }
            var horizontalInset: CGFloat { self == .compact ? compactHorizontalInset : Segmented.horizontalInset }
            var radius: CGFloat { self == .compact ? compactRadius : Segmented.radius }
        }
        static let compactHorizontalInset: CGFloat = 8
        static let compactRadius: CGFloat = 7
        static let height: CGFloat = 28
        static let horizontalInset: CGFloat = 10
        static let thumbInset: CGFloat = 2
        static let radius: CGFloat = 9
        static let contentGap: CGFloat = 5
        static let iconSize: CGFloat = 17
        /// Aa 文字样式预览的底色/边框装饰，字形始终使用官方 SF textformat。
        static let textStyleIconSize: CGFloat = 14
        /// 文字样式每段 38pt，较默认内容宽度左右各多留 2pt。
        static let textStyleSegmentWidth: CGFloat = 38
        static let symbolBadgeInset: CGFloat = 3
        static let symbolBadgeHeight: CGFloat = 17
        static let symbolBadgeRadius: CGFloat = 4
        static let symbolBadgeLineWidth: CGFloat = 1.5
        static let font = Text.settingsRow.nsFont
    }
    enum AnnotationEditor {
        static let inset: CGFloat = 8
        static let radius: CGFloat = 10
        static let maximumAutoWidth: CGFloat = 400
        static let textMeasurementPadding: CGFloat = 2
        static let defaultWidth: CGFloat = 40
        static let minimumWidth: CGFloat = 40
        static let minimumHeight: CGFloat = 28
        static let emptyAspectRatio: CGFloat = 1.25
        static let borderWidth: CGFloat = 1.5
        static let textBorderInset: CGFloat = 3
        static let handleWidth: CGFloat = 3
        static let handleHeight: CGFloat = 12
    }

    // MARK: 圆角

    enum Radius {
        /// 输入框、语言栏、卡片。
        static let block: CGFloat = 8
        /// 小控件、键帽。
        static let control: CGFloat = 5
        /// 服务品牌图标的圆角占边长的比例，与 macOS App 图标一致。
        static let brandTileRatio: CGFloat = 0.225
    }

    /// 原地替换状态胶囊；高度固定，宽度随状态文字变化。
    enum ReplacementHUD {
        static let height: CGFloat = 30
        static let resultHold: TimeInterval = 1.5
        static let maximumWidth: CGFloat = 360
        static let orbSize: CGFloat = 20
        static let frameInterval: TimeInterval = 1.0 / 30
        static let shimmerDuration: TimeInterval = 1
        static let shimmerSpread: CGFloat = 0.24
        static let shimmerConcentration: CGFloat = 1.5
        static let cornerRadius: CGFloat = height / 2
        static let borderWidth: CGFloat = 0.5
    }

    // MARK: 动效

    enum Motion {
        /// 图标切换、淡入淡出、按下反馈。
        static let fast: TimeInterval = 0.15
        /// 展开收起、高度变化、旋转。
        static let standard: TimeInterval = 0.24
        /// 成功反馈的停留时间。
        static let hold: TimeInterval = 1.2
        /// 快捷键录制成功后，弹出框自动关闭前的停留。
        static let settle: TimeInterval = 0.6
        /// 流式文字增长时高度跟随的时长（逐帧跟随，不是过渡；调大会让跟随变慢）。
        static let follow: TimeInterval = 0.10
        /// 喇叭声波每帧间隔（播放节奏，不是过渡）。
        static let speakerFrame: TimeInterval = 0.35

        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    // MARK: 图标

    enum Icon {
        /// 工具与卡片操作按钮。
        static let action: CGFloat = 16
        /// 卡片操作的固定点击区域，图标或反馈变化时保持布局。
        static let cardActionSize: CGFloat = 26
        /// 展开箭头等小图标。
        static let small: CGFloat = 11
        /// 弹出菜单的上下小尖角。
        static let tiny: CGFloat = 9
        /// 空状态插图。
        static let hero: CGFloat = 30
        /// 服务品牌图标（圆角方块）。
        static let brand: CGFloat = 20

        /// Seven自带的自定义符号（`Resources/Symbols.xcassets`，打包时由 actool 编译进 App）。
        /// 交换语言：上向右、下向左的半叉箭头（⇌）。
        static let swapLanguages = "seven.swap"

        /// 自定义符号缺失时（例如未经打包直接运行测试）使用的系统符号。
        static let screenshotFocus = "squareshape.on.pattern.diagonalline"
        /// 马赛克采用官方黑白相间的棋盘格符号。
        static let screenshotMosaic = "checkerboard.rectangle"
        /// 六点拖动手柄的 SVG 模板资源。
        static let screenshotDrag = "ScreenshotDragHandle"
        private static let customFallbacks = [swapLanguages: "arrow.left.arrow.right", screenshotFocus: "square.on.square"]

        /// 按名称取符号：先找系统 SF Symbols，再找Seven自带的自定义符号，最后用备用系统符号。
        static func symbol(_ name: String, description: String? = nil, tint: NSColor? = nil) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
                ?? NSImage(symbolName: name, bundle: .main, variableValue: 0)
                ?? customFallbacks[name].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: description) }
            guard let tint, let colored = image?.withSymbolConfiguration(.init(paletteColors: [tint])) else { return image }
            // 原生分段控件会用系统色重绘模板；保留已配置的符号色板。
            colored.isTemplate = false
            return colored
        }
    }

    enum Palette {
        /// 第三方服务的品牌色（十六进制 RGB），只用于服务图标；Seven自己的界面颜色不要用它。
        static func brand(_ rgb: UInt32) -> NSColor { ThemePalette.rgb(rgb) }
    }

    // MARK: 透明度

    enum Opacity {
        /// 不可用的控件、未启用的状态、占位内容。
        static let disabled: CGFloat = 0.4
    }

    // MARK: 键帽

    enum Keycap {
        static let radius = Radius.control
        static let spacing = Space.xs
        static let strokeWidth: CGFloat = 1
    }
}
