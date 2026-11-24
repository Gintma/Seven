import AppKit

enum ScreenshotEditCursor: Equatable {
    case idle, move, dragging, horizontal, vertical, diagonalUp, diagonalDown, text, drawing
    var cursor: NSCursor {
        switch self {
        case .idle: return .arrow
        case .move: return .openHand
        case .dragging: return .closedHand
        case .text: return .iBeam
        case .drawing: return .arrow
        case .horizontal:
            if #available(macOS 15, *) { return .columnResize }
            return .resizeLeftRight
        case .vertical:
            if #available(macOS 15, *) { return .rowResize }
            return .resizeUpDown
        case .diagonalUp:
            if #available(macOS 15, *) { return .frameResize(position: .topRight, directions: .all) }
            return .arrow
        case .diagonalDown:
            if #available(macOS 15, *) { return .frameResize(position: .topLeft, directions: .all) }
            return .arrow
        }
    }
}
