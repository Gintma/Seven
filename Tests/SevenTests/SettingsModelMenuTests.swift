import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import Seven

@MainActor final class SettingsModelMenuTests: XCTestCase {
    func testGroupsKeepManualModelsSeparateAcrossCatalogRefresh() {
        let groups = SettingsModelChoices.groups(current: "manual-a", fetched: ["api-a", "manual-a", "api-a"],
                                                manual: ["manual-a", "manual-b", "manual-a"])
        XCTAssertEqual(groups.catalog, ["api-a"])
        XCTAssertEqual(groups.manual, ["manual-a", "manual-b"])
        XCTAssertEqual(SettingsModelChoices.normalized("  custom-model\n"), "custom-model")
        XCTAssertEqual(SettingsModelChoices.normalized(" \n"), "")
    }

    func testFetchedCatalogSurvivesSettingsStoreReload() throws {
        let item = ServiceInstance(provider: .custom)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json["cachedModels"] = ["remote-a", "remote-b"]
        let saved = try JSONDecoder().decode(ServiceInstance.self, from: JSONSerialization.data(withJSONObject: json))
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: "FetchedModels-" + UUID().uuidString))
        SettingsStore(defaults: defaults).serviceInstances = [saved]
        let restored = try XCTUnwrap(SettingsStore(defaults: defaults).serviceInstances?.first)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertEqual(encoded["cachedModels"] as? [String], ["remote-a", "remote-b"],
                       "获取过的模型列表必须随服务配置保存，重启后不能丢失")
    }

    func testSwitchingServicePreservesItsRestoredCatalogWhileEditingSourceInvalidates() throws {
        var first = ServiceInstance(provider: .openAI)
        first.fetchedModels = ["openai-a", "openai-b"]
        var second = ServiceInstance(provider: .claude)
        second.fetchedModels = ["claude-a", "claude-b"]
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: "CatalogSwitch-" + UUID().uuidString))
        SettingsStore(defaults: defaults).serviceInstances = [first, second]
        let restored = try XCTUnwrap(SettingsStore(defaults: defaults).serviceInstances)
        XCTAssertFalse(restored[1].requiresModelCatalogInvalidation(comparedTo: restored[0]),
                       "切换服务不是修改服务地址，不能清空刚从本地恢复的目录")
        XCTAssertFalse(restored[0].requiresModelCatalogInvalidation(comparedTo: restored[1]),
                       "切回来也要保留该服务目录")
        var edited = restored[0]
        edited.baseAddress = "https://changed.example/v1"
        XCTAssertTrue(edited.requiresModelCatalogInvalidation(comparedTo: restored[0]))
        edited = restored[0]; edited.apiStyle = .anthropic
        XCTAssertTrue(edited.requiresModelCatalogInvalidation(comparedTo: restored[0]))
        edited = restored[0]; edited.model = "another"; edited.name = "重命名"
        XCTAssertFalse(edited.requiresModelCatalogInvalidation(comparedTo: restored[0]))
        XCTAssertEqual(restored[0].fetchedModels, first.fetchedModels)
        XCTAssertEqual(restored[1].fetchedModels, second.fetchedModels)
    }

    func testManualModelsRoundTripAndOlderInstancesDecodeWithoutNewField() throws {
        var first = ServiceInstance(provider: .custom)
        first.manualModels = ["one", "two"]
        let data = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(ServiceInstance.self, from: data).manualModels, ["one", "two"])
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "addedModels")
        let decoded = try JSONDecoder().decode(ServiceInstance.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(decoded.manualModels.isEmpty)
        let second = ServiceInstance(provider: .custom)
        XCTAssertTrue(second.manualModels.isEmpty, "不同实例不共享手动模型")
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: "ManualModels-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        settings.serviceInstances = [first, second]
        let restored = try XCTUnwrap(SettingsStore(defaults: defaults).serviceInstances)
        XCTAssertEqual(restored[0].manualModels, ["one", "two"])
        XCTAssertTrue(restored[1].manualModels.isEmpty)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    func testStaleMenuItemCannotDeleteCurrentModel() async throws {
        _ = NSApplication.shared
        let state = ModelDeletionState()
        let root = NSHostingView(rootView: ModelDeletionFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first)
        let submenu = try XCTUnwrap(button.menu?.item(withTitle: L10n.text("deleteModel"))?.submenu)
        XCTAssertNil(submenu.item(withTitle: state.selection))
        let oldTwo = try XCTUnwrap(submenu.item(withTitle: "two"))
        state.selection = "two"
        await Task.yield(); root.layoutSubtreeIfNeeded()
        NSApp.sendAction(try XCTUnwrap(oldTwo.action), to: oldTwo.target, from: oldTwo)
        XCTAssertEqual(state.manual, ["one", "two", "three"], "切为当前模型后，旧副菜单项也不能删除它")
        let remove = try XCTUnwrap(button.menu?.item(withTitle: L10n.text("deleteModel"))?.submenu?.item(withTitle: "three"))
        NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove)
        XCTAssertEqual(state.manual, ["one", "two"])
        XCTAssertEqual(state.selection, "two")
    }
}

@MainActor private final class ModelDeletionState: ObservableObject {
    @Published var selection = "one"
    @Published var manual = ["one", "two", "three"]
}
private struct ModelDeletionFixture: View {
    @ObservedObject var state: ModelDeletionState
    var body: some View {
        SettingsModelRow(text: $state.selection, models: ["api"], manualModels: $state.manual, isLoading: false, fetch: {})
    }
}
