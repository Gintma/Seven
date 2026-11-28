import Foundation
import XCTest
@testable import Seven

final class PreferencesDomainMigrationTests: XCTestCase {
    private let legacy = "local.seven.translator"
    private let current = "com.crissun.seven"

    @MainActor func testCopiesLegacyPreferencesOnceBeforeConsumersReadNewDomain() throws {
        let servicePayload = Data([0x5b, 0x5d])
        let domains = MemoryPreferencesDomains([
            legacy: ["configured": true, "serviceInstances.v2": servicePayload, "hotKey.v1": ["keyCode": 14]]
        ])
        PreferencesDomainMigration.migrateIfNeeded(bundleIdentifier: current, defaults: domains)
        let migrated = try XCTUnwrap(domains.persistentDomain(forName: current))
        XCTAssertEqual(migrated as NSDictionary, domains.persistentDomain(forName: legacy) as NSDictionary?)
        XCTAssertEqual(migrated["serviceInstances.v2"] as? Data, servicePayload)
        XCTAssertTrue(OnboardingFlow.hasExistingUsage(preferences: migrated, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))

        domains.setPersistentDomain(["configured": false], forName: legacy)
        PreferencesDomainMigration.migrateIfNeeded(bundleIdentifier: current, defaults: domains)
        XCTAssertEqual(domains.persistentDomain(forName: current)?["configured"] as? Bool, true)
        XCTAssertEqual(domains.persistentDomain(forName: legacy)?["configured"] as? Bool, false)
    }

    func testExistingNewPreferencesAreNeverOverwrittenOrMerged() {
        let domains = MemoryPreferencesDomains([
            legacy: ["configured": true, "serviceInstances.v2": Data([0])],
            current: ["configured": false]
        ])
        PreferencesDomainMigration.migrateIfNeeded(bundleIdentifier: current, defaults: domains)
        XCTAssertEqual(domains.persistentDomain(forName: current)?["configured"] as? Bool, false)
        XCTAssertNil(domains.persistentDomain(forName: current)?["serviceInstances.v2"])
    }

    func testVariantsAndUnbundledExecutablesNeverReadOrWriteLegacyPreferences() {
        let domains = MemoryPreferencesDomains([legacy: ["configured": true]])
        for identifier in [nil, "com.crissun.seven.sparkle", "local.seven.translator", "com.example.other"] {
            PreferencesDomainMigration.migrateIfNeeded(bundleIdentifier: identifier, defaults: domains)
        }
        XCTAssertTrue(domains.reads.isEmpty)
        XCTAssertNil(domains.persistentDomain(forName: current))
    }

    func testMissingOrEmptyLegacyDomainDoesNotCreateNewPreferences() {
        let domains = MemoryPreferencesDomains([:])
        PreferencesDomainMigration.migrateIfNeeded(bundleIdentifier: current, defaults: domains)
        XCTAssertNil(domains.persistentDomain(forName: current))
        domains.setPersistentDomain([:], forName: legacy)
        PreferencesDomainMigration.migrateIfNeeded(bundleIdentifier: current, defaults: domains)
        XCTAssertNil(domains.persistentDomain(forName: current))
    }
}

// Uses an in-memory domain so tests never touch production preferences even when Seven is already installed.
private final class MemoryPreferencesDomains: PreferencesDomains {
    private var domains: [String: [String: Any]]
    private(set) var reads = [String]()

    init(_ domains: [String: [String: Any]]) { self.domains = domains }

    func persistentDomain(forName domainName: String) -> [String: Any]? {
        reads.append(domainName)
        return domains[domainName]
    }

    func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        domains[domainName] = domain
    }
}
