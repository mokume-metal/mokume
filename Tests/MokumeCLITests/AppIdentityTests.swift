// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 束ねた作品の名乗り。
///
/// **書かれていないまま配られるのを止める**のがここの仕事で、書き方まで示す。
@Suite("作品の名乗り")
struct AppIdentityTests {
    private func makeSketch(identity: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let identity {
            try identity.write(
                to: root.appendingPathComponent(AppIdentity.fileName), atomically: true,
                encoding: .utf8)
        }
        return root
    }

    @Test("書いてあれば読める")
    func aWrittenIdentityIsRead() throws {
        let root = try makeSketch(identity: AppIdentity.example)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            try AppIdentity.read(in: root)
                == AppIdentity(name: "Grain", identifier: "org.example.grain", version: "0.1.0"))
    }

    @Test("置かれていなければ止まり、書き方を見せる")
    func aMissingIdentityStops() throws {
        let root = try makeSketch(identity: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(AppIdentity.fileName).path
        #expect(throws: CommandFailure.identityMissing(path: path)) {
            try AppIdentity.read(in: root)
        }
        #expect(CommandFailure.identityMissing(path: path).message.contains(AppIdentity.example))
    }

    @Test("形が壊れていれば、その旨を言う")
    func anUnreadableIdentityStops() throws {
        let root = try makeSketch(identity: "{ これは JSON ではない")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            throws: CommandFailure.identityUnreadable(
                path: root.appendingPathComponent(AppIdentity.fileName).path)
        ) { try AppIdentity.read(in: root) }
    }

    /// 鍵があることではなく、名乗れる中身があることを見る。
    @Test("空白だけの値は、書かれていないものとして扱う")
    func blankValuesCountAsMissing() {
        #expect(
            throws: CommandFailure.identityIncomplete(
                path: "/demo", missing: ["identifier", "version"])
        ) {
            try AppIdentity.make(
                from: ["name": "Grain", "identifier": "  ", "version": ""], path: "/demo")
        }
    }

    @Test("足りないものを名指しする")
    func theMissingKeysAreNamed() {
        let failure = CommandFailure.identityIncomplete(path: "/demo", missing: ["identifier"])
        #expect(failure.message.contains("identifier"))
    }

    @Test("名乗りが、包みが読む一覧になる")
    func theIdentityBecomesThePropertyList() {
        let identity = AppIdentity(
            name: "Grain", identifier: "org.example.grain", version: "0.1.0")
        let plist = identity.infoPlist(executable: "grain", minimumSystemVersion: "26.0")
        #expect(plist["CFBundleExecutable"] as? String == "grain")
        #expect(plist["CFBundleIdentifier"] as? String == "org.example.grain")
        #expect(plist["CFBundleName"] as? String == "Grain")
        #expect(plist["CFBundleShortVersionString"] as? String == "0.1.0")
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
    }
}
