// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// `new <name>` が、組めないパッケージを作る名前を書き始める前に断る
/// ([#2310](https://github.com/mokume-metal/mokume/issues/2310))。
///
/// **約束: `Created` と言って作ったパッケージは、そのまま `swift build` で組める。** 文字の種類
/// (``NewCommand/isValid(name:)``) だけを見ていた頃は、`sketch` が `Created` の後に
/// `'Sketch' inherits from itself` で組めなかった。
///
/// 組めない名前は、実際に `swift build` で確かめた (2026-10-13・Swift 6.3)。ここの表はその結果で、
/// 一覧の側にあるものは断り、一覧に無いものは作る。
@Suite("組めない名前を断る")
struct NewNameTests {
    private func unusable(_ arguments: [String]) -> (name: String, reason: String)? {
        do {
            _ = try NewCommand.parse(arguments)
            return nil
        } catch let failure as CommandFailure {
            guard case .unusableName(let name, let reason) = failure else { return nil }
            return (name, reason)
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------------ 完了条件 1・2

    /// 名前ごとの `swift build` の結果 (実測):
    ///
    /// | 名前 | 組めない理由 |
    /// | --- | --- |
    /// | `sketch`・`Sketch` | `'Sketch' inherits from itself` (ひな形の型名が mokume の `Sketch` と同じ) |
    /// | `sketch-settings` | 型 `SketchSettings` が mokume の `SketchSettings` を隠す |
    /// | `Self`・`self`・`Any` | `keyword 'Self' cannot be used as an identifier here` |
    /// | `mokume`・`Mokume` | `cyclic dependency declaration found` (作るパッケージの identity が依存と同じ) |
    /// | `MokumeCore` ほか | `multiple packages … declare targets with a conflicting name` |
    /// | `Foundation` | `module dependency cycle` (ひな形が import するモジュール) |
    /// | `Swift` | `module name "Swift" is reserved for the standard library` |
    @Test(
        "組めない名前は、使えない名前として止まり、名前と別の名前の例を言う",
        arguments: [
            "sketch", "Sketch", "sketch-settings", "sketch_settings", "Self", "self", "Any",
            "mokume", "Mokume", "MokumeCore", "MokumeCamera", "MokumeAudio", "MokumeNetwork",
            "MokumeDiagnostics", "MokumeMacros", "Foundation", "Swift",
        ])
    func anUnbuildableNameIsRefused(name: String) throws {
        let refused = try #require(unusable([name]), "\(name) が断られていない")
        #expect(refused.name == name)
        let message = CommandFailure.unusableName(name: refused.name, reason: refused.reason).message
        #expect(message.contains(name), "名前を言っていない: \(message)")
        #expect(message.contains("my-\(name.lowercased())"), "別の名前の例を言っていない: \(message)")
    }

    /// **何も書かずに断る。** 止まった後にディレクトリが残ると、打ち直しが「Already there」になる。
    @Test("断った名前は、ディレクトリを作らない")
    func nothingIsWrittenForARefusedName() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-new-refused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        for name in ["sketch", "Self", "mokume", "MokumeCore"] {
            #expect(throws: CommandFailure.self) {
                try NewCommand.run([name, "--path", parent.path])
            }
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(left.isEmpty, "断ったのに書かれたものがある: \(left)")
    }

    /// 組めた名前は、いままでどおり作られる。**一覧の外へ断る範囲を広げていないこと**を固定する。
    @Test(
        "組める名前は、断られない",
        arguments: [
            "my-sketch", "sketch_2", "café", "a½", "Type", "Protocol", "Never", "Error", "Main",
            "frame-rate-probe", "mokumecore", "main", "class", "test", "grain", "sketch2",
            "my-sketch-settings", "Sketches",
        ])
    func aBuildableNameIsKept(name: String) throws {
        #expect(NewCommand.isValid(name: name))
        #expect(unusable([name]) == nil, "組める名前が断られた: \(name)")
        #expect(try NewCommand.parse([name]).name == name)
    }

    /// 文字の種類の誤りは、これまでどおり別の失敗 (`invalidName`) で、一覧には入らない。
    @Test("文字の誤りは、従来の失敗のまま")
    func invalidCharactersKeepTheirOwnFailure() {
        #expect(throws: CommandFailure.invalidName("1abc")) { try NewCommand.parse(["1abc"]) }
        #expect(throws: CommandFailure.invalidName("a b")) { try NewCommand.parse(["a b"]) }
    }

    // ------------------------------------------------------------ 依存と同じ名前

    /// **依存のパッケージの名前 (identity) と、作るパッケージの名前が同じだと組めない。**
    /// 作るディレクトリの名前が identity になるので、`--local` が同じ名前で終わる場所を指すと、
    /// 作るパッケージは自分自身に依存する形になる。本体の置き場の名前は人ごとに違う
    /// (`mokume`・作業用の複製の名前) ので、名前の一覧には載らない。
    @Test("--local の末尾と同じ名前は、断る (大小は問わない)")
    func aNameEqualToTheDependencyIdentityIsRefused() {
        for (name, local) in [("frog", "/w/frog"), ("Frog", "/w/frog"), ("frog", "../Frog.git")] {
            let options = NewCommand.Options(name: name, local: local)
            let refused = #expect(throws: CommandFailure.self) {
                try NewCommand.files(
                    for: options, base: URL(fileURLWithPath: "/w/typed", isDirectory: true))
            }
            guard case .unusableName(let refusedName, _)? = refused else {
                Issue.record("\(name) / \(local) が断られていない: \(String(describing: refused))")
                continue
            }
            #expect(refusedName == name)
        }
    }

    /// 裏。**違う名前なら作る。** 作業用の複製 (`work-copy`) を指して、別の名前のスケッチを作る
    /// いつもの形。
    @Test("--local の末尾と違う名前は、いままでどおり作る")
    func aDifferentNameIsKept() throws {
        let files = try NewCommand.files(
            for: .init(name: "foo", local: "/a/b/work-copy"),
            base: URL(fileURLWithPath: "/w/typed", isDirectory: true))
        #expect(files.contains { $0.0 == "Package.swift" })
    }

    // ------------------------------------------------------------ 完了条件 3・4: 一覧の突き合わせ

    /// 完了条件 3。**ひな形が mokume から使う型を、断る一覧と突き合わせる。** ひな形に
    /// 型の参照を足したとき (たとえば `Color`)、作る型の名前がそれと衝突して組めなくなるのに、
    /// 一覧に足し忘れると誰も気付かない。
    @Test("ひな形 Sketch.swift が参照する型は、すべて断る一覧に載っている")
    func everyTypeTheTemplateUsesIsListed() throws {
        let template = try Self.template("Sketch.swift.template")
        let withoutHoles = template.replacingOccurrences(
            of: #"\{\{[A-Z]+\}\}"#, with: "", options: .regularExpression)
        // import の行は型の参照ではない (モジュールは下の検査が見る)
        let code = withoutHoles.split(separator: "\n").filter { !$0.hasPrefix("import ") }
            .joined(separator: "\n")
        let used = Set(Self.matches(of: #"\b[A-Z][A-Za-z0-9_]*\b"#, in: code))
        #expect(used.contains("Sketch") && used.contains("SketchSettings"), "見つけ方が壊れている: \(used)")
        let missing = used.subtracting(NewCommand.templateTypes)
        #expect(
            missing.isEmpty,
            "ひな形が使う型を NewCommand.templateTypes に足す (作る型の名前と衝突して組めなくなる): \(missing.sorted())")
    }

    /// ひな形が import するモジュールは、同じ名前のパッケージを作ると組めない。
    @Test("ひな形が import するモジュールは、すべて断る一覧に載っている")
    func everyImportedModuleIsListed() throws {
        for name in ["Sketch.swift.template", "Package.swift.template"] {
            let text = try Self.template(name)
            let imported = Set(Self.matches(of: #"(?m)^import (\w+)"#, in: text, group: 1))
            // Package.swift の PackageDescription は、作るパッケージの名前とは別の場所の話
            // (マニフェストのコンパイル) なので、Swift のソースだけを見る
            guard name == "Sketch.swift.template" else { continue }
            #expect(imported == ["Foundation", "mokume"], "ひな形の import が変わった: \(imported)")
            let missing = imported.subtracting(NewCommand.unusableModules)
            #expect(missing.isEmpty, "import するモジュールを NewCommand.unusableModules に足す: \(missing)")
        }
    }

    /// 完了条件 4。**mokume の library product が辿るターゲット名を、宣言から導いて突き合わせる。**
    /// ターゲットを足したとき、一覧に足し忘れると、その名前のスケッチが `conflicting name` で組めない。
    @Test("mokume の product が辿るターゲットは、すべて断る一覧に載っている")
    func everyTargetBehindTheLibraryIsListed() throws {
        let repository = TemplateBuildTests.repository
        // **置き場を別にする。** 既定の `.build` は、この検査を走らせている `swift test` が
        // ロックを持っていて、同じ置き場へ聞くと互いに待って終わらない
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-dump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dump = try RunCommand.swift(
            ["package", "--scratch-path", scratch.path, "dump-package"], in: repository,
            capturing: true, errors: .inherit
        ).output
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any])
        let products = try #require(manifest["products"] as? [[String: Any]])
        let library = try #require(products.first { ($0["name"] as? String) == "mokume" })
        let targets = try #require(manifest["targets"] as? [[String: Any]])
        let dependencies: [String: [String]] = Dictionary(
            uniqueKeysWithValues: targets.map { target in
                let names = (target["dependencies"] as? [[String: Any]] ?? []).compactMap {
                    ($0["target"] as? [Any])?.first as? String
                        ?? ($0["byName"] as? [Any])?.first as? String
                }
                return (target["name"] as! String, names)
            })

        // 製品から辿れるターゲット (自パッケージの中だけ。外のパッケージは product の依存で、辿らない)
        var reached = Set<String>()
        var queue = library["targets"] as? [String] ?? []
        while let next = queue.popLast() {
            guard reached.insert(next).inserted else { continue }
            queue += (dependencies[next] ?? []).filter { dependencies[$0] != nil }
        }
        #expect(reached.contains("mokume") && reached.contains("MokumeCore"), "辿り方が壊れている: \(reached)")
        let missing = reached.subtracting(NewCommand.unusableModules)
        #expect(
            missing.isEmpty,
            "mokume の product が辿るターゲットを NewCommand.unusableModules に足す: \(missing.sorted())")
    }

    // ------------------------------------------------------------ 道具

    private static func template(_ name: String) throws -> String {
        let url = TemplateBuildTests.repository
            .appendingPathComponent("Sources/MokumeCLI/Templates/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func matches(of pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
