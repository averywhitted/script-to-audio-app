import XCTest
@testable import TableRead

// MARK: - FormatProfile wire-schema decoding
//
// FormatProfile mirrors backend/audio_worker.py's _format_profile_to_json
// exactly. JSONDecoder silently leaves an unmatched Optional field `nil`
// rather than failing, so a literal fixture shaped like the real backend
// response is the cheap guard against camelCase drift between the two sides.

final class FormatProfileDecodingTests: XCTestCase {

    private let fixtureJSON = """
    {
        "version": 1,
        "roles": {
            "character_cue": {
                "xMin": 192.0,
                "xMax": 212.0,
                "capsRatioMin": 0.95,
                "isBold": true,
                "isItalic": false,
                "sampleCount": 2
            }
        },
        "sceneHeadingPattern": null,
        "overlapMarkerDescription": null,
        "sourcePdfIdentifier": "/tmp/x.pdf"
    }
    """

    func testDecodesRealBackendFixture() throws {
        let data = try XCTUnwrap(fixtureJSON.data(using: .utf8))
        let profile = try JSONDecoder().decode(FormatProfile.self, from: data)

        XCTAssertEqual(profile.version, 1)
        XCTAssertEqual(profile.sourcePdfIdentifier, "/tmp/x.pdf")
        XCTAssertNil(profile.sceneHeadingPattern)
        XCTAssertNil(profile.overlapMarkerDescription)

        let cue = try XCTUnwrap(profile.roles["character_cue"])
        XCTAssertEqual(cue.xMin, 192.0)
        XCTAssertEqual(cue.xMax, 212.0)
        XCTAssertEqual(cue.capsRatioMin, 0.95)
        XCTAssertEqual(cue.isBold, true)
        XCTAssertEqual(cue.isItalic, false)
        XCTAssertEqual(cue.sampleCount, 2)
    }

    func testEncodeDecodeRoundTrip() throws {
        let original = FormatProfile(
            version: 1,
            roles: [
                "dialog": RoleGeometry(xMin: 90, xMax: 400, capsRatioMin: nil, isBold: nil, isItalic: nil, sampleCount: 3),
            ],
            sceneHeadingPattern: nil,
            overlapMarkerDescription: "slash-separated cue",
            sourcePdfIdentifier: "/tmp/y.pdf"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FormatProfile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRegionStyleDecodesRealBackendFixture() throws {
        let json = """
        {"x0": 100.0, "x1": 200.0, "capsRatio": 1.0, "isBold": false,
         "isItalic": false, "text": "ALICE"}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let region = try JSONDecoder().decode(RegionStyle.self, from: data)
        XCTAssertEqual(region.text, "ALICE")
        XCTAssertEqual(region.x0, 100.0)
        XCTAssertEqual(region.x1, 200.0)
    }

    func testTaggedBlockExampleFromRegionStyleCarriesGeometry() {
        let region = RegionStyle(
            x0: 100, x1: 260, capsRatio: 1.0, isBold: true, isItalic: false, text: "JOSH"
        )
        let example = TaggedBlockExample(role: "character_cue", region: region)
        XCTAssertEqual(example.role, "character_cue")
        XCTAssertEqual(example.x0, 100)
        XCTAssertEqual(example.x1, 260)
        XCTAssertEqual(example.capsRatio, 1.0)
        XCTAssertEqual(example.isBold, true)
        XCTAssertEqual(example.text, "JOSH")
    }
}

// MARK: - FormatTemplateLibrary persistence

final class FormatTemplateLibraryTests: XCTestCase {

    @MainActor
    private func makeTempLibrary() -> (FormatTemplateLibrary, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableReadTests-\(UUID().uuidString)")
        let library = FormatTemplateLibrary(baseURLProvider: { base })
        return (library, base)
    }

    @MainActor func testSaveLoadRoundTrip() throws {
        let (library, base) = makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: base) }

        let item = FormatTemplateLibraryItem(
            id: UUID(),
            name: "My Theater Format",
            createdAt: Date(),
            originProjectName: "Test Play",
            profile: FormatProfile(roles: [
                "dialog": RoleGeometry(xMin: 90, xMax: 400, capsRatioMin: nil, isBold: nil, isItalic: nil, sampleCount: 1),
            ])
        )
        try library.save(item)
        XCTAssertEqual(library.templates.count, 1)

        let reloaded = FormatTemplateLibrary(baseURLProvider: { base })
        XCTAssertEqual(reloaded.templates.count, 1)
        XCTAssertEqual(reloaded.templates.first?.name, "My Theater Format")
        XCTAssertEqual(reloaded.templates.first?.profile, item.profile)
    }

    @MainActor func testDeleteRemovesItem() throws {
        let (library, base) = makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: base) }

        let item = FormatTemplateLibraryItem(
            id: UUID(), name: "Temp", createdAt: Date(),
            originProjectName: "X", profile: FormatProfile()
        )
        try library.save(item)
        library.delete(item.id)
        XCTAssertTrue(library.templates.isEmpty)

        let reloaded = FormatTemplateLibrary(baseURLProvider: { base })
        XCTAssertTrue(reloaded.templates.isEmpty)
    }

    @MainActor func testLoadAllOnMissingFolderIsEmpty() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableReadTests-missing-\(UUID().uuidString)")
        let library = FormatTemplateLibrary(baseURLProvider: { base })
        XCTAssertTrue(library.templates.isEmpty)
    }
}
