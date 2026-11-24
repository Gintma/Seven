import Foundation
import XCTest

extension XCTestCase {
    func isolatedDefaults(suiteName: String = "SevenTests." + UUID().uuidString) -> UserDefaults? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
