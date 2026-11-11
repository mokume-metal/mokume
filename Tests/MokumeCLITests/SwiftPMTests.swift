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
        #expect(package.declaredResourceBundles(forProduct: "demo").isEmpty)
        #expect(package.unusedResourceBundles(forProduct: "demo").isEmpty)
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
        // product の宣言が無ければ、推し量らずに全部の target を数え、何も除かない
        #expect(package.declaredResourceBundles(forProduct: "demo") == ["demo_demo.bundle"])
        #expect(package.unusedResourceBundles(forProduct: "demo").isEmpty)
    }

    /// 道具立てが書く依存の形 (`byName`・`target`・`product`) の dump。
    /// - `Demo` (実行) → `Lib` (byName) → `Core` (target)。`Lib` と `Core` は資材を持つ
    /// - `Tool` (実行・別の product) → `ToolKit` (資材つき) と `Core`
    /// - `DemoTests` (テスト) → `Demo`。`Demo` と同じ名前の置き場 `assets` を宣言する
    /// - `Unused` (どの product にも入らない・資材つき)
    private let multiProductDump = """
        {"name":"Demo",
         "products":[
           {"name":"Demo","type":{"executable":null},"targets":["Demo"]},
           {"name":"Tool","type":{"executable":null},"targets":["Tool"]}],
         "targets":[
           {"name":"Demo","type":"executable","resources":[{"rule":{"copy":{}},"path":"assets"}],
            "dependencies":[{"byName":["Lib",null]},{"product":["Mokume","mokume",null,null]}]},
           {"name":"Lib","type":"regular","resources":[{"rule":{"copy":{}},"path":"res"}],
            "dependencies":[{"target":["Core",null]}]},
           {"name":"Core","type":"regular","resources":[{"rule":{"process":{}},"path":"shaders"}]},
           {"name":"Tool","type":"executable",
            "dependencies":[{"byName":["ToolKit",null]},{"byName":["Core",null]}]},
           {"name":"ToolKit","type":"regular","resources":[{"rule":{"copy":{}},"path":"kit"}]},
           {"name":"DemoTests","type":"test","resources":[{"rule":{"copy":{}},"path":"assets"}],
            "dependencies":[{"byName":["Demo",null]}]},
           {"name":"Unused","type":"regular","resources":[{"rule":{"copy":{}},"path":"x"}]}]}
        """

    /// **配る範囲は、実行 product の依存の閉包で決める** (#3982)。テストの target・別の product の
    /// target・どこからも使われない target の資材は入れず、必須の検査も数えない。推移的に依存する
    /// target (`Lib` → `Core`) の資材は入れる。テストの target が実行 target と同じ名前の置き場
    /// (`assets`) を宣言していても、包みは target ごとなので `Demo` の分は残る。
    @Test("資材の包みは、実行 product が推移的に使う target のものだけを数え、残りを除く")
    func bundlesFollowTheProductClosure() throws {
        let package = try #require(SwiftPM.package(inDumpOf: multiProductDump))
        #expect(package.targetClosure(ofProduct: "Demo") == ["Demo", "Lib", "Core"])
        #expect(
            package.declaredResourceBundles(forProduct: "Demo")
                == ["Demo_Demo.bundle", "Demo_Lib.bundle", "Demo_Core.bundle"])
        #expect(
            package.unusedResourceBundles(forProduct: "Demo")
                == [
                    "Demo_Tool.bundle", "Demo_ToolKit.bundle", "Demo_DemoTests.bundle",
                    "Demo_Unused.bundle",
                ])
    }

    /// **別の product を束ねれば、範囲もその product の閉包になる。** 共有する `Core` は両方に入る。
    /// 名前の形 (`…Tests`) で決めていれば、ここで `ToolKit` を除いたり `Demo` を入れたりする。
    @Test("別の実行 product では、その product の閉包が配る範囲になり、共有する target は残る")
    func anotherProductHasItsOwnClosure() throws {
        let package = try #require(SwiftPM.package(inDumpOf: multiProductDump))
        #expect(package.targetClosure(ofProduct: "Tool") == ["Tool", "ToolKit", "Core"])
        #expect(
            package.declaredResourceBundles(forProduct: "Tool")
                == ["Demo_Core.bundle", "Demo_ToolKit.bundle"])
        #expect(
            package.unusedResourceBundles(forProduct: "Tool")
                == [
                    "Demo_Demo.bundle", "Demo_Lib.bundle", "Demo_DemoTests.bundle",
                    "Demo_Unused.bundle",
                ])
    }

    /// 宣言に無い product は、推し量らずに従来どおり (全部数え、何も除かない)。
    @Test("宣言に無い product では、閉包を作らず何も除かない")
    func unknownProductsExcludeNothing() throws {
        let package = try #require(SwiftPM.package(inDumpOf: multiProductDump))
        #expect(package.targetClosure(ofProduct: "Missing") == nil)
        #expect(package.unusedResourceBundles(forProduct: "Missing").isEmpty)
        #expect(package.declaredResourceBundles(forProduct: "Missing").count == 6)
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
        // ブランチで固定した依存に版は無い。**断定できないときは断定しない**
        #expect(resolved.version(of: "other") == nil)
        #expect(resolved.version(of: "absent") == nil)
    }
}
