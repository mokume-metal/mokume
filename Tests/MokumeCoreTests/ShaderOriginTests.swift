// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 見張りの下で、資材の置き場の断片を元のファイルから読む (#2517)。**GPU を使わない。**
///
/// 見張りの子は作業ディレクトリがスケッチの根で、断片の候補は束の写しに解ける。見張りが渡す
/// 置き場の元 (`MOKUME_ASSET_ORIGIN`) が、**作業ディレクトリの次**に差されることを見る。
@Suite("見張りの下の、置き場の断片の在処")
struct ShaderOriginTests {
    private let origin = URL(fileURLWithPath: "/work/sketch/Sources/wa/assets", isDirectory: true)

    /// 作業ディレクトリ → 束の資源 → 束の隣、の並び (実物と同じ形)。
    private func candidates(for path: String) -> [URL] {
        ImageFile.candidates(
            for: path, workingDirectory: "/work/sketch",
            neighbourhood: URL(fileURLWithPath: "/work/sketch/.build/Debug", isDirectory: true),
            resources: URL(fileURLWithPath: "/work/sketch/.build/Debug/wa_wa.bundle/Contents/Resources"))
    }

    @Test("置き場の断片は、作業ディレクトリの次 (束の写しより先) に置き場の元を探す")
    func theOriginComesRightAfterTheWorkingDirectory() {
        let before = candidates(for: "assets/paint.metal")
        let after = ShaderOrigin.inserting(origin: origin, for: "assets/paint.metal", into: before)
        #expect(after.count == before.count + 1)
        #expect(after[0] == before[0], "作業ディレクトリが先 (今までどおり)")
        #expect(after[1].path == "/work/sketch/Sources/wa/assets/paint.metal")
        #expect(Array(after.dropFirst(2)) == Array(before.dropFirst()), "残りは今までの並びのまま")
        // 入れ子の下も置き場の下に解く
        let nested = ShaderOrigin.inserting(
            origin: origin, for: "assets/fx/blur.metal", into: candidates(for: "assets/fx/blur.metal"))
        #expect(nested[1].path == "/work/sketch/Sources/wa/assets/fx/blur.metal")
    }

    @Test("合図が無ければ、置き場の断片も今までの並びのまま")
    func withoutTheSignalNothingChanges() {
        let before = candidates(for: "assets/paint.metal")
        #expect(ShaderOrigin.inserting(origin: nil, for: "assets/paint.metal", into: before) == before)
    }

    @Test("置き場の名前で始まらない・絶対パス・置き場の外へ出る名前は、今までの並びのまま")
    func namesOutsideTheDirectoryAreLeftAlone() {
        for path in [
            "paint.metal", "other/paint.metal", "assets", "assets/../paint.metal",
            "assets/./paint.metal", "/abs/assets/paint.metal", "assetsX/paint.metal",
        ] {
            let before = candidates(for: path)
            #expect(
                ShaderOrigin.inserting(origin: origin, for: path, into: before) == before,
                "\(path) の並びが変わった")
        }
    }

    @Test("読む鍵は一覧から取り、絶対パスでない値や空白だけの値は渡されていないものとする")
    func theSignalIsReadFromTheListAndMustBeAbsolute() {
        let key = StartupReads.assetOrigin.key
        #expect(StartupReads.all.contains(StartupReads.assetOrigin))
        #expect(StartupReads.assetOrigin.origin == .environment)
        #expect(StartupReads.assetOrigin.decidedBy == .tool)
        #expect(ShaderOrigin.startup(environment: [:]) == nil)
        #expect(ShaderOrigin.startup(environment: [key: "  "]) == nil)
        #expect(
            ShaderOrigin.startup(environment: [key: "Sources/wa/assets"]) == nil,
            "相対は読む側で別の場所になる")
        #expect(
            ShaderOrigin.startup(environment: [key: " /work/sketch/Sources/wa/assets \n"])?.path
                == "/work/sketch/Sources/wa/assets")
    }

    // MARK: - 断片の口 (ShaderSource.read)

    private func makeFragment(_ body: String, under root: URL) throws -> URL {
        let assets = root.appendingPathComponent("Sources/wa/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try body.write(
            to: assets.appendingPathComponent("paint.metal"), atomically: true, encoding: .utf8)
        return assets
    }

    @Test("断片の口は、置き場の元があればそこから読み、保存した中身が読める")
    func readFindsTheFragmentAtTheOrigin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-origin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try makeFragment("// red", under: root)

        let found = try ShaderSource.read(at: "assets/paint.metal", origin: assets)
        #expect(
            found.url.standardizedFileURL.path
                == assets.appendingPathComponent("paint.metal").standardizedFileURL.path)
        #expect(found.body == "// red")
        #expect(found.name == "paint")

        // 置き場に無い断片は、元を差しても今までの並びのまま探して見つからない
        #expect(throws: ShaderFailure.self) {
            try ShaderSource.read(at: "assets/missing.metal", origin: assets)
        }
    }

    @Test("合図が無ければ、同じ名前でも元は探さない (見張りの外の解き方は変わらない)")
    func readIgnoresTheOriginWithoutTheSignal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-origin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeFragment("// red", under: root)
        #expect(throws: ShaderFailure.self) {
            try ShaderSource.read(at: "assets/paint.metal", origin: nil)
        }
    }
}
