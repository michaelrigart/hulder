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
}
