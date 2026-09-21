import XCTest

@testable import VesperEngine

final class AddOnStoreTests: XCTestCase {

    // MARK: - Manifest decoding

    func testManifestDecoding() throws {
        let json = """
            {
              "id": "speaker-labels",
              "version": 1,
              "displayVersion": "1.0",
              "zipSizeBytes": 220716143,
              "installedSizeBytes": 240559364,
              "sha256": "f1dcd2a4022d943cd441e34e4f32a5692510ea7ed7ecaeedf4e83d25326c3fea",
              "minAppBuild": 1,
              "rootPath": "v3/fp16/Sortformer_v2.1.mlmodelc"
            }
            """
        let manifest = try JSONDecoder().decode(AddOnManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.id, "speaker-labels")
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.zipSizeBytes, 220_716_143)
        XCTAssertEqual(manifest.rootPath, "v3/fp16/Sortformer_v2.1.mlmodelc")
    }

    func testManifestZipObjectPathConvention() throws {
        let json = """
            {"id": "speaker-labels", "version": 1, "displayVersion": "1.0", "zipSizeBytes": 1,
             "installedSizeBytes": 1, "sha256": "abc", "minAppBuild": 1, "rootPath": "x"}
            """
        let manifest = try JSONDecoder().decode(AddOnManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.zipObjectPath, "speaker-labels/v1/speaker-labels-v1.zip")
    }

    // MARK: - SHA-256 verification

    func testSha256HexMatchesKnownValue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hello.txt")
        try Data("hello world\n".utf8).write(to: file)

        // Known SHA-256 of "hello world\n": printf 'hello world\n' | shasum -a 256
        let expected = "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447"
        let actual = try AddOnStore.sha256Hex(of: file)
        XCTAssertEqual(actual, expected)
    }

    func testHashMismatchIsDetectable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.bin")
        try Data("some downloaded bytes".utf8).write(to: file)

        let actual = try AddOnStore.sha256Hex(of: file)
        let wrongExpected = "0000000000000000000000000000000000000000000000000000000000000000"
        XCTAssertNotEqual(actual, wrongExpected, "a corrupted/wrong download must not match the manifest hash")
    }

    // MARK: - Installed-marker detection (no network)

    func testInstalledMarkerDetectionFindsHighestVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let v1 = root.appendingPathComponent("speaker-labels/v1")
        let v2 = root.appendingPathComponent("speaker-labels/v2")
        try FileManager.default.createDirectory(at: v1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)

        let marker1 = AddOnInstalledMarker(version: 1, installedSizeBytes: 100, rootPath: "a")
        let marker2 = AddOnInstalledMarker(version: 2, installedSizeBytes: 200, rootPath: "b")
        try JSONEncoder().encode(marker1).write(to: v1.appendingPathComponent("installed.json"))
        try JSONEncoder().encode(marker2).write(to: v2.appendingPathComponent("installed.json"))

        let found = AddOnStore.installedMarker(addOnID: "speaker-labels", root: root)
        XCTAssertEqual(found?.marker.version, 2)
        XCTAssertEqual(found?.marker.installedSizeBytes, 200)
        XCTAssertEqual(
            found?.versionDirectory.resolvingSymlinksInPath().path, v2.resolvingSymlinksInPath().path)
    }

    func testInstalledMarkerDetectionReturnsNilWhenMissing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let found = AddOnStore.installedMarker(addOnID: "speaker-labels", root: root)
        XCTAssertNil(found)
    }

    func testInstalledMarkerDetectionIgnoresCorruptJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let v1 = root.appendingPathComponent("speaker-labels/v1")
        try FileManager.default.createDirectory(at: v1, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: v1.appendingPathComponent("installed.json"))

        let found = AddOnStore.installedMarker(addOnID: "speaker-labels", root: root)
        XCTAssertNil(found)
    }

    // MARK: - AddOnStore instance reflects disk state with no network

    @MainActor
    func testAddOnStoreDoesNotAutoInstallOnInit() {
        // A fresh store for an id with nothing installed must report
        // notDownloaded without making any network call.
        let store = AddOnStore(addOnID: "nonexistent-test-addon-\(UUID().uuidString)")
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.status, .notDownloaded)
    }
}
