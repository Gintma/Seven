import AppKit

/// Persists tool parameters only; never saves screenshots, text, selections, or the currently active tool.
final class ScreenshotToolPreferences {
    private var smartSelection = true
    static let smartSelectionKey = "screenshotSmartSelection.v1"
    var smartSelectionEnabled: Bool {
        get { defaults?.object(forKey: Self.smartSelectionKey) as? Bool ?? smartSelection }
        set { smartSelection = newValue; defaults?.set(newValue, forKey: Self.smartSelectionKey) }
    }
    var shadowStyle:ScreenshotShadowStyle {ScreenshotShadowPreferences(defaults:defaults).style(.screenshot)}
    var capturePreferences:ScreenshotCapturePreferences {ScreenshotCapturePreferences(defaults:defaults)}
    var usesPersistentStorage: Bool { defaults != nil }
    private let defaults: UserDefaults?
    private var values: [Int: ScreenshotToolOptions] = [:]
    private var cornerRadius: Double = 0
    var outputCornerRadius: CGFloat {
        get { CGFloat(defaults?.double(forKey: "screenshotOutputCornerRadius.v1") ?? cornerRadius) }
        set { cornerRadius = Double(newValue); defaults?.set(cornerRadius, forKey: "screenshotOutputCornerRadius.v1") }
    }
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    func options(for tool: ScreenshotEditorTool) -> ScreenshotToolOptions {
        if let value = values[tool.rawValue] { return value }
        if let data = defaults?.data(forKey: key(tool)), let value = try? JSONDecoder().decode(ScreenshotToolOptions.self, from: data) { return value }
        return ScreenshotToolOptions(tool: tool)
    }
    func save(_ options: ScreenshotToolOptions, for tool: ScreenshotEditorTool) {
        values[tool.rawValue] = options
        if let data = try? JSONEncoder().encode(options) { defaults?.set(data, forKey: key(tool)) }
    }
    private func key(_ tool: ScreenshotEditorTool) -> String { "screenshotToolOptions.v1.\(tool.rawValue)" }
}

struct ScreenshotToolOptions: Codable, Equatable {
    var color: [Double] = [1, 0, 0, 1]
    var size: Double
    var opacity: Double = 1
    var fillOpacity = Design.ScreenshotEditor.defaultFillOpacity
    var filled = false, fillHasBorder = false, rounded = false, dashed = false, blurred = false, curved = false, focusIsEllipse = false
    var cornerRadius = Double(Design.ScreenshotEditor.defaultCornerRadius)
    var marker = ScreenshotAnnotationMarker.none.rawValue
    var arrowStyle: Int?
    var pencilMode: Int?
    var pencilFreehandOpacity: Double?
    var pencilHighlighterOpacity: Double?
    var textStyle = ScreenshotEditorTextStyle.background.rawValue
    init(tool: ScreenshotEditorTool) {
        size = Double(tool.defaultSize)
        if tool == .highlight { opacity = Design.ScreenshotEditor.defaultFocusOpacity }
    }
    @MainActor init(canvas: ScreenshotEditorCanvas, tool: ScreenshotEditorTool) {
        self.init(tool: tool)
        if let rgb = canvas.color.usingColorSpace(.sRGB) { color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map(Double.init) }
        fillOpacity = canvas.fillOpacity
        size = Double(canvas.width); opacity = Double(tool == .highlight ? canvas.highlightOpacity : canvas.opacity)
        filled = canvas.filled; fillHasBorder = canvas.fillHasBorder; rounded = canvas.rounded
        dashed = canvas.dashed; blurred = canvas.blurred; curved = canvas.curved; focusIsEllipse = canvas.focusIsEllipse
        arrowStyle = canvas.arrowStyle.rawValue; pencilMode = canvas.pencilMode.rawValue
        pencilFreehandOpacity = Double(canvas.pencilFreehandOpacity)
        pencilHighlighterOpacity = Double(canvas.pencilHighlighterOpacity)
        cornerRadius = Double(canvas.cornerRadius); marker = canvas.marker.rawValue; textStyle = canvas.textStyle.rawValue
    }
    @MainActor func apply(to canvas: ScreenshotEditorCanvas, tool: ScreenshotEditorTool) {
        canvas.arrowStyle = ScreenshotArrowStyle(rawValue: arrowStyle ?? ScreenshotArrowStyle.solid.rawValue) ?? .solid
        canvas.pencilMode = ScreenshotPencilMode(rawValue: pencilMode ?? ScreenshotPencilMode.freehand.rawValue) ?? .freehand
        canvas.color = Design.ScreenshotEditor.restoredColor(color)
        canvas.fillOpacity = fillOpacity
        canvas.width = CGFloat(size); canvas.opacity = tool == .line || tool == .arrow ? 1 : CGFloat(opacity)
        if tool == .pencil {
            canvas.pencilFreehandOpacity = CGFloat(pencilFreehandOpacity ?? opacity)
            canvas.pencilHighlighterOpacity = CGFloat(pencilHighlighterOpacity ?? Double(Design.ScreenshotEditor.highlighterOpacity))
            canvas.opacity = canvas.pencilMode == .highlighter ? canvas.pencilHighlighterOpacity : canvas.pencilFreehandOpacity
        }
        if tool == .highlight { canvas.highlightOpacity = CGFloat(opacity) }
        canvas.filled = filled; canvas.fillHasBorder = fillHasBorder; canvas.rounded = rounded
        canvas.dashed = dashed; canvas.blurred = blurred; canvas.curved = curved; canvas.focusIsEllipse = focusIsEllipse
        canvas.cornerRadius = CGFloat(cornerRadius)
        canvas.marker = ScreenshotAnnotationMarker(rawValue: marker) ?? .none
        canvas.textStyle = ScreenshotEditorTextStyle(rawValue: textStyle) ?? .background
    }
}
