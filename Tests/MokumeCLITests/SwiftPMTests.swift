// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 道具立て (SwiftPM) が書く JSON の読み方。
///
/// **鍵の綴りは 1 箇所しかない。** 読み手が銘々 `as?` で降りていたころは、道具立てが
/// 形を変えると 4 箇所とも「黙って `nil`」へ落ち、どれも `nil` を正常系 (宣言が無い)
/// として扱うので**壊れたことが症状に出なかった**。
@Suite("道具立てが書く JSON")
struct SwiftPMTests {
    // MARK: - dump-package

    /// **鍵が在るかどうかで決まる。** 道具立ては `{"executable": null}` と書くので、
    /// 値を読むと「null」と「鍵が無い」の区別が付かない。
    @Test("実行ファイルかどうかは、種別の鍵が在るかで決まる")
    func executablesAreNamedByTheKeyBeingThere() throws {
        let dump = """
            {"name":"demo","products":[
              {"name":"lib","type":{"library":["automatic"]}},
              {"name":"tool","type":{"executable":null}}
            ]}
            """
        let package = try #require(SwiftPM.package(inDumpOf: dump))
        #expect(package.executableProductName == "tool")
    }

    @Test("実行ファイルが無ければ、名前を作らない")
    func packagesWithoutAnExecutableNameNothing() throws {
        let dump = #"{"name":"demo","products":[{"name":"lib","type":{"library":["automatic"]}}]}"#
        let package = try #require(SwiftPM.package(inDumpOf: dump))
        #expect(package.executableProductName == nil)
    }

    /// **空と「鍵が無い」は同じ意味。** 宣言していないものを道具立てがどう書くかは
    /// 版で動くので、どちらも「宣言が無い」として読む。
    @Test("宣言していない鍵が無くても読める")
    func absentDeclarationsReadAsEmpty() throws {
        let package = try #require(SwiftPM.package(inDumpOf: #"{"name":"demo"}"#))
        #expect(package.products.isEmpty)
        #expect(package.targets.isEmpty)
        #expect(package.platforms.isEmpty)
        #expect(package.minimumMacOSVersion == nil)
        #expect(package.declaredResourceBundles.isEmpty)
    }

    @Test("dump-package の出力でなければ、読めたことにしない")
    func nonPackageDocumentsAreNotRead() {
        // 名前だけは必ず在る。無ければ別の JSON を読まされている
        #expect(SwiftPM.package(inDumpOf: "{}") == nil)
        #expect(SwiftPM.package(inDumpOf: "壊れている") == nil)
    }

    @Test("資材を宣言した target だけが、包みの名前になる")
    func onlyTargetsWithResourcesGetABundle() throws {
        let dump = """
            {"name":"demo","targets":[
              {"name":"demo","resources":[{"rule":{"copy":{}},"path":"assets"}]},
              {"name":"quiet"}
            ]}
            """
        let package = try #require(SwiftPM.package(inDumpOf: dump))
        #expect(package.declaredResourceBundles == ["demo_demo.bundle"])
    }

    @Test("名乗っている macOS の下限を読む")
    func theMinimumMacOSVersionIsRead() throws {
        let dump = """
            {"name":"demo","platforms":[
              {"platformName":"ios","version":"18.0"},
              {"platformName":"macos","version":"26.0"}
            ]}
            """
        #expect(try #require(SwiftPM.package(inDumpOf: dump)).minimumMacOSVersion == "26.0")
    }

    // MARK: - .build/workspace-state.json

    private func workspaceState(_ json: String) throws -> SwiftPM.WorkspaceState {
        try #require(SwiftPM.read(SwiftPM.WorkspaceState.self, from: Data(json.utf8)))
    }

    /// パスで指した依存は、絶対パスがそのまま載る。
    @Test("パスで指した依存は、書かれている場所をそのまま指す")
    func pathDependenciesPointWhereTheyAre() throws {
        let state = try workspaceState(
            """
            {"object":{"dependencies":[
              {"packageRef":{"name":"mokume"},
               "state":{"name":"fileSystem","path":"/work/mokume"}}
            ]}}
            """)
        let work = URL(fileURLWithPath: "/sketch", isDirectory: true)
        #expect(state.resolved("mokume", under: work)?.path == "/work/mokume")
    }

    /// 取ってきた依存は `.build/checkouts/` の下に置かれる。
    @Test("取ってきた依存は、作業ディレクトリの下を指す")
    func fetchedDependenciesPointIntoTheCheckouts() throws {
        let state = try workspaceState(
            """
            {"object":{"dependencies":[
              {"packageRef":{"name":"mokume"},
               "state":{"name":"sourceControlCheckout"},"subpath":"mokume"}
            ]}}
            """)
        // **受けるのは置き場そのもの。** `.build` を足すのは呼ぶ側の仕事ではない —
        // 置き場はパッケージ直下とは限らない (ADR-0037)
        let build = URL(fileURLWithPath: "/sketch/.build", isDirectory: true)
        #expect(state.resolved("mokume", under: build)?.path == "/sketch/.build/checkouts/mokume")
        let shared = URL(fileURLWithPath: "/store/swiftlang-1/0.7.1", isDirectory: true)
        #expect(
            state.resolved("mokume", under: shared)?.path == "/store/swiftlang-1/0.7.1/checkouts/mokume",
            "共有の置き場でも同じ 1 本の計算で引ける")
    }

    @Test("名前の合わない依存は取り違えない")
    func otherDependenciesAreNotMistaken() throws {
        let state = try workspaceState(
            """
            {"object":{"dependencies":[
              {"packageRef":{"name":"mokume-extras"},
               "state":{"name":"fileSystem","path":"/work/extras"}}
            ]}}
            """)
        #expect(state.resolved("mokume", under: URL(fileURLWithPath: "/sketch")) == nil)
    }

    // MARK: - Package.resolved

    @Test("版で固定した pin だけが、版を名乗る")
    func onlyVersionPinsHaveAVersion() throws {
        let resolved = try #require(
            SwiftPM.read(
                SwiftPM.Resolved.self,
                from: Data(
                    """
                    {"pins":[
                      {"identity":"mokume","state":{"version":"0.4.0"}},
                      {"identity":"other","state":{"branch":"main","revision":"abc"}}
                    ]}
                    """.utf8)))
        #expect(resolved.version(of: "mokume") == "0.4.0")
        // 枝で固定した依存に版は無い。**断定できないときは断定しない**
        #expect(resolved.version(of: "other") == nil)
        #expect(resolved.version(of: "absent") == nil)
    }
}
