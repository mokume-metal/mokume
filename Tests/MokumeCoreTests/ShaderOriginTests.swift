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

    /// 束の写し (資源の置き場の下) が在る、として答える。
    private static let bundleCopyExists: (URL) -> Bool = { $0.path.contains("/Contents/Resources/") }

    @Test("置き場の断片は、作業ディレクトリの次 (束の写しより先) に置き場の元を探す")
    func theOriginComesRightAfterTheWorkingDirectory() {
        let before = candidates(for: "assets/paint.metal")
        let after = ShaderOrigin.inserting(
            origin: origin, for: "assets/paint.metal", into: before, exists: Self.bundleCopyExists)
        #expect(after.count == before.count + 1)
        #expect(after[0] == before[0], "作業ディレクトリが先 (今までどおり)")
        #expect(after[1].path == "/work/sketch/Sources/wa/assets/paint.metal")
        #expect(Array(after.dropFirst(2)) == Array(before.dropFirst()), "残りは今までの並びのまま")
        // 入れ子の下も置き場の下に解く
        let nested = ShaderOrigin.inserting(
            origin: origin, for: "assets/fx/blur.metal", into: candidates(for: "assets/fx/blur.metal"),
            exists: Self.bundleCopyExists)
        #expect(nested[1].path == "/work/sketch/Sources/wa/assets/fx/blur.metal")
    }

    @Test("合図が無ければ、置き場の断片も今までの並びのまま")
    func withoutTheSignalNothingChanges() {
        let before = candidates(for: "assets/paint.metal")
        #expect(
            ShaderOrigin.inserting(
                origin: nil, for: "assets/paint.metal", into: before, exists: Self.bundleCopyExists)
                == before)
    }

    @Test("置き場の名前で始まらない・絶対パス・置き場の外へ出る名前は、今までの並びのまま")
    func namesOutsideTheDirectoryAreLeftAlone() {
        for path in [
            "paint.metal", "other/paint.metal", "assets", "assets/../paint.metal",
            "assets/./paint.metal", "/abs/assets/paint.metal", "assetsX/paint.metal",
        ] {
            let before = candidates(for: path)
            #expect(
                ShaderOrigin.inserting(
                    origin: origin, for: path, into: before, exists: Self.bundleCopyExists) == before,
                "\(path) の並びが変わった")
        }
    }

    /// **束に写されていない断片は、見張りだけが元から読んで隠さない** (資材の宣言の検査が止めるはずの抜け)。
    @Test("束の写しが無い断片は、置き場の元を差さず、変更前どおり見つからない")
    func aFragmentTheBundleLacksIsLeftAlone() {
        let before = candidates(for: "assets/paint.metal")
        let after = ShaderOrigin.inserting(
            origin: origin, for: "assets/paint.metal", into: before, exists: { _ in false })
        #expect(after == before, "束に無い断片に元を差している")
        // 作業ディレクトリ側にしか無いものは「束の写し」ではない
        let onlyWorkingDirectory = ShaderOrigin.inserting(
            origin: origin, for: "assets/paint.metal", into: before, exists: { $0 == before[0] })
        #expect(onlyWorkingDirectory == before)
    }

    /// 束の写しの解き方 (APFS の既定) と揃える。
    @Test("置き場の名前は大文字小文字を区別せずに比べる")
    func theDirectoryNameIsComparedWithoutCase() {
        let before = candidates(for: "Assets/paint.metal")
        let after = ShaderOrigin.inserting(
            origin: origin, for: "Assets/paint.metal", into: before, exists: Self.bundleCopyExists)
        #expect(after.count == before.count + 1)
        #expect(after[1].path == "/work/sketch/Sources/wa/assets/paint.metal")
    }

    /// 合図はこのプロセスを起こした見張りのもので、このプロセスが起こす子のものではない。
    @Test("合図は読んだときに環境から消え、控えは 1 度きりである")
    func theSignalIsTakenOutOfTheEnvironment() {
        let key = StartupReads.assetOrigin.key
        var unset: [String] = []
        let taken = ShaderOrigin.take(from: [key: "/work/Sources/wa/assets"], unset: { unset.append($0) })
        #expect(taken?.path == "/work/Sources/wa/assets")
        #expect(unset == [key], "読んだのに環境から消していない")
        // 無ければ消すものも無い
        unset = []
        #expect(ShaderOrigin.take(from: [:], unset: { unset.append($0) }) == nil)
        #expect(unset.isEmpty)
        // 絶対パスでなくても、渡された変数は消す (孫へ継がせない)
        _ = ShaderOrigin.take(from: [key: "relative"], unset: { unset.append($0) })
        #expect(unset == [key])
    }

    /// **配線**: 既定の引数が本物の環境から読む。既定を `nil` に戻すと、置き場の元を見つけられなくなる。
    @Test("断片の口は、既定の引数で環境の合図を読み、読んだら環境から消す")
    func readUsesTheEnvironmentSignalByDefault() throws {
        let name = "mokume-origin-test-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        let fragment = assets.appendingPathComponent("paint.metal")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "// green".write(to: fragment, atomically: true, encoding: .utf8)
        // 束の写しがある、という候補の並び (写しの在処は別の場所で、中身は元と違う)
        let bundled = root.appendingPathComponent("bundled/assets/paint.metal")
        try FileManager.default.createDirectory(
            at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// red".write(to: bundled, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("nowhere/assets/paint.metal")
        let find: (String) -> [URL] = { _ in [missing, bundled] }

        let key = StartupReads.assetOrigin.key
        ShaderOrigin.forgetStartup()
        setenv(key, assets.path, 1)
        defer {
            unsetenv(key)
            ShaderOrigin.forgetStartup()
        }

        // 置き場の名前 (assets) で始まる名前だけが対象で、元の中身が読める
        let found = try ShaderSource.read(at: "assets/paint.metal", candidates: find)
        #expect(found.body == "// green", "環境の合図を読んでいない (束の写しを読んだ)")
        #expect(getenv(key) == nil, "読んだのに環境に残っている (孫へ継がれる)")
        // 控えているので、環境が消えても 2 度目以降も同じ答え
        #expect(try ShaderSource.read(at: "assets/paint.metal", candidates: find).body == "// green")
    }

    @Test("読む鍵は一覧から取り、絶対パスでない値や空白だけの値は渡されていないものとする")
    func theSignalIsReadFromTheListAndMustBeAbsolute() {
        let key = StartupReads.assetOrigin.key
        #expect(StartupReads.all.contains(StartupReads.assetOrigin))
        #expect(StartupReads.assetOrigin.origin == .environment)
        #expect(StartupReads.assetOrigin.decidedBy == .tool)
        #expect(ShaderOrigin.origin(from: [:]) == nil)
        #expect(ShaderOrigin.origin(from: [key: "  "]) == nil)
        #expect(
            ShaderOrigin.origin(from: [key: "Sources/wa/assets"]) == nil,
            "相対は読む側で別の場所になる")
        #expect(
            ShaderOrigin.origin(from: [key: " /work/sketch/Sources/wa/assets \n"])?.path
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

    /// 束の写しがある (中身は元と違う) 候補の並び。
    private func withBundledCopy(under root: URL, _ body: (@escaping (String) -> [URL]) throws -> Void) throws {
        let bundled = root.appendingPathComponent("bundled/assets/paint.metal")
        try FileManager.default.createDirectory(
            at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// bundled".write(to: bundled, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("nowhere/assets/paint.metal")
        try body({ _ in [missing, bundled] })
    }

    @Test("断片の口は、束にも写されていれば置き場の元から読み、保存した中身が読める")
    func readFindsTheFragmentAtTheOrigin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-origin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try makeFragment("// green", under: root)

        try withBundledCopy(under: root) { find in
            let found = try ShaderSource.read(at: "assets/paint.metal", origin: assets, candidates: find)
            #expect(
                found.url.standardizedFileURL.path
                    == assets.appendingPathComponent("paint.metal").standardizedFileURL.path)
            #expect(found.body == "// green")
            #expect(found.name == "paint")

            // 元に無ければ、今までの並び (束の写し) へ落ちる
            try FileManager.default.removeItem(at: assets.appendingPathComponent("paint.metal"))
            #expect(
                try ShaderSource.read(at: "assets/paint.metal", origin: assets, candidates: find).body
                    == "// bundled")
        }
    }

    /// **束に入っていない断片を、見張りだけが元から読まない** (資材の宣言の検査が止めるはずの抜け)。
    @Test("束に写されていない断片は、元が在っても変更前どおり見つからない")
    func readDoesNotHideAFragmentTheBundleLacks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-origin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try makeFragment("// green", under: root)
        let missing = root.appendingPathComponent("nowhere/assets/paint.metal")
        #expect(throws: ShaderFailure.self) {
            try ShaderSource.read(at: "assets/paint.metal", origin: assets, candidates: { _ in [missing] })
        }
    }

    @Test("合図が無ければ、同じ名前でも元は探さない (見張りの外の解き方は変わらない)")
    func readIgnoresTheOriginWithoutTheSignal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-origin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeFragment("// green", under: root)
        let missing = root.appendingPathComponent("nowhere/assets/paint.metal")
        #expect(throws: ShaderFailure.self) {
            try ShaderSource.read(at: "assets/paint.metal", origin: nil, candidates: { _ in [missing] })
        }
    }
}
