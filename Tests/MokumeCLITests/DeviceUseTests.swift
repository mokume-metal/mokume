// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 許可の文言が要るのに無いまま、束ねない。
///
/// 判定は**呼び出しの有無だけ**を見る。ここで見るのは、**止めるべきもの**と
/// **止めてはいけないもの**の境目 — 機材に触れない作品を止めると、使わない許可の文言を
/// 書かせることになる。
@Suite("機材を使うか")
struct DeviceUseTests {
    private func makeSketch(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-device-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private let identity = AppIdentity(
        name: "Grain", identifier: "org.example.grain", version: "0.1.0")

    // MARK: - 1 本のソース

    @Test("カメラを開く呼び出しを見つける")
    func aCameraCallIsFound() {
        #expect(DeviceUse.opensCamera("camera = try? createCapture()"))
        #expect(DeviceUse.opensCamera("camera = try? createCapture(1280, 720)"))
        #expect(DeviceUse.opensCamera("camera = try? createCapture(device: devices[0])"))
        #expect(DeviceUse.opensCamera("camera = try? self.createCapture ( )"))
        #expect(
            DeviceUse.opensCamera(
                """
                camera = try? createCapture(
                    1280, 720, device: devices[0])
                """))
    }

    /// 記録した絵を流すだけで、機材も許可も使わない。
    @Test("記録した絵を流す形は、機材に触れない")
    func theInjectedFormDoesNotTouchTheDevice() {
        #expect(!DeviceUse.opensCamera("camera = try? createCapture(frames: [red])"))
        #expect(!DeviceUse.opensCamera("camera = try? createCapture(frames : recorded)"))
        #expect(
            !DeviceUse.opensCamera(
                """
                camera = try? createCapture(
                    frames: recorded)
                """))
    }

    @Test("注釈の中の名前は、使っているとは数えない")
    func commentsAreNotCalls() {
        #expect(!DeviceUse.opensCamera("// camera = createCapture()"))
        #expect(!DeviceUse.opensCamera("/// `createCapture()` で開く"))
        #expect(!DeviceUse.opensCamera("/* createCapture() */"))
        #expect(
            !DeviceUse.opensCamera(
                """
                /*
                 createCapture()
                 */
                """))
        // 注釈の外にあれば数える
        #expect(DeviceUse.opensCamera("camera = createCapture() // 開く"))
        #expect(DeviceUse.opensCamera("/* 開く */ camera = createCapture()"))
    }

    @Test("機材を数えるだけの呼び出しや、名前の一部は数えない")
    func otherNamesAreNotCalls() {
        // 一覧を引くだけでは、許可は要らない
        #expect(!DeviceUse.opensCamera("let devices = captureDevices()"))
        // 語の途中
        #expect(!DeviceUse.opensCamera("recreateCapture()"))
        // 呼び出しではない
        #expect(!DeviceUse.opensCamera("let name = \"createCapture\""))
        #expect(!DeviceUse.opensCamera(""))
    }

    // MARK: - スケッチの置き場

    @Test("使っているファイルを、スケッチからの相対で名指しする")
    func theUsersAreNamed() throws {
        let root = try makeSketch(files: [
            "Sources/mirror/Mirror.swift": "camera = try? createCapture()",
            "Sources/mirror/Nested/Other.swift": "camera = try? createCapture(640, 480)",
            "Sources/mirror/Plain.swift": "func draw() {}",
            "Sources/mirror/notes.txt": "createCapture()",
            "Sources/mirror/.hidden/Backup.swift": "createCapture()",
            "Tests/MirrorTests/Test.swift": "createCapture()",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            DeviceUse.cameraUsers(in: root)
                == ["Sources/mirror/Mirror.swift", "Sources/mirror/Nested/Other.swift"])
    }

    @Test("置き場が無ければ、使っていないものとして扱う")
    func noSourcesMeansNoUse() throws {
        let root = try makeSketch(files: ["Package.swift": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DeviceUse.cameraUsers(in: root).isEmpty)
    }

    // MARK: - 判定

    @Test("カメラを使うのに文言が無ければ止まり、使っているファイルを名指しする")
    func missingTextStops() throws {
        let root = try makeSketch(files: ["Sources/mirror/Mirror.swift": "createCapture()"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(AppIdentity.fileName).path

        #expect(
            throws: CommandFailure.cameraUsageMissing(
                path: path, files: ["Sources/mirror/Mirror.swift"])
        ) {
            try DeviceUse.check(in: root, identity: identity)
        }

        // 空白だけは書かれていないのと同じ (読み込みの段で nil になる)
        let blank = try AppIdentity.make(
            from: AppIdentity.Wire(
                name: "Grain", identifier: "org.example.grain", version: "0.1.0",
                cameraUsage: "  "),
            path: path)
        #expect(throws: (any Error).self) { try DeviceUse.check(in: root, identity: blank) }
    }

    @Test("止めるときは、足す 1 行と使っているファイルを見せる")
    func theFailureShowsTheFix() {
        let message = CommandFailure.cameraUsageMissing(
            path: "/work/mokume-app.json", files: ["Sources/mirror/Mirror.swift"]
        ).message
        #expect(message.contains("/work/mokume-app.json"))
        #expect(message.contains("Sources/mirror/Mirror.swift"))
        #expect(message.contains("\"cameraUsage\""))
    }

    @Test("文言があれば通る")
    func aWrittenTextPasses() throws {
        let root = try makeSketch(files: ["Sources/mirror/Mirror.swift": "createCapture()"])
        defer { try? FileManager.default.removeItem(at: root) }
        var written = identity
        written.cameraUsage = "for the drawing"

        #expect(throws: Never.self) { try DeviceUse.check(in: root, identity: written) }
    }

    /// 使わない作品に文言を書かせない。
    @Test("カメラを使わなければ、文言が無くても通る")
    func noUseNeedsNoText() throws {
        let root = try makeSketch(files: [
            "Sources/mirror/Mirror.swift": "camera = try? createCapture(frames: [red])"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: Never.self) { try DeviceUse.check(in: root, identity: identity) }
    }
}
