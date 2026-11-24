import CoreGraphics
import Darwin

/// 滚动截图的 Core Graphics 取图入口，运行时解析窗口截图符号。
enum FrozenSystemImage {
    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    static func capture(rect: CGRect, options: CGWindowListOption = .optionOnScreenOnly,
                        windowID: CGWindowID = kCGNullWindowID, imageOptions: CGWindowImageOption = []) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: Capture.self)
        return function(rect, options.rawValue, windowID, imageOptions.rawValue)?.takeRetainedValue()
    }
}
