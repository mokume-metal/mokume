// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 名前が在るものに解けたのに開けないファイルを、文字のファイルを読む口がどう断るか ([#2341])。
///
/// **開けない事情を、中身の符号化の問題と名乗らない。** ディレクトリや読む権利の無いファイルを
/// ``DataFailure/unreadable(path:)`` (「UTF-8 で保存されているか確かめよ」) で断ると、利用者は
/// 保存し直すという的外れな手を勧められる。開けないものは
/// ``DataFailure/unopenable(path:location:reason:)`` で、解けた場所と OS が名乗った事情を添えて断る。
///
/// 範囲は、名前を `assetURL` で探してから `TextFile.read` で読む口すべて (``Door``)。口ごとに
/// 検査を写さず、一覧を 1 つの手順 (``expectUnopenable(_:_:onto:)``) に回す。
///
/// 走っているスケッチは要らない — どの口も、面に触れる前に投げる。ただし `requestShape` だけは
/// 呼んだ時点で読み込む面を取るので、面を差し込んで呼ぶ。面は GPU が無いと作れないので、その口は
/// GPU の条件の掛かった入れ子の suite (``NeedingCanvas``) が同じ手順で回す。
///
/// [#2341]: https://github.com/mokume-metal/mokume/issues/2341
@Suite("見つかったが開けないファイル")
struct UnopenableFileTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    /// 文字のファイルを読む口。`rg -n 'TextFile\.read' Sources` で引いた呼び出し元すべてである
    /// (`loadJSONObject` / `loadXML` は `readText`、待たない版は `requestParsed` を通る)。
    nonisolated enum Door: CaseIterable, Sendable {
        case loadStrings, requestStrings
        case loadTable, requestTable
        case loadJSONObject, requestJSONObject
        case loadXML, requestXML
        case loadShape, requestShape

        /// 呼んだ時点で読み込む面が要るか。
        var needsCanvas: Bool {
            if case .requestShape = self { return true }
            return false
        }

        static var withoutCanvas: [Door] { allCases.filter { !$0.needsCanvas } }
        static var needingCanvas: [Door] { allCases.filter(\.needsCanvas) }

        /// 口を呼ぶ。読んだ値は捨てる。
        @MainActor
        func read(_ path: String) async throws(DataFailure) {
            let sketch = Bare()
            switch self {
            case .loadStrings: _ = try sketch.loadStrings(path)
            case .requestStrings: _ = try await sketch.requestStrings(path)
            case .loadTable: _ = try sketch.loadTable(path)
            case .requestTable: _ = try await sketch.requestTable(path)
            case .loadJSONObject: _ = try sketch.loadJSONObject(path)
            case .requestJSONObject: _ = try await sketch.requestJSONObject(path)
            case .loadXML: _ = try sketch.loadXML(path)
            case .requestXML: _ = try await sketch.requestXML(path)
            case .loadShape: _ = try sketch.loadShape(path)
            case .requestShape: _ = try await sketch.requestShape(path)
            }
        }
    }

    /// 名前が在るものに解けるのに、開けないもの。
    nonisolated enum Obstacle: CaseIterable, Sendable {
        /// `data.csv` という名前のディレクトリ。
        case directory
        /// 中身の正しい CSV を `chmod 000` にしたもの。
        case noPermission

        /// 文面に出るはずの、OS が名乗る事情。
        var reason: String {
            switch self {
            case .directory: "Is a directory"
            case .noPermission: "Permission denied"
            }
        }
    }

    /// 検査ごとに別の置き場。
    struct Scratch {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-unopenable-\(UUID().uuidString)")

        /// 開けないものの名前。拡張子は表のものだが、読むのは中身を解く前に止まるので、どの口に
        /// 渡しても同じである。
        static let name = "data.csv"

        /// 開けないものを置き、その場所を返す。外した権利は ``cleanUp()`` が戻す。
        func place(_ obstacle: Obstacle) throws -> String {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(Self.name)
            switch obstacle {
            case .directory:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case .noPermission:
                try Data("a,b\n1,2\n".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
                // root で走ると権利を外しても読める。読めてしまうと、検査が見たいものを見ていない
                try #require(
                    !FileManager.default.isReadableFile(atPath: url.path), "読む権利を外せていない")
            }
            return url.path
        }

        /// 置いたものを、作業ディレクトリから辿る**相対の名前**にする。
        ///
        /// 読む口は相対の名前を、作業ディレクトリ・束ねた資源の置き場・実行ファイルの隣の順に
        /// 探す (`assetURL`)。この名前は最初の作業ディレクトリの側で解ける。作業ディレクトリ
        /// (リポジトリ) にものを置かずに済むよう、根まで上ってから一時ディレクトリへ降りる。
        static func relativeName(of absolute: String) -> String {
            let depth = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .pathComponents.count - 1
            return String(repeating: "../", count: depth) + absolute.drop { $0 == "/" }
        }

        /// 中身を書いたファイルを置き、その場所を返す。
        func file(_ name: String, _ bytes: Data) throws -> String {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            return url.path
        }

        /// 外した読む権利を戻してから、置き場を消す。
        func cleanUp() {
            let placed = folder.appendingPathComponent(Self.name).path
            if FileManager.default.fileExists(atPath: placed),
                !FileManager.default.isReadableFile(atPath: placed)
            {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: placed)
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// 口を呼んで、投げた失敗を返す。投げなければ `nil`。`canvas` を渡すと、それを読み込む面に
    /// して呼ぶ。
    static func failure(
        of door: Door, reading path: String, onto canvas: Canvas? = nil
    ) async throws -> DataFailure? {
        do {
            if let canvas {
                try await LaunchingSketch.$canvas.withValue(canvas) { try await door.read(path) }
            } else {
                try await door.read(path)
            }
            return nil
        } catch let failure as DataFailure {
            return failure
        }
    }

    /// 開けないものを口に渡すと、`unopenable` で、解けた場所と OS が名乗った事情を添え、UTF-8 に
    /// 触れずに断る。
    ///
    /// 同じものを**絶対の名前と相対の名前**の両方で渡す。相対の名前は探して解くので、渡した名前
    /// だけでは、どこにある何を直せばよいかが分からない — 文面が解けた場所を名乗ることを見る。
    static func expectUnopenable(_ door: Door, _ obstacle: Obstacle, onto canvas: Canvas? = nil) async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let placed = try scratch.place(obstacle)
        for name in [placed, Scratch.relativeName(of: placed)] {
            let failure = try await failure(of: door, reading: name, onto: canvas)
            guard case .unopenable(let named, let location, let reason) = failure else {
                Issue.record("\(door) が \(name) (\(obstacle)) を unopenable で断っていない: \(String(describing: failure))")
                continue
            }
            #expect(named == name)
            // 置いた場所そのもの。名前が相対でも、探して解けた先を `..` を畳んで名乗る
            #expect(location == placed)
            #expect(reason == obstacle.reason)
            let text = failure?.description ?? ""
            #expect(text.contains(obstacle.reason), "\(text)")
            #expect(text.contains("\"\(placed)\""), "解けた場所を名乗っていない: \(text)")
            #expect(!text.contains("UTF-8"), "中身の符号化の問題と名乗っている: \(text)")
        }
    }

    /// 開けるが中身が UTF-8 でないファイルは今までどおり `unreadable`、在らない名前は今までどおり
    /// `notFound` で探した場所が載る。開けないことの case が、手前と奥の失敗を飲み込まない。
    static func expectOtherFailuresUnchanged(_ door: Door, onto canvas: Canvas? = nil) async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        // 0xFF は UTF-8 のどこにも現れないバイト
        let invalid = try scratch.file("invalid.txt", Data([0x61, 0x2C, 0xFF, 0x0A]))
        #expect(try await failure(of: door, reading: invalid, onto: canvas) == .unreadable(path: invalid))
        // UTF-16 (BOM 付きの little endian)。UTF-8 の BOM ではないので読み飛ばさず、UTF-8 として解けない
        let utf16 = try scratch.file(
            "utf16.txt", Data([0xFF, 0xFE] + "a,b\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        #expect(try await failure(of: door, reading: utf16, onto: canvas) == .unreadable(path: utf16))
        let missing = scratch.folder.appendingPathComponent("missing.csv").path
        #expect(
            try await failure(of: door, reading: missing, onto: canvas)
                == .notFound(path: missing, searched: ImageFile.candidates(for: missing).map(\.path)))
    }

    @Test(
        "ディレクトリと読む権利の無いファイルは、unopenable で開けない事情を名乗る",
        arguments: Door.withoutCanvas, Obstacle.allCases)
    func unopenableNamesWhy(_ door: Door, _ obstacle: Obstacle) async throws {
        try await Self.expectUnopenable(door, obstacle)
    }

    @Test("中身が UTF-8 でないファイルは今までどおり unreadable、在らない名前は notFound", arguments: Door.withoutCanvas)
    func otherFailuresStayAsTheyWere(_ door: Door) async throws {
        try await Self.expectOtherFailuresUnchanged(door)
    }

    @Test("読む権利を戻した同じ CSV は、loadTable で読める")
    func restoredPermissionReads() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let path = try scratch.place(.noPermission)
        #expect(throws: DataFailure.self) { try Bare().loadTable(path, header: true) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        let table = try Bare().loadTable(path, header: true)
        #expect(table.columnTitles == ["a", "b"])
        #expect(table.rows.map { $0.getFloat("b") } == [2])
    }

    /// 呼んだ時点で読み込む面を取る口。面は GPU が無いと作れない。
    @Suite(
        "読み込む面の要る口",
        .enabled(if: RenderDevice.isAvailable, "読み込む面を作るので GPU が要る")
    )
    struct NeedingCanvas {
        private func canvas() throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        }

        @Test(
            "ディレクトリと読む権利の無いファイルは、unopenable で開けない事情を名乗る",
            arguments: Door.needingCanvas, Obstacle.allCases)
        func unopenableNamesWhy(_ door: Door, _ obstacle: Obstacle) async throws {
            try await UnopenableFileTests.expectUnopenable(door, obstacle, onto: canvas())
        }

        @Test("中身が UTF-8 でないファイルは今までどおり unreadable、在らない名前は notFound", arguments: Door.needingCanvas)
        func otherFailuresStayAsTheyWere(_ door: Door) async throws {
            try await UnopenableFileTests.expectOtherFailuresUnchanged(door, onto: canvas())
        }
    }
}
