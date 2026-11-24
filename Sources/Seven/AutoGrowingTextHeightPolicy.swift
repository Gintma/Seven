import Foundation

struct AutoGrowingTextHeightPolicy {
    static let minimum: CGFloat = 56
    static let defaultMaximum: CGFloat = 180

    static func clamped(_ height: CGFloat, maximum: CGFloat = defaultMaximum) -> CGFloat {
        min(max(height, minimum), max(minimum, maximum))
    }
}
