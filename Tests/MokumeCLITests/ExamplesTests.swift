// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 同梱した作例を引く口 (#2436)。
///
/// 束は説明文から `scripts/bundle-examples.py` が作る生成物で、検査は**束の形を手で書いた
/// 小さな束**で引き方を見る。説明文から作った本物の束は、最後の suite (``EveryBundledExampleBuildsTests``)
/// が自分で作り、全部の例を `--from` で開いて組む。
enum ExamplesFixture {
    /// 手で書いた束。`rows` は (綴り, 説明, スケッチの本体)。**索引の形は本物と同じ** (3 欄の tsv)。
    static func catalogue(_ rows: [(spelling: String, summary: String, source: String)]) throws
        -> (Examples.Catalogue, URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-examples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var index = ""
        for (number, row) in rows.enumerated() {
            let file = String(format: "%04d.swift.template", number + 1)
            try row.source.write(
                to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
            index += "\(row.spelling)\t\(file)\t\(row.summary)\n"
        }
        try index.write(
            to: directory.appendingPathComponent(Examples.indexName), atomically: true, encoding: .utf8)
        return (try Examples.Catalogue(directory: directory), directory)
    }

    /// 例の本体。`{{TYPE}}` と `{{NAME}}` を持つ。
    static func sketch(_ body: String = "circle(200, 150, 40)") -> String {
        """
        import mokume

        @main
        final class {{TYPE}}: Sketch {
            var settings = SketchSettings(width: 400, height: 300, title: "{{NAME}}")
            func draw() {
                \(body)
            }
        }

        """
    }

    /// 引き方を見る小さな束。`circle` は例が 2 本・`triangle` は 1 本・`fill(_:_:)` は overload が 2 本。
    static func standard() throws -> (Examples.Catalogue, URL) {
        try catalogue([
            ("circle(_:_:_:)#1", "円を塗る。", sketch("circle(200, 150, 40)")),
            ("circle(_:_:_:)#2", "円を塗る。", sketch("circle(100, 100, 20)")),
            ("fill(_:_:)#1", "灰色の下地を置く。", sketch("fill(1, 2)")),
            ("fill(_:_:)#2", "色に透明度を添える。", sketch("fill(3, 4)")),
            ("triangle(_:_:_:_:_:_:)", "三角形を塗る。", sketch("triangle(200, 50, 330, 250, 70, 250)")),
            ("Circle.draw()", "値の円を描く。", sketch("Circle(x: 1, y: 2, diameter: 3).draw()")),
        ])
    }
}

@Suite("同梱した作例を引く")
struct ExamplesTests {
    // MARK: - 綴り

    @Test("綴りから、番号と引数のラベルを除いた見出しと短い名前が取れる")
    func theHeadingAndTheShortNameComeFromTheSpelling() {
        let numbered = Examples.Entry(spelling: "circle(_:_:_:)#2", file: "f", summary: "s")
        #expect(numbered.heading == "circle(_:_:_:)")
        #expect(numbered.shortName == "circle")
        let plain = Examples.Entry(spelling: "triangle(_:_:_:_:_:_:)", file: "f", summary: "s")
        #expect(plain.heading == "triangle(_:_:_:_:_:_:)")
        #expect(plain.shortName == "triangle")
        // 型の口は型の名前を前に付けたまま。値型の口は短い名前でも型を名乗る
        let owned = Examples.Entry(spelling: "Circle.init(center:radius:fill:)", file: "f", summary: "s")
        #expect(owned.shortName == "Circle.init")
        // 型そのもの・値 (引数を持たない口) は、そのまま見出しになる
        let value = Examples.Entry(spelling: "Vector2.x#3", file: "f", summary: "s")
        #expect(value.heading == "Vector2.x")
        #expect(value.shortName == "Vector2.x")
        // 番号に見えるが番号ではない綴り (末尾が数字だけではない) は動かさない
        #expect(Examples.Entry(spelling: "a#b", file: "f", summary: "s").heading == "a#b")
    }

    // MARK: - 引く

    @Test("1 つに決まる短い名前と見出しで、1 本を引ける")
    func aShortNameOrAHeadingFindsTheOnlyExample() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }

        let short = try catalogue.select("triangle")
        #expect(short.spelling == "triangle(_:_:_:_:_:_:)")
        #expect(short.source.contains("triangle(200, 50, 330, 250, 70, 250)"))
        // 見出しの綴りでも、番号を添えずに 1 本に決まる
        #expect(try catalogue.select("triangle(_:_:_:_:_:_:)").spelling == short.spelling)
        // 型の口は、型の名前を含む綴りで引く
        #expect(try catalogue.select("Circle.draw()").spelling == "Circle.draw()")
        #expect(try catalogue.select("Circle.draw").spelling == "Circle.draw()")
    }

    @Test("番号まで書いた綴りは、その 1 本を引く")
    func aNumberedSpellingPicksOne() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }

        let second = try catalogue.select("circle(_:_:_:)#2")
        #expect(second.spelling == "circle(_:_:_:)#2")
        #expect(second.source.contains("circle(100, 100, 20)"))
        let first = try catalogue.select("circle(_:_:_:)#1")
        #expect(first.source.contains("circle(200, 150, 40)"))
    }

    @Test("名前だけでは決まらないときは、候補の綴りを並べて断る")
    func anAmbiguousNameListsTheCandidates() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 例が複数ある口 (短い名前でも見出しでも)
        for spelling in ["circle", "circle(_:_:_:)"] {
            do {
                _ = try catalogue.select(spelling)
                Issue.record("\(spelling) が 1 本に決まってしまった")
            } catch let failure {
                guard case .exampleAmbiguous(let given, let candidates) = failure else {
                    Issue.record("\(spelling): 決まらない名前の断りではない: \(failure)")
                    continue
                }
                #expect(given == spelling)
                #expect(candidates.map(\.spelling) == ["circle(_:_:_:)#1", "circle(_:_:_:)#2"])
            }
        }
        // overload が複数ある口 (引数のラベルまで書いても、同じ綴りを名乗る)
        do {
            _ = try catalogue.select("fill(_:_:)")
            Issue.record("overload が複数あるのに 1 本に決まった")
        } catch let failure {
            guard case .exampleAmbiguous(_, let candidates) = failure else {
                Issue.record("決まらない名前の断りではない: \(failure)")
                return
            }
            #expect(candidates.map(\.spelling) == ["fill(_:_:)#1", "fill(_:_:)#2"])
        }
    }

    @Test("知らない名前は、一覧を案内して断る")
    func anUnknownNameIsRefusedWithAPointerToTheList() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }

        for spelling in ["nope", "", "circle(_:_:_:)#3", "triang"] {
            do {
                _ = try catalogue.select(spelling)
                Issue.record("\(spelling.debugDescription) が引けてしまった")
            } catch let failure {
                #expect(failure == .exampleUnknown(spelling: spelling))
                #expect(failure.message.contains("\(Command.name) examples"), "一覧を案内していない")
            }
        }
    }

    @Test("索引にあるファイルが読めなければ、読めないと断る")
    func anUnreadableExampleIsRefused() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("0005.swift.template"))

        do {
            _ = try catalogue.select("triangle")
            Issue.record("読めないファイルを引けてしまった")
        } catch let failure {
            #expect(failure == .exampleUnreadable(spelling: "triangle(_:_:_:_:_:_:)"))
        }
    }

    // MARK: - 束

    @Test("索引が無い・空の置き場は、束が無いと断る")
    func aMissingBundleIsRefused() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-examples-none-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        // 束を作る前の置き場 (README の 1 枚だけが在る)
        try "placeholder".write(
            to: empty.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        #expect(throws: CommandFailure.examplesMissing) { try Examples.Catalogue(directory: empty) }
        // 索引はあっても、中身が 1 行も読めなければ束が無いのと同じ
        try "no tabs here\n".write(
            to: empty.appendingPathComponent(Examples.indexName), atomically: true, encoding: .utf8)
        #expect(throws: CommandFailure.examplesMissing) { try Examples.Catalogue(directory: empty) }
    }

    @Test("索引の読み方は、3 欄の行だけを拾う")
    func theIndexKeepsOnlyWellFormedRows() {
        let rows = Examples.Catalogue.parse("a\tf1\t説明 a\nbroken line\nb\tf2\t説明 b\n\n")
        #expect(rows.map(\.spelling) == ["a", "b"])
        #expect(rows.map(\.file) == ["f1", "f2"])
        #expect(rows.last?.summary == "説明 b")
    }

    @Test("同梱した束が、道具の資源に載っている")
    func theBundleDirectoryIsDeclared() {
        // 束を作っていない手元でも置き場は在る (README の 1 枚)。束が在れば索引も読める。
        // **どちらの状態でも、資源の宣言が欠けていないことを見る**
        let url = Bundle.module.url(forResource: Examples.directoryName, withExtension: nil)
        #expect(url != nil, "Package.swift が Examples を資源として宣言していない")
    }

    // MARK: - 一覧

    @Test("一覧は、綴りと説明の 2 欄を揃えて並べ、引き方を添える")
    func theListingAlignsSpellingAndSummary() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }

        let listing = catalogue.listing(toolVersion: "1.2.3 (Homebrew)")
        let lines = listing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "6 examples from the reference this tool was built with (1.2.3 (Homebrew)).")
        #expect(listing.contains("new <name> --from <example>"))
        #expect(listing.contains("--from 'fill(_:_:)#2'"), "引用符の案内が無い")

        // 行は説明の欄の頭が揃う。**綴りの長さが違っても**
        let rows = lines.suffix(6)
        let columns = Set(
            rows.compactMap { row in
                catalogue.entries.first(where: { row.hasPrefix($0.spelling) }).map {
                    row.distance(from: row.startIndex, to: row.range(of: $0.summary)!.lowerBound)
                }
            })
        #expect(columns.count == 1, "説明の欄が揃っていない: \(rows)")
        for entry in catalogue.entries {
            #expect(rows.contains { $0.hasPrefix(entry.spelling) && $0.hasSuffix(entry.summary) })
        }
    }

    @Test("決まらなかった名前の断りは、候補・上限・貼れる 1 行を持つ")
    func theAmbiguityTextIsActionable() {
        let candidates = (1...25).map {
            Examples.Entry(spelling: "begin(_:)#\($0)", file: "f", summary: "始める。")
        }
        let text = Examples.ambiguousText(spelling: "begin", candidates: candidates)
        #expect(text.hasPrefix("More than one example answers to begin:"))
        #expect(text.contains("begin(_:)#20"))
        #expect(!text.contains("begin(_:)#21"), "上限を越えた候補まで並んでいる")
        #expect(text.contains("5 more"))
        #expect(text.contains("--from 'begin(_:)#1'"), "そのまま貼れる 1 行が無い")
    }

    @Test("口は引数を取らない")
    func theVerbTakesNoArguments() {
        #expect(throws: CommandFailure.self) { try ExamplesCommand.run(["circle"]) }
    }

    // MARK: - 例が使う型の名前

    @Test("例が書いている語だけを、識別子として見つける")
    func mentionsFindsWholeIdentifiersOnly() {
        let chosen = Examples.Chosen(
            spelling: "x",
            source: ExamplesFixture.sketch("let c = Circle(x: 1, y: 2, diameter: 3)\n        circle(200, 150, 40)"))
        #expect(chosen.mentions("Circle"))
        // 部分一致は拾わない (`Circle2`・`MyCircle`)。小文字の関数 `circle` は別の語
        #expect(!chosen.mentions("Circl"))
        #expect(!chosen.mentions("Rect"))
        // 作るクラスの名前の差し込み口 (`{{TYPE}}`) は、例が書いた語ではない
        #expect(!chosen.mentions("TYPE"))
    }
}

// MARK: - new --from

@Suite("new --from は、例を 1 本のスケッチにする")
struct NewFromExampleTests {
    @Test("--from の値は、引き方として解かれる")
    func theOptionIsParsed() throws {
        let options = try NewCommand.parse(["my-shape", "--from", "triangle"])
        #expect(options.from == "triangle")
        #expect(options.name == "my-shape")
        #expect(try NewCommand.parse(["my-shape"]).from == nil)
        // 値が無い
        #expect(throws: CommandFailure.usage("--from needs an example after it (\(Command.name) examples lists them)")) {
            try NewCommand.parse(["my-shape", "--from"])
        }
    }

    @Test("例の入ったスケッチは、ひな形のスケッチの本体だけが例に替わる")
    func onlyTheSketchFileIsReplaced() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = NewCommand.Options(name: "my-shape", path: ".", local: "/lib/mokume", from: "triangle")

        let plain = try NewCommand.files(for: options)
        let withExample = try NewCommand.files(for: options, example: try catalogue.select("triangle"))

        #expect(plain.map(\.0) == withExample.map(\.0), "作るファイルの並びが変わった")
        let sketchPath = "Sources/my-shape/MyShape.swift"
        for (path, contents) in withExample {
            let before = try #require(plain.first { $0.0 == path }).1
            if path == sketchPath {
                #expect(contents != before)
            } else {
                #expect(contents == before, "\(path) まで変わった")
            }
        }
        let sketch = try #require(withExample.first { $0.0 == sketchPath }).1
        #expect(sketch.contains("@main\nfinal class MyShape: Sketch {"))
        #expect(sketch.contains(#"title: "my-shape""#), "窓の題に名前が入っていない")
        #expect(sketch.contains("triangle(200, 50, 330, 250, 70, 250)"))
        #expect(!sketch.contains("{{"), "差し込みが残っている")
    }

    @Test("例が使う型と同じ名前のクラスになる名前は、何も作る前に断る")
    func aNameThatHidesATypeTheExampleUsesIsRefused() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `Circle.draw()` の例は型 `Circle` を使う。クラス `Circle` になる名前は、その型を隠す
        let chosen = try catalogue.select("Circle.draw()")
        let options = NewCommand.Options(name: "circle", path: ".", from: "Circle.draw()")

        do {
            _ = try NewCommand.files(for: options, example: chosen)
            Issue.record("型を隠す名前が通った")
        } catch let failure {
            guard case .unusableName(let name, let reason) = failure else {
                Issue.record("名前の断りではない: \(failure)")
                return
            }
            #expect(name == "circle")
            #expect(reason.contains("Circle"))
        }
        // 別の名前なら通る
        #expect(throws: Never.self) {
            _ = try NewCommand.files(
                for: NewCommand.Options(name: "my-circle", path: ".", from: "Circle.draw()"),
                example: chosen)
        }
    }

    // MARK: - 実際に書く

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-new-from-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("例からスケッチ一式ができ、@main を持つ 1 本が置かれる")
    func runWritesThePackage() throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        let place = try workspace()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: place)
        }

        try NewCommand.run(
            ["my-shape", "--from", "triangle", "--path", place.path], examples: { catalogue })

        let sketch = try String(
            contentsOf: place.appendingPathComponent("my-shape/Sources/my-shape/MyShape.swift"),
            encoding: .utf8)
        #expect(sketch.contains("@main"))
        #expect(sketch.contains("triangle(200, 50, 330, 250, 70, 250)"))
        for file in ["Package.swift", ".gitignore", "AGENTS.md", ".mcp.json", "Sources/my-shape/assets/README.md"] {
            #expect(
                FileManager.default.fileExists(
                    atPath: place.appendingPathComponent("my-shape/\(file)").path), "\(file) が無い")
        }
    }

    /// **部分的なパッケージを残さない** (#2436 の完了条件 3)。どの断りでも、作る場所には何も
    /// 現れない。
    @Test(
        "知らない名前・決まらない名前・束が無いときは、何も作らずに断る",
        arguments: ["nope", "circle", "fill(_:_:)", ""])
    func aRefusalLeavesNothingBehind(spelling: String) throws {
        let (catalogue, directory) = try ExamplesFixture.standard()
        let place = try workspace()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: place)
        }

        #expect(throws: CommandFailure.self) {
            try NewCommand.run(
                ["my-shape", "--from", spelling, "--path", place.path], examples: { catalogue })
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: place.path)
        #expect(left.isEmpty, "断ったのに残っている: \(left)")
    }

    @Test("束が無い道具は、束が無いと断り、何も作らない")
    func noBundleLeavesNothingBehind() throws {
        let place = try workspace()
        defer { try? FileManager.default.removeItem(at: place) }

        #expect(throws: CommandFailure.examplesMissing) {
            try NewCommand.run(
                ["my-shape", "--from", "triangle", "--path", place.path],
                examples: { () throws(CommandFailure) in throw CommandFailure.examplesMissing })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.path).isEmpty)
    }

    @Test("--from を付けないときは、ひな形の回る円のまま")
    func withoutFromTheTemplateIsUnchanged() throws {
        let place = try workspace()
        defer { try? FileManager.default.removeItem(at: place) }

        // 束を引く手は呼ばれない (束が無い道具でも、ひな形は作れる)
        try NewCommand.run(
            ["plain", "--path", place.path],
            examples: { () throws(CommandFailure) in throw CommandFailure.examplesMissing })
        let sketch = try String(
            contentsOf: place.appendingPathComponent("plain/Sources/plain/Plain.swift"), encoding: .utf8)
        #expect(sketch.contains("let angle = time * 0.8"))
    }
}

// MARK: - 説明文から作った束

/// **説明文から作った本物の束を、全部 `--from` で開いて、組めることを見る** (#2436 の完了条件 5)。
///
/// 組むだけで走らせない (GPU は要らない)。束は検査が自分で作る — `make cli-examples` を打って
/// いるかに依らない。全部を 1 本ずつ別のパッケージにすると終わらないので、**`--from` が書いた
/// スケッチを、1 つのパッケージの 1 つのモジュールに並べて 1 度で組む**。そのモジュールは
/// 例ごとに `@main` を持てないので、並べるときに `@main` の行だけを外す。外す前に、全部の
/// 例が `@main` を持つことを見る。
@Suite("同梱した全部の例が、--from で作ったとおりに組める")
struct EveryBundledExampleBuildsTests {
    static var repository: URL { TemplateBuildTests.repository }

    /// 束を作る。`scripts/bundle-examples.py` を、作業ツリーの説明文に対して走らせる。
    static func makeBundle(into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "scripts/bundle-examples.py", "--out", directory.path]
        process.currentDirectoryURL = repository
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let result = try BuildProcess.run(process, reading: pipe, within: 300)
        #expect(result.killed == false, "束を作るのが終わらない")
        #expect(result.status == 0, "束を作れない:\n\(result.output)")
    }

    @Test("全部の例を --from で作り、1 つのモジュールに並べて組む")
    func everyExampleBuilds() throws {
        let bundle = SharedDebugScratch.sketches.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.makeBundle(into: bundle)
        let catalogue = try Examples.Catalogue(directory: bundle)
        // **空の束で緑にならない。** 例が極端に減ったときも赤にする
        #expect(catalogue.entries.count >= 100, "同梱した例が \(catalogue.entries.count) 本しかない")
        #expect(Set(catalogue.entries.map(\.spelling)).count == catalogue.entries.count, "綴りが重なっている")

        let root = SharedDebugScratch.sketches.appendingPathComponent("every-example", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/every", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (number, entry) in catalogue.entries.enumerated() {
            // **名前は `--from` と同じ経路で通す** — 例が使う型と衝突しない名前を付ける
            let name = "ex\(number)"
            let options = NewCommand.Options(
                name: name, path: root.path, local: Self.repository.path, from: entry.spelling)
            let files = try NewCommand.files(
                for: options, example: try catalogue.select(entry.spelling))
            let sketch = try #require(files.first { $0.0 == "Sources/\(name)/\(NewCommand.typeName(for: name)).swift" })
            let lines = sketch.1.components(separatedBy: "\n")
            #expect(lines.contains("@main"), "\(entry.spelling) が @main を持たない")
            let text = lines.filter { $0 != "@main" }.joined(separator: "\n")
            try text.write(
                to: sources.appendingPathComponent("\(NewCommand.typeName(for: name)).swift"),
                atomically: true, encoding: .utf8)
        }

        let identity = NewCommand.packageIdentity(local: Self.repository.path, sketch: root)
        try """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "every",
            platforms: [.macOS("26.0")],
            dependencies: [.package(path: "\(NewCommand.swiftStringContents(Self.repository.path))")],
            targets: [
                .target(
                    name: "every",
                    dependencies: [.product(name: "mokume", package: "\(NewCommand.swiftStringContents(identity))")],
                    swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)])
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let built = try BuildProcess.build(in: root, scratchPath: SharedDebugScratch.place)
        #expect(built.killed == false, "組み上げが終わらないまま期限に達した")
        #expect(built.status == 0, "同梱した例が組めない:\n\(built.output)")
    }

    @Test("説明文の例 triangle が、名前だけで引ける")
    func theExampleFromTheIssueIsThere() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Self.makeBundle(into: bundle)
        let catalogue = try Examples.Catalogue(directory: bundle)

        #expect(try catalogue.select("triangle").spelling == "triangle(_:_:_:_:_:_:)")
        // 例が複数ある口は、短い名前では決まらない
        #expect(throws: CommandFailure.self) { try catalogue.select("circle") }
        #expect(throws: CommandFailure.self) { try catalogue.select("arc") }
        #expect(try catalogue.select("arc(_:_:_:_:_:_:)#4").spelling == "arc(_:_:_:_:_:_:)#4")
        #expect(throws: CommandFailure.self) { try catalogue.select("nope") }
        // 資材を読む例は一覧に出ない (写せる実体が無い・束の作り方の注記)
        for entry in catalogue.entries {
            let text = try String(
                contentsOf: bundle.appendingPathComponent(entry.file), encoding: .utf8)
            #expect(!text.contains("\"assets/") && !text.contains("\"data/"), "\(entry.spelling) が資材を読む")
        }
    }
}
