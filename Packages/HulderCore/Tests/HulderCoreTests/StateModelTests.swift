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

    private func withTempFile(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir.appendingPathComponent("state.json"))
    }

    @Test func sightingsUpdateLastSeenAndReturnOnlyNewApps() async throws {
        try await withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)

            let added = model.recordSightings([(a, "A"), (n, "N")], at: t2)

            #expect(added == [n])
            #expect(model.state.layout.apps[a]?.lastSeen == t2)
            #expect(model.state.layout.apps[n]?.name == "N")
        }
    }

    @Test func aRepeatedSightingOnTheSameDayChangesAndSavesNothing() async throws {
        try await withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)
            await model.flushSaves()
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)

            model.recordSightings([(a, "A")], at: t1)
            await model.flushSaves()

            #expect(model.state.layout.apps[a]?.lastSeen == t0)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!saved.isEmpty)
        }
    }

    @Test func stateIsSavedAfterChange() async throws {
        try await withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A"), (n, "N")], at: t0)
            model.assign(a, to: .hidden)
            model.forget(n)
            model.setDefaultSection(.alwaysHidden)
            model.update { $0.rehideDelay = .never }
            await model.flushSaves()

            #expect(StateStore(fileURL: file).load() == .loaded(model.state))
            #expect(model.state.layout.section(of: a) == .hidden)
            #expect(model.state.layout.apps[n] == nil)
            #expect(model.state.layout.defaultSection == .alwaysHidden)
            #expect(model.state.settings.rehideDelay == .never)
        }
    }

    @Test func reloadingGivesTheSavedStateAndOkStatus() async throws {
        try await withTempFile { file in
            let first = StateModel(store: StateStore(fileURL: file))
            first.recordSightings([(a, "A")], at: t0)
            first.assign(a, to: .hidden)
            await first.flushSaves()

            let second = StateModel(store: StateStore(fileURL: file))

            #expect(second.state == first.state)
            #expect(second.storeStatus == .ok)
        }
    }

    @Test func readOnlyStoreNeverWrites() async throws {
        try await withTempFile { file in
            let original = Data(#"{"version":2}"#.utf8)
            try original.write(to: file)
            let model = StateModel(store: StateStore(fileURL: file))
            let text = "Settings were saved by a newer version of Hulder (format 2)."
            #expect(model.storeStatus == .readOnly(text))

            model.recordSightings([(a, "A")], at: t0)
            model.assign(a, to: .hidden)
            model.update { $0.launchAtLogin = false }
            await model.flushSaves()

            #expect(model.storeStatus == .readOnly(text))
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func unreadableFileIsReadOnlyWithFixedText() async throws {
        try await withTempFile { file in
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

            let model = StateModel(store: StateStore(fileURL: file))

            #expect(model.storeStatus == .readOnly("The settings file can't be read, so Hulder won't change it."))
        }
    }

    @Test func corruptFileIsRecoveredWithDefaults() async throws {
        try await withTempFile { file in
            try Data("not json".utf8).write(to: file)

            let model = StateModel(store: StateStore(fileURL: file))

            #expect(model.storeStatus == .recovered)
            #expect(model.state == HulderState())
        }
    }

    @Test func aFailedSaveIsFlaggedKeepsTheChangeAndClearsOnTheNextSave() async throws {
        try await withTempFile { file in
            let directory = file.deletingLastPathComponent()
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)
            await model.flushSaves()
            #expect(!model.saveFailed)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

            model.assign(a, to: .hidden)
            await model.flushSaves()

            #expect(model.saveFailed)
            #expect(model.state.layout.section(of: a) == .hidden)
            #expect(model.storeStatus == .ok)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            model.assign(a, to: .alwaysHidden)
            await model.flushSaves()

            #expect(!model.saveFailed)
            #expect(StateStore(fileURL: file).load() == .loaded(model.state))
        }
    }

    @Test func eachFailedSaveCountsOnce() async throws {
        try await withTempFile { file in
            let directory = file.deletingLastPathComponent()
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)
            await model.flushSaves()
            #expect(model.failedSaveCount == 0)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

            model.assign(a, to: .hidden)
            model.assign(a, to: .alwaysHidden)
            await model.flushSaves()

            #expect(model.failedSaveCount == 2)
        }
    }

    @Test func aReadOnlyRefusalIsNotAFailedSave() async throws {
        try await withTempFile { file in
            try Data(#"{"version":2}"#.utf8).write(to: file)
            let model = StateModel(store: StateStore(fileURL: file))

            model.recordSightings([(a, "A")], at: t0)
            model.assign(a, to: .hidden)
            model.update { $0.launchAtLogin = false }
            await model.flushSaves()

            #expect(model.failedSaveCount == 0)
        }
    }

    @Test func manyQuickChangesAreSavedInOrderAndTheLastOneWins() async throws {
        try await withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))
            model.recordSightings([(a, "A")], at: t0)
            let sections: [Section] = [.hidden, .alwaysHidden, .visible]

            for index in 0..<60 { model.assign(a, to: sections[index % 3]) }
            model.update { $0.launchAtLogin = false }
            await model.flushSaves()

            #expect(model.state.layout.section(of: a) == sections[59 % 3])
            #expect(StateStore(fileURL: file).load() == .loaded(model.state))
        }
    }

    @Test func aChangeUpdatesTheStateAtOnceWhileTheSaveIsStillQueued() async throws {
        try await withTempFile { file in
            let model = StateModel(store: StateStore(fileURL: file))

            model.recordSightings([(a, "A")], at: t0)

            #expect(model.state.layout.section(of: a) == .visible)
            await model.flushSaves()
        }
    }

    @Test func aFailedSaveIsCountedOnTheMainActorOnceTheQueueReportsBack() async throws {
        try await withTempFile { file in
            let directory = file.deletingLastPathComponent()
            let model = StateModel(store: StateStore(fileURL: file))
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

            model.recordSightings([(a, "A")], at: t0)
            model.assign(a, to: .hidden)
            await model.flushSaves()

            #expect(model.failedSaveCount == 2)
            #expect(model.saveFailed)
        }
    }

    @Test func buildingTheModelFromALoadWritesNothing() async throws {
        try await withTempFile { file in
            let store = StateStore(fileURL: file)
            _ = StateModel(store: store, load: .fresh)
            #expect(!FileManager.default.fileExists(atPath: file.path))

            let first = StateModel(store: store)
            first.recordSightings([(a, "A")], at: t0)
            await first.flushSaves()
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)

            let second = StateModel(store: store, load: .loaded(first.state))
            await second.flushSaves()

            #expect(second.state == first.state)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!saved.isEmpty)
        }
    }

    @Test func aRefusedLoadLeavesTheFileAloneEvenForQueuedChanges() async throws {
        try await withTempFile { file in
            let original = Data(#"{"version":2}"#.utf8)
            try original.write(to: file)
            let store = StateStore(fileURL: file)
            let model = StateModel(store: store, load: store.load())

            model.assign(a, to: .hidden)
            model.recordSightings([(a, "A")], at: t0)
            await model.flushSaves()

            #expect(try Data(contentsOf: file) == original)
        }
    }
}
