import Foundation
import Testing
@testable import HulderCore

struct StateStoreTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func sampleState() -> HulderState {
        var layout = Layout()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        _ = layout.recordSighting(AppID("com.example.a"), name: "A", at: t)
        _ = layout.recordSighting(AppID("com.example.b"), name: "B", at: t)
        _ = layout.recordSighting(AppID("com.example.c"), name: "C", at: t)
        layout.assign(AppID("com.example.b"), to: .hidden)
        layout.assign(AppID("com.example.c"), to: .alwaysHidden)
        var settings = HulderSettings()
        settings.rehideDelay = .never
        settings.toggleHotkey = Hotkey(keyCode: 49, modifiers: 256)
        settings.revealAllHotkey = Hotkey(keyCode: 12, modifiers: 768)
        return HulderState(layout: layout, settings: settings)
    }

    @Test func stateRoundTrips() throws {
        let state = sampleState()
        #expect(try StateCodec.decode(StateCodec.encode(state)) == state)
    }

    @Test func unknownVersionIsRefused() {
        #expect(throws: StateFileError.unsupportedVersion(2)) {
            try StateCodec.decode(Data(#"{"version":2}"#.utf8))
        }
    }

    @Test func nonJSONOrMissingVersionIsCorrupt() {
        #expect(throws: StateFileError.corrupt) { try StateCodec.decode(Data("not json".utf8)) }
        #expect(throws: StateFileError.corrupt) { try StateCodec.decode(Data("{}".utf8)) }
        #expect(throws: StateFileError.corrupt) { try StateCodec.decode(Data(#"{"version":1}"#.utf8)) }
    }

    @Test func encodingCarriesVersionAndKeysApps() throws {
        let json = try #require(String(data: StateCodec.encode(sampleState()), encoding: .utf8))
        #expect(json.contains(#""version" : 1"#))
        #expect(json.contains(#""com.example.a" : {"#))
    }

    @Test func missingFileLoadsFresh() throws {
        try withTempDir { dir in
            let store = StateStore(fileURL: dir.appendingPathComponent("state.json"))
            #expect(store.load() == .fresh)
        }
    }

    @Test func saveCreatesDirectoryAndLoads() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("sub/state.json")
            let store = StateStore(fileURL: url)
            let state = sampleState()
            try store.save(state)
            #expect(store.load() == .loaded(state))
        }
    }

    @Test func refusedFileIsNeverOverwritten() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("state.json")
            let bytes = Data(#"{"version":2}"#.utf8)
            try bytes.write(to: url)
            let store = StateStore(fileURL: url)
            #expect(store.load() == .refused(.unsupportedVersion(2)))
            #expect(throws: StateFileError.unsupportedVersion(2)) { try store.save(sampleState()) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func corruptFileIsMovedAsideAndRecovered() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("state.json")
            try Data("not json".utf8).write(to: url)
            let store = StateStore(fileURL: url)
            #expect(store.load() == .recoveredFromCorrupt)
            let aside = dir.appendingPathComponent("state.corrupt.json")
            #expect(try Data(contentsOf: aside) == Data("not json".utf8))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            try store.save(sampleState())
            #expect(store.load() == .loaded(sampleState()))
        }
    }

    @Test func corruptFileThatCannotBeMovedIsRefusedAndKept() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("state.json")
            let bytes = Data("not json".utf8)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            let store = StateStore(fileURL: url)
            #expect(store.load() == .refused(.corrupt))
            #expect(throws: StateFileError.corrupt) { try store.save(sampleState()) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func unreadableFileIsRefusedAndNeverMoved() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("state.json")
            let bytes = try StateCodec.encode(sampleState())
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            let store = StateStore(fileURL: url)
            #expect(store.load() == .refused(.corrupt))
            #expect(throws: StateFileError.corrupt) { try store.save(HulderState()) }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(try Data(contentsOf: url) == bytes)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.corrupt.json").path))
        }
    }

    @Test func aFileThatCannotEvenBeStatedIsRefusedAndNeverOverwritten() throws {
        try withTempDir { dir in
            let folder = dir.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("state.json")
            let bytes = try StateCodec.encode(sampleState())
            try bytes.write(to: url)
            // The file is there, but the folder can't be searched: its status can't be read, which is not
            // the same as there being no file.
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            let store = StateStore(fileURL: url)

            #expect(store.load() == .refused(.corrupt))
            #expect(throws: StateFileError.corrupt) { try store.save(HulderState()) }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func aMissingFolderIsAMissingFile() throws {
        try withTempDir { dir in
            let store = StateStore(fileURL: dir.appendingPathComponent("never/state.json"))
            #expect(store.load() == .fresh)
        }
    }

    @Test func failedMoveKeepsTheOlderBackup() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("state.json")
            let aside = dir.appendingPathComponent("state.corrupt.json")
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: aside.appendingPathComponent("old.txt"))
            try Data("not json".utf8).write(to: url)
            #expect(StateStore(fileURL: url).load() == .refused(.corrupt))
            #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("old.txt").path))
            #expect(try Data(contentsOf: url) == Data("not json".utf8))
        }
    }

    @Test func datesAreEncodedAsISO8601() throws {
        let json = try #require(String(data: StateCodec.encode(sampleState()), encoding: .utf8))
        #expect(json.contains(#""lastSeen" : "2023-11-14T22:13:20Z""#))
    }

    @Test func secondCorruptFileReplacesTheFirstAside() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("state.json")
            let store = StateStore(fileURL: url)
            try Data("one".utf8).write(to: url)
            #expect(store.load() == .recoveredFromCorrupt)
            try Data("two".utf8).write(to: url)
            #expect(store.load() == .recoveredFromCorrupt)
            let aside = dir.appendingPathComponent("state.corrupt.json")
            #expect(try Data(contentsOf: aside) == Data("two".utf8))
        }
    }

    @Test func moduleAssignmentsRoundTripThroughTheCodec() throws {
        var state = sampleState()
        state.layout.assign(SystemItemID(moduleName: "WiFi"), to: .hidden)
        state.layout.assign(SystemItemID(moduleName: "Battery"), to: .alwaysHidden)

        let decoded = try StateCodec.decode(StateCodec.encode(state))

        #expect(decoded == state)
        #expect(decoded.layout.section(of: SystemItemID(moduleName: "WiFi")) == .hidden)
        #expect(decoded.layout.section(of: SystemItemID(moduleName: "Battery")) == .alwaysHidden)
    }

    @Test func moduleAssignmentsAreKeyedByModuleName() throws {
        var state = sampleState()
        state.layout.assign(SystemItemID(moduleName: "WiFi"), to: .hidden)

        let json = try #require(String(data: StateCodec.encode(state), encoding: .utf8))

        #expect(json.contains(#""systemItems" : {"#))
        #expect(json.contains(#""WiFi" : "hidden""#))
    }

    @Test func aStateWrittenByV1LoadsWithNoModuleAssignmentsAtTheSameVersion() throws {
        let v1 = """
            {"version":1,"layout":{"defaultSection":"hidden","apps":{"com.example.a":
            {"section":"alwaysHidden","name":"A","lastSeen":"2023-11-14T22:13:20Z"}}},
            "settings":{"launchAtLogin":false,"rehideDelay":"never"}}
            """

        let state = try StateCodec.decode(Data(v1.utf8))

        #expect(state.layout.systemItems.isEmpty)
        #expect(state.layout.defaultSection == .hidden)
        #expect(state.layout.section(of: AppID("com.example.a")) == .alwaysHidden)
        #expect(StateCodec.currentVersion == 1)
    }

    /// A test-only copy of how v1 decodes its state file: `version`, `layout.defaultSection`, `layout.apps` and
    /// `settings`, ignoring every other key. It stays as v1 had it, so a build that writes more still has to
    /// satisfy it.
    private struct FrozenV1State: Decodable {
        struct KnownApp: Decodable {
            let section: String
            let name: String
            let lastSeen: Date
        }

        struct Layout: Decodable {
            let defaultSection: String
            let apps: [String: KnownApp]
        }

        struct Hotkey: Decodable {
            let keyCode: UInt32
            let modifiers: UInt32
        }

        struct Settings: Decodable {
            let launchAtLogin: Bool
            let rehideDelay: String
            let toggleHotkey: Hotkey?
            let revealAllHotkey: Hotkey?
        }

        let version: Int
        let layout: Layout
        let settings: Settings
    }

    @Test func v1CanReadAStateHoldingModuleAssignments() throws {
        var state = sampleState()
        state.layout.defaultSection = .hidden
        state.layout.assign(SystemItemID(moduleName: "WiFi"), to: .hidden)
        state.layout.assign(SystemItemID(moduleName: "Battery"), to: .alwaysHidden)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let v1 = try decoder.decode(FrozenV1State.self, from: StateCodec.encode(state))

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(v1.version == 1)
        #expect(v1.layout.defaultSection == "hidden")
        #expect(v1.layout.apps.keys.sorted() == ["com.example.a", "com.example.b", "com.example.c"])
        #expect(v1.layout.apps["com.example.a"]?.section == "visible")
        #expect(v1.layout.apps["com.example.b"]?.section == "hidden")
        #expect(v1.layout.apps["com.example.c"]?.section == "alwaysHidden")
        #expect(v1.layout.apps["com.example.c"]?.name == "C")
        #expect(v1.layout.apps["com.example.c"]?.lastSeen == t)
        #expect(v1.settings.launchAtLogin == true)
        #expect(v1.settings.rehideDelay == "never")
        #expect(v1.settings.toggleHotkey?.keyCode == 49)
        #expect(v1.settings.toggleHotkey?.modifiers == 256)
        #expect(v1.settings.revealAllHotkey?.keyCode == 12)
        #expect(v1.settings.revealAllHotkey?.modifiers == 768)
    }
}
