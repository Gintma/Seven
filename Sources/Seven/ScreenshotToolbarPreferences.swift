import AppKit
import Combine

enum ScreenshotToolbarAction: String, CaseIterable, Identifiable, Codable {
    case rectangle, ellipse, line, arrow, pencil, mosaic, text, highlight
    case undo, redo, ocr, scroll, save, share, pin, copy, cancel, drag
    case edit, reset
    var id: Self { self }
    static let tools: [Self] = [.rectangle,.ellipse,.line,.arrow,.pencil,.mosaic,.text,.highlight]
    static let editableOperations:[Self] = [.ocr,.scroll,.share,.pin]
    static let builtInOperations:[Self] = [.undo,.redo,.save,.edit,.reset,.copy,.cancel]
    static let operations:[Self] = editableOperations+builtInOperations+[.drag]
    var tool: ScreenshotEditorTool? { ScreenshotEditorTool.toolbarCases.first { String(describing:$0) == rawValue } }
    var title: String {
        if let tool { return tool.title }
        switch self {
        case .undo:return L10n.text("undo")
        case .redo:return L10n.text("redo")
        case .ocr:return L10n.text("recognizeText")
        case .scroll:return L10n.text("scrollingScreenshot")
        case .save:return L10n.text("saveScreenshot")
        case .pin:return L10n.text("pinImage")
        case .copy:return L10n.text("copy")
        case .share:return L10n.text("share")
        case .cancel:return L10n.text("cancelOrExit")
        case .drag:return L10n.text("dragToolbar")
        case .edit:return L10n.text("editImage")
        case .reset:return L10n.text("resetScrollingScreenshot")
        default:return rawValue
        }
    }
    static let allowedKeys=Array("0123456789abcdefghijklmnopqrstuvwxyz").map(String.init)
    var defaultKey: String? {
        if let index=Self.tools.firstIndex(of:self) {return String(index+1)}
        switch self {case .ocr:return "o";case .scroll:return "l";case .share:return "h";case .pin:return "p";default:return nil}
    }
    enum Context:Hashable {case screenshotEdit,longCapture,pinEdit,pinIdle}
    var contexts:Set<Context> {
        if tool != nil {return [.screenshotEdit,.pinEdit]}
        switch self {
        case .edit:return [.longCapture,.pinIdle]
        case .reset:return [.longCapture]
        case .scroll:return [.screenshotEdit]
        case .undo,.redo:return [.screenshotEdit,.pinEdit]
        case .pin:return [.screenshotEdit,.longCapture]
        case .save,.share,.ocr:return [.screenshotEdit,.longCapture,.pinEdit,.pinIdle]
        case .copy,.cancel,.drag:return [.screenshotEdit,.longCapture,.pinEdit]
        default:return []
        }
    }
    var symbol:String {
        if let tool {return tool.symbol}
        switch self {
        case .undo:return "arrow.uturn.backward"
        case .redo:return "arrow.uturn.forward"
        case .edit:return "square.and.pencil"
        case .reset:return "arrow.counterclockwise"
        case .ocr:return "text.viewfinder"
        case .scroll:return "rectangle.arrowtriangle.2.outward"
        case .save:return "square.and.arrow.down"
        case .share:return "square.and.arrow.up"
        case .pin:return "pin"
        case .copy:return "checkmark"
        case .cancel:return "xmark"
        case .drag:return Design.Icon.screenshotDrag
        default:return "questionmark"
        }
    }
    var fixedKeyLabels:[String]? {
        switch self {
        case .undo:return ["⌘","Z"]
        case .redo:return ["⌘","⇧","Z"]
        case .save:return ["⌘","S"]
        case .copy:return ["↩"]
        case .cancel:return ["Esc"]
        case .edit:return ["Space"]
        case .reset:return ["R"]
        default:return nil
        }
    }
    var acceptsKey: Bool { fixedKeyLabels == nil && ![Self.drag,.reset].contains(self) }

}

/// Editor shortcuts and button visibility; never saves images, text, or edited documents. A nil default is used for isolated tests.
@MainActor final class ScreenshotToolbarPreferences: ObservableObject {
    static let shared = ScreenshotToolbarPreferences(defaults:.standard)
    static let changed = Notification.Name("Seven.ScreenshotToolbarChanged")
    private static let storageKey = "screenshotToolbar.v1"
    struct Item: Codable, Equatable { var visible: Bool; var key: String? }
    @Published private var items: [String:Item] = [:]
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = nil) {
        self.defaults=defaults
        if let data=defaults?.data(forKey:Self.storageKey),let saved=try? JSONDecoder().decode([String:Item].self,from:data) {
            items=saved
            // Older versions allowed leaving shortcuts blank; after adding default keys, duplicate legacy overrides fall back to their respective defaults.
            for _ in ScreenshotToolbarAction.allCases {
                var changed=false
                for action in ScreenshotToolbarAction.allCases where action.acceptsKey {
                    let value=item(action)
                    if value.key != action.defaultKey,let key=value.key,(!Self.isValidKey(key) || conflict(key,except:action) != nil || reservedAction(key,for:action) != nil) {
                        items[action.rawValue]=Item(visible:value.visible,key:action.defaultKey);changed=true
                    }
                }
                if !changed {break}
            }
        }
    }
    func item(_ action:ScreenshotToolbarAction)->Item {
        var value=items[action.rawValue] ?? Item(visible:true,key:action.defaultKey)
        if action.acceptsKey {value.key=value.key ?? action.defaultKey}else{value.key=nil}
        return value
    }
    func setVisible(_ value:Bool,for action:ScreenshotToolbarAction) { var valueItem=item(action);valueItem.visible=value;items[action.rawValue]=valueItem;persist() }
    @discardableResult func setKey(_ key:String?,for action:ScreenshotToolbarAction)->Bool {
        guard action.acceptsKey else{return false}
        guard let normalized=(key ?? action.defaultKey)?.lowercased(),Self.isValidKey(normalized),conflict(normalized,except:action)==nil && reservedAction(normalized,for:action)==nil else{return false}
        var value=item(action);value.key=normalized;items[action.rawValue]=value;persist();return true
    }
    @discardableResult func resetKey(_ action:ScreenshotToolbarAction)->Bool {setKey(action.defaultKey,for:action)}
    static func isValidKey(_ key:String)->Bool {ScreenshotToolbarAction.allowedKeys.contains(key)}
    func conflict(_ key:String,except action:ScreenshotToolbarAction)->ScreenshotToolbarAction? {
        ScreenshotToolbarAction.allCases.first {$0 != action && !$0.contexts.isDisjoint(with:action.contexts) && item($0).key==key.lowercased()}
    }
    func reservedAction(_ key:String,for action:ScreenshotToolbarAction)->String? {
        if key.lowercased() == "r",action.contexts.contains(.longCapture) {return ScreenshotToolbarAction.reset.title}
        return nil
    }
    func recordingProblem(_ event:NSEvent,for action:ScreenshotToolbarAction)->String? {
        let flags=event.modifierFlags.intersection([.command,.option,.control,.shift])
        let text=event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command || flags == [.command,.shift] {
            let name=flags.contains(.shift) && text == "z" ? L10n.text("redo"):["c":L10n.text("copy"),"s":L10n.text("save"),"z":L10n.text("undo"),"w":L10n.text("closeWindow")][text]
            if let name {return L10n.format("thisKeyIsUsedFor", String(describing: name))}
        }
        if [UInt16(51),117].contains(event.keyCode) {return L10n.text("thisKeyDeletesTheSelectedAnnotation")}
        if event.keyCode == 36 {return L10n.text("thisKeyCopiesTheScreenshot")}
        if event.keyCode == 49, !action.contexts.isDisjoint(with:[.longCapture,.pinIdle]) {return L10n.text("thisKeyIsUsedToEditThe")}
        if let reserved=reservedAction(text,for:action) {return L10n.format("thisKeyIsUsedFor", String(describing: reserved))}
        if !flags.intersection([.command,.option,.control]).isEmpty {return L10n.text("useALetterOrNumberWithoutModifiers")}
        if !Self.isValidKey(text) {return L10n.text("use09OrAZ")}
        if let other=conflict(text,except:action) {return L10n.format("thisKeyIsAlreadyUsedFor", String(describing: other.title))}
        return nil
    }
    func action(for event:NSEvent,context:ScreenshotToolbarAction.Context? = nil)->ScreenshotToolbarAction? {
        let flags=event.modifierFlags.intersection([.command,.option,.control,.shift])
        let fixed:ScreenshotToolbarAction?
        if flags == .command,event.charactersIgnoringModifiers?.lowercased() == "s" {fixed = .save}
        else if flags == .command,event.charactersIgnoringModifiers?.lowercased() == "z" {fixed = .undo}
        else if flags == [.command,.shift],event.charactersIgnoringModifiers?.lowercased() == "z" {fixed = .redo}
        else if flags.isEmpty,event.charactersIgnoringModifiers?.lowercased() == "r",context == .longCapture {fixed = .reset}
        else if flags.isEmpty,event.keyCode == 49 {fixed = .edit}
        else if flags.isEmpty,event.keyCode == 36 {fixed = .copy}
        else if flags.isEmpty,event.keyCode == 53 {fixed = .cancel}
        else {fixed=nil}
        if let fixed,context.map(fixed.contexts.contains) ?? true {return fixed}
        guard event.modifierFlags.intersection([.command,.option,.control]).isEmpty,
              let key=event.charactersIgnoringModifiers?.lowercased(),Self.isValidKey(key) else{return nil}
        return ScreenshotToolbarAction.allCases.first {(context.map($0.contexts.contains) ?? true) && item($0).key==key}
    }
    func hint(_ action:ScreenshotToolbarAction)->String {action.fixedKeyLabels?.joined() ?? item(action).key?.uppercased() ?? ""}
    private func persist() {
        if let data=try? JSONEncoder().encode(items) {defaults?.set(data,forKey:Self.storageKey)}
        NotificationCenter.default.post(name:Self.changed,object:self)
    }
}
