// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

@Suite("スケッチ一式を作る")
struct NewCommandTests {
    @Test("名前と場所を読む")
    func readsTheNameAndWhereToPutIt() throws {
        #expect(try NewCommand.parse(["sketch"]) == .init(name: "sketch"))
        #expect(
            try NewCommand.parse(["sketch", "--path", "/tmp"])
                == .init(name: "sketch", path: "/tmp"))
        #expect(
            try NewCommand.parse(["sketch", "--local", "../mokume"])
                == .init(name: "sketch", path: ".", local: "../mokume"))
    }

    @Test("名前が無ければ、何をすればよいか言って止まる")
    func refusesWithoutAName() {
        #expect(throws: CommandFailure.nameMissing) { try NewCommand.parse([]) }
    }

    @Test("使えない名前を弾く")
    func rejectsNamesThatCannotBeUsed() {
        #expect(NewCommand.isValid(name: "my-sketch"))
        #expect(NewCommand.isValid(name: "sketch_2"))
        // 先頭が英字でないものはパッケージ名にも型の名前にもできない
        #expect(!NewCommand.isValid(name: "2sketch"))
        #expect(!NewCommand.isValid(name: "-sketch"))
        #expect(!NewCommand.isValid(name: "my sketch"))
        #expect(!NewCommand.isValid(name: ""))
    }

    @Test("名前から型の名前を作る")
    func buildsATypeNameFromTheName() {
        #expect(NewCommand.typeName(for: "my-sketch") == "MySketch")
        #expect(NewCommand.typeName(for: "sketch") == "Sketch")
        #expect(NewCommand.typeName(for: "a_b-c") == "ABC")
    }

    @Test("パスで指した依存は、末尾のディレクトリ名で参照する")
    func namesAPathDependencyByItsDirectory() {
        // リポジトリの名前ではなくパスの末尾が identity になる。作業用の複製を
        // 指したときに食い違うので、パスから導く
        #expect(NewCommand.packageIdentity(local: nil) == "mokume")
        #expect(NewCommand.packageIdentity(local: "/a/b/mokume") == "mokume")
        #expect(NewCommand.packageIdentity(local: "/a/b/work-copy") == "work-copy")
    }

    @Test("作られるのは 4 つ — 定義・スケッチ・無視の指定・資材の置き場")
    func writesThePackageTheSketchTheIgnoreFileAndTheAssetsDirectory() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        #expect(
            files.map(\.0) == [
                "Package.swift", "Sources/my-sketch/MySketch.swift", ".gitignore",
                "Sources/my-sketch/assets/README.md",
            ])
    }

    @Test("スケッチの入口は、資材を足しても壊れない形で書かれている")
    func theEntryPointSurvivesAddingResources() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        let sketch = try #require(files.first { $0.0.hasSuffix("MySketch.swift") }?.1)
        // **一番上に式を置かない。** 置く形は「対象の中身が 1 つだけ」のときしか
        // 通らないので、利用者が資材を 1 つ足した時点で組み上がらなくなる
        #expect(sketch.contains("@main"))
        #expect(!sketch.contains("MySketch.main()"))
    }

    @Test("作られた定義は、実行ファイルを宣言している")
    func theGeneratedPackageDeclaresAnExecutable() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        let package = try #require(files.first { $0.0 == "Package.swift" }?.1)
        // 宣言が無いと、道具が実行ファイルの場所を解決できず遠回りを払い続ける
        #expect(package.contains(#".executable(name: "my-sketch", targets: ["my-sketch"])"#))
    }

    @Test("差し込みの残りが出来上がりに混ざらない")
    func leavesNoPlaceholderBehind() throws {
        for (name, contents) in try NewCommand.files(for: .init(name: "my-sketch")) {
            #expect(!contents.contains("{{"), "\(name) に差し込みの残りがある")
        }
    }

    @Test("上限を切って版を指す")
    func pinsTheLibraryVersionWithAnUpperBound() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        let package = try #require(files.first { $0.0 == "Package.swift" }?.1)
        // 1.0 未満では次のマイナーで形が変わりうる。上限が無いと、作った時点では
        // 動いていたものが後から壊れた組み合わせを引く
        #expect(package.contains(".upToNextMinor(from: \"\(Templates.libraryVersion)\")"))
    }
}

@Suite("スケッチを走らせる")
struct RunCommandTests {
    @Test("宣言された実行ファイルの product から名前を取る")
    func findsTheExecutableProduct() {
        let dump = """
            {"products":[
              {"name":"lib","type":{"library":["automatic"]}},
              {"name":"tool","type":{"executable":null}}
            ]}
            """
        #expect(RunCommand.executableProductName(inDumpOf: dump) == "tool")
    }

    @Test("実行ファイルが無ければ、名前を作らない")
    func returnsNothingWithoutAnExecutable() {
        let dump = #"{"products":[{"name":"lib","type":{"library":["automatic"]}}]}"#
        #expect(RunCommand.executableProductName(inDumpOf: dump) == nil)
        #expect(RunCommand.executableProductName(inDumpOf: "壊れている") == nil)
    }
}
