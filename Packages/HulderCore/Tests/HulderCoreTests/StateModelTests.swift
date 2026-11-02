import Foundation
import Testing
@testable import HulderCore

@MainActor
struct StateModelTests {
    private let t0 = noon()
    private let t1 = noon(plusSeconds: 100)
    private let t2 = noon(days: 1)
    private let a = AppID("com.example.a")
    private let n = AppID("com.example.n")

    private func withTempFile(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("state.json"))
    }

    @Test func sightingsUpdateLastSeenAndReturnOnlyNewApps() throws {
        try withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)

            let added = model.recordSightings([(a, "A"), (n, "N")], at: t2)

            #expect(added == [n])
            #expect(model.state.layout.apps[a]?.lastSeen == t2)
            #expect(model.state.layout.apps[n]?.name == "N")
        }
    }

    @Test func aRepeatedSightingOnTheSameDayChangesAndSavesNothing() throws {
        try withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)

            model.recordSightings([(a, "A")], at: t1)

            #expect(model.state.layout.apps[a]?.lastSeen == t0)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!saved.isEmpty)
        }
    }

    @Test func stateIsSavedAfterChange() throws {
        try withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A"), (n, "N")], at: t0)
            model.assign(a, to: .hidden)
            model.forget(n)
            model.setDefaultSection(.alwaysHidden)
            model.update { $0.rehideDelay = .never }

            #expect(StateStore(fileURL: file).load() == .loaded(model.state))
            #expect(model.state.layout.section(of: a) == .hidden)
            #expect(model.state.layout.apps[n] == nil)
            #expect(model.state.layout.defaultSection == .alwaysHidden)
            #expect(model.state.settings.rehideDelay == .never)
        }
    }

    @Test func reloadingGivesTheSavedStateAndOkStatus() throws {
        try withTempFile { file in
            let first = StateModel(store: StateStore(fileURL: file))
            first.recordSightings([(a, "A")], at: t0)
            first.assign(a, to: .hidden)

            let second = StateModel(store: StateStore(fileURL: file))

            #expect(second.state == first.state)
            #expect(second.storeStatus == .ok)
        }
    }

    @Test func readOnlyStoreNeverWrites() throws {
        try withTempFile { file in
            let original = Data(#"{"version":2}"#.utf8)
            try original.write(to: file)
            let model = StateModel(store: StateStore(fileURL: file))
            let text = "Settings were saved by a newer version of Hulder (format 2)."
            #expect(model.storeStatus == .readOnly(text))

            model.recordSightings([(a, "A")], at: t0)
            model.assign(a, to: .hidden)
            model.update { $0.launchAtLogin = false }

            #expect(model.storeStatus == .readOnly(text))
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func unreadableFileIsReadOnlyWithFixedText() throws {
        try withTempFile { file in
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

            let model = StateModel(store: StateStore(fileURL: file))

            #expect(model.storeStatus == .readOnly("The settings file can't be read, so Hulder won't change it."))
        }
    }

    @Test func corruptFileIsRecoveredWithDefaults() throws {
        try withTempFile { file in
            try Data("not json".utf8).write(to: file)

            let model = StateModel(store: StateStore(fileURL: file))

            #expect(model.storeStatus == .recovered)
            #expect(model.state == HulderState())
        }
    }

    @Test func aFailedSaveIsFlaggedKeepsTheChangeAndClearsOnTheNextSave() throws {
        try withTempFile { file in
            let directory = file.deletingLastPathComponent()
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)
            #expect(!model.saveFailed)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

            model.assign(a, to: .hidden)

            #expect(model.saveFailed)
            #expect(model.state.layout.section(of: a) == .hidden)
            #expect(model.storeStatus == .ok)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            model.assign(a, to: .alwaysHidden)

            #expect(!model.saveFailed)
            #expect(StateStore(fileURL: file).load() == .loaded(model.state))
        }
    }

    @Test func eachFailedSaveCountsOnce() throws {
        try withTempFile { file in
            let directory = file.deletingLastPathComponent()
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)
            #expect(model.failedSaveCount == 0)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

            model.assign(a, to: .hidden)
            model.assign(a, to: .alwaysHidden)

            #expect(model.failedSaveCount == 2)
        }
    }

    @Test func aReadOnlyRefusalIsNotAFailedSave() throws {
        try withTempFile { file in
            try Data(#"{"version":2}"#.utf8).write(to: file)
            let model = StateModel(store: StateStore(fileURL: file))

            model.recordSightings([(a, "A")], at: t0)
            model.assign(a, to: .hidden)
            model.update { $0.launchAtLogin = false }

            #expect(model.failedSaveCount == 0)
        }
    }
}
