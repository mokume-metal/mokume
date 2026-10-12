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
                from: AppIdentity.Wire(name: "Grain", identifier: "  ", version: ""),
                path: "/demo")
        }
    }

    @Test("足りないものを名指しする")
    func theMissingKeysAreNamed() {
        let failure = CommandFailure.identityIncomplete(path: "/demo", missing: ["identifier"])
        #expect(failure.message.contains("identifier"))
    }

    // MARK: - 名前はファイル名にもなる (#2309)

    /// **`name` は表示名であり、包みのファイル名 (`bundle/<name>.app`) と開き方の紙の名前にも
    /// なる。** `/` があると `--out` の下に余計なディレクトリを作って途中で止まり、`..` と組むと
    /// `--out` の外の `.app` を消していた ([#2309](https://github.com/mokume-metal/mokume/issues/2309))。
    /// 組み立ての前 (名乗りを読む段) に、使えないものを名指して断る (メンテナの決定: 案 B)。
    @Test(
        "name に / があれば、使えないものを名指して止まる",
        arguments: ["AC/DC", "../victim", "/", "Bund/", "a/../b"])
    func aNameWithASlashIsRefused(name: String) {
        let path = "/demo/mokume-app.json"
        let thrown = #expect(throws: CommandFailure.self) {
            try AppIdentity.make(
                from: AppIdentity.Wire(
                    name: name, identifier: "org.example.bund", version: "0.1.0"),
                path: path)
        }
        #expect(thrown == .identityNameUnusable(path: path, name: name))
        let message = thrown?.message ?? ""
        #expect(message.contains("\"/\""), "使えないもの (/) を名指していない: \(message)")
        #expect(message.contains(name), "渡された名前を名乗っていない: \(message)")
        #expect(message.contains(path), "名乗りの場所を名乗っていない: \(message)")
    }

    /// 裏側。**`/` の無い名前は、空白・日本語・点だけでも通る** — `..` は `/` と組まなければ
    /// 場所を動かさない (`...app` という名前になるだけ)。
    @Test("/ の無い名前は、いままでどおり通る", arguments: ["Bund", "My Sketch", "木目", "..", "."])
    func aNameWithoutASlashPasses(name: String) throws {
        let identity = try AppIdentity.make(
            from: AppIdentity.Wire(name: name, identifier: "org.example.bund", version: "0.1.0"),
            path: "/demo/mokume-app.json")
        #expect(identity.name == name)
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

    // MARK: - 許可の文言

    private let withTexts = """
        {
          "name": "Grain",
          "identifier": "org.example.grain",
          "version": "0.1.0",
          "cameraUsage": "Grain looks at the camera to draw what it sees",
          "microphoneUsage": "Grain listens to the room to move"
        }
        """

    @Test("許可の文言は、書いてあれば読める")
    func writtenUsageTextsAreRead() throws {
        let root = try makeSketch(identity: withTexts)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try AppIdentity.read(in: root)
        #expect(identity.cameraUsage == "Grain looks at the camera to draw what it sees")
        #expect(identity.microphoneUsage == "Grain listens to the room to move")
    }

    /// 要らない作品がほとんどなので、書かなくても名乗りは揃う。
    @Test("許可の文言は、無くても名乗りは揃う")
    func usageTextsAreOptional() throws {
        let root = try makeSketch(identity: AppIdentity.example)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try AppIdentity.read(in: root)
        #expect(identity.cameraUsage == nil)
        #expect(identity.microphoneUsage == nil)
    }

    /// 鍵があることではなく、見せられる中身があることを見る。
    @Test("空白だけの文言は、書かれていないものとして扱う")
    func blankUsageTextsCountAsMissing() throws {
        let identity = try AppIdentity.make(
            from: AppIdentity.Wire(
                name: "Grain", identifier: "org.example.grain", version: "0.1.0",
                cameraUsage: "   ", microphoneUsage: ""),
            path: "/demo")
        #expect(identity.cameraUsage == nil)
        #expect(identity.microphoneUsage == nil)
    }

    /// 文言を持たない作品の包みに空の鍵を置くと、使わない許可を名乗ることになる。
    @Test("文言は、書かれているものだけ包みの一覧に入る")
    func usageTextsEnterThePropertyListOnlyWhenWritten() {
        let plain = AppIdentity(name: "Grain", identifier: "org.example.grain", version: "0.1.0")
        let none = plain.infoPlist(executable: "grain", minimumSystemVersion: "26.0")
        #expect(none["NSCameraUsageDescription"] == nil)
        #expect(none["NSMicrophoneUsageDescription"] == nil)

        var camera = plain
        camera.cameraUsage = "for the drawing"
        let onlyCamera = camera.infoPlist(executable: "grain", minimumSystemVersion: "26.0")
        #expect(onlyCamera["NSCameraUsageDescription"] as? String == "for the drawing")
        #expect(onlyCamera["NSMicrophoneUsageDescription"] == nil)

        var microphone = plain
        microphone.microphoneUsage = "for the motion"
        let onlyMicrophone = microphone.infoPlist(
            executable: "grain", minimumSystemVersion: "26.0")
        #expect(onlyMicrophone["NSMicrophoneUsageDescription"] as? String == "for the motion")
        #expect(onlyMicrophone["NSCameraUsageDescription"] == nil)
    }

    /// 文言と entitlement を別々に宣言させると、片方だけ書いた食い違い (文言はあるのに
    /// ダイアログも出ずに拒否される) を作れてしまう。
    @Test("entitlement は、文言を書いた機材の分だけになる")
    func entitlementsFollowTheTexts() {
        let plain = AppIdentity(name: "Grain", identifier: "org.example.grain", version: "0.1.0")
        #expect(plain.entitlements.isEmpty)

        var camera = plain
        camera.cameraUsage = "for the drawing"
        #expect(camera.entitlements == ["com.apple.security.device.camera": true])

        var microphone = plain
        microphone.microphoneUsage = "for the motion"
        #expect(microphone.entitlements == ["com.apple.security.device.audio-input": true])

        var both = camera
        both.microphoneUsage = "for the motion"
        #expect(
            both.entitlements == [
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ])
    }
}
