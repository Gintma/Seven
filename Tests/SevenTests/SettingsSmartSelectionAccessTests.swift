import SwiftUI
import XCTest
@testable import Seven

@MainActor
final class SettingsSmartSelectionAccessTests: XCTestCase {
    func testMissingPermissionShowsOffAndKeepsStoredPreference() {
        var trusted = false
        var preference = true
        var requests = 0
        let access = SettingsSmartSelectionAccess(isTrusted: { trusted }, requestPermission: { _ in requests += 1 })
        let saved = Binding(get: { preference }, set: { preference = $0 })

        XCTAssertFalse(access.binding(for: saved).wrappedValue)
        access.binding(for: saved).wrappedValue = true
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(preference)
        XCTAssertFalse(access.binding(for: saved).wrappedValue)
        access.binding(for: saved).wrappedValue = false
        XCTAssertTrue(preference)
        XCTAssertEqual(requests, 1)

        trusted = true
        access.refresh()
        XCTAssertTrue(access.binding(for: saved).wrappedValue)
        trusted = false
        access.refresh()
        XCTAssertFalse(access.binding(for: saved).wrappedValue)
        XCTAssertTrue(preference)
    }

    func testBindingReadsUpdatedPermissionImmediatelyAfterWriting() {
        var trusted = false
        var preference = false
        let access = SettingsSmartSelectionAccess(isTrusted: { trusted }, requestPermission: { _ in
            XCTFail("已经授权，无需再次发起授权请求")
        })
        let saved = Binding(get: { preference }, set: { preference = $0 })
        let binding = access.binding(for: saved)
        XCTAssertFalse(binding.wrappedValue)

        trusted = true
        binding.wrappedValue = true

        XCTAssertTrue(access.isGranted)
        XCTAssertTrue(preference)
        XCTAssertTrue(binding.wrappedValue, "同一个绑定应立即读取刷新后的权限")
    }

    func testOnlyConfirmedPendingSwitchChangesAndRequiresActualGrant() {
        var trusted = false
        var screenshot = false
        var ocr = false
        var translation = false
        var granted: (() -> Void)?
        let access = SettingsSmartSelectionAccess(isTrusted: { trusted }, requestPermission: { granted = $0 })
        let screenshotBinding = Binding(get: { screenshot }, set: { screenshot = $0 })
        let ocrBinding = Binding(get: { ocr }, set: { ocr = $0 })
        let translationBinding = Binding(get: { translation }, set: { translation = $0 })

        access.binding(for: ocrBinding).wrappedValue = true
        XCTAssertNotNil(granted)
        XCTAssertFalse(ocr)
        XCTAssertFalse(access.binding(for: ocrBinding).wrappedValue)
        granted?()
        XCTAssertFalse(ocr)

        access.binding(for: translationBinding).wrappedValue = true
        trusted = true
        granted?()
        XCTAssertTrue(access.binding(for: translationBinding).wrappedValue)
        XCTAssertFalse(access.binding(for: screenshotBinding).wrappedValue)
        XCTAssertFalse(access.binding(for: ocrBinding).wrappedValue)

        granted = nil
        access.binding(for: translationBinding).wrappedValue = false
        XCTAssertFalse(translation)
        access.binding(for: screenshotBinding).wrappedValue = true
        XCTAssertTrue(screenshot)
        XCTAssertNil(granted)
    }

    func testClosingSwitchAfterReturningFromAuthorizationWinsOverPendingRequest() {
        var trusted = false
        var preference = true
        var pending: (() -> Void)?
        let access = SettingsSmartSelectionAccess(isTrusted: { trusted }, requestPermission: { pending = $0 },
            refreshPermissionRequest: {
                guard trusted else { return }
                let grant = pending
                pending = nil
                grant?()
            })
        let saved = Binding(get: { preference }, set: { preference = $0 })
        access.binding(for: saved).wrappedValue = true
        XCTAssertNotNil(pending)

        trusted = true
        access.refresh()
        XCTAssertTrue(access.binding(for: saved).wrappedValue)
        access.binding(for: saved).wrappedValue = false
        pending?()
        XCTAssertFalse(preference)
    }
}
