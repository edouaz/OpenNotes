import XCTest
@testable import OpenNotes
final class SecurityTests: XCTestCase {
    func testCloudConfigurationDecodesPlistStringAddress() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["url": "https://example.supabase.co", "publishableKey": "sb_publishable_example"], format: .xml, options: 0)
        let config = try PropertyListDecoder().decode(CloudConfiguration.self, from: data)
        XCTAssertEqual(config.url.absoluteString, "https://example.supabase.co")
        XCTAssertTrue(CloudConfiguration.isPublicKey(config.publishableKey))
    }

    func testCloudConfigurationRejectsUnsafeAddresses() throws {
        for address in ["http://example.com", "relative/path", "https://user:password@example.com"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["url": address, "publishableKey": "sb_publishable_example"], format: .xml, options: 0)
            XCTAssertThrowsError(try PropertyListDecoder().decode(CloudConfiguration.self, from: data))
        }
    }

    func testBundledCloudConfigurationLoadsWhenPresent() throws {
        guard Bundle.main.url(forResource: "Supabase", withExtension: "plist") != nil else {
            throw XCTSkip("Cloud configuration is optional for local-only builds.")
        }
        XCTAssertNotNil(CloudConfiguration.load(), "The bundled configuration must enable the account screen.")
    }

    func testOnlyPublicKeysAccepted() {
        XCTAssertTrue(CloudConfiguration.isPublicKey("sb_publishable_example"))
        XCTAssertFalse(CloudConfiguration.isPublicKey("sb_secret_example"))
        let payload = Data("{\"role\":\"service_role\"}".utf8).base64EncodedString()
        XCTAssertFalse(CloudConfiguration.isPublicKey("header.\(payload).signature"))
        let anon = Data("{\"role\":\"anon\"}".utf8).base64EncodedString()
        XCTAssertTrue(CloudConfiguration.isPublicKey("header.\(anon).signature"))
    }
}
