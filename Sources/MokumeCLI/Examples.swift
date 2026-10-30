// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 道具に同梱した作例 (#2436)。`mokume examples` が並べ、`mokume new <名前> --from <例>` が開く。
///
/// ## 例はどこから来るか
///
/// **説明文 (`///`) の中の例である。** 手で書く例の置き場を増やさない (ADR-0027 決定 6)。
/// 束は `scripts/bundle-examples.py` が説明文から作り、`Examples/` として道具の資源 (実行ファイルの
/// 隣の `mokume_MokumeCLI.bundle`) に入る。**作った束をリポジトリにコミットしない**ので、束ねるのは
/// 版を作る段 (`make cli-dist`) で、入れた版の口と例はずれない。ネットワークは使わない。
///
/// 束の形は `index.tsv` (`綴り<TAB>ファイル名<TAB>1 行の説明`) と、`@main` を持つスケッチ 1 本ずつ
/// (`{{TYPE}}` と `{{NAME}}` を `new` が差し込む)。
///
/// ## 引き方
///
/// 綴りは**参照の面の見出しと同じ** (`fill(_:_:_:_:)`・`Circle.draw()`)。同じ綴りに例が複数ある口は、
/// 束を作るときに `#1`・`#2` と番号を添える。**引数のラベルを省いた短い名前** (`triangle`) でも、
/// 1 本に決まるなら引ける。決まらない名前は候補の綴りを並べて断り、知らない名前は一覧を案内して
/// 断る — どちらも**何も作る前に**断る。
nonisolated enum Examples {
    /// 束の中の 1 本。
    nonisolated struct Entry: Equatable {
        /// 引き方。番号を添えた後の綴り。
        let spelling: String
        /// 束の中のファイル名。
        let file: String
        /// 説明文の最初の 1 文。
        let summary: String

        /// 番号を除いた綴り (参照の面の見出しと同じ)。
        var heading: String {
            guard let hash = spelling.range(of: #"#[0-9]+$"#, options: .regularExpression) else {
                return spelling
            }
            return String(spelling[..<hash.lowerBound])
        }

        /// 引数のラベルを省いた短い名前。
        var shortName: String {
            heading.firstIndex(of: "(").map { String(heading[..<$0]) } ?? heading
        }
    }

    /// 引いた例。
    nonisolated struct Chosen: Equatable {
        let spelling: String
        /// `{{TYPE}}` と `{{NAME}}` を持つスケッチ。
        let source: String

        /// 例が名前として書いている語 (識別子としての出現)。**作るクラスの名前と同じだと、例が
        /// 使いたい型を隠して組めなくなる** (`new circle --from circle` で `Circle` が自分自身になる)。
        func mentions(_ identifier: String) -> Bool {
            let body = source.replacingOccurrences(of: "{{TYPE}}", with: "")
            let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: identifier)
                + "(?![A-Za-z0-9_])"
            return body.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// 束の置き場の名前 (``Templates`` と同じく、道具の資源の中)。
    static let directoryName = "Examples"
    static let indexName = "index.tsv"

    /// 候補を並べる上限。越えた分は件数で言う (一覧が全部を持つ)。
    static let candidateLimit = 20

    /// 同梱した束。**束が無ければ断る** — 手元の組み立てで束を作っていない・片方だけ入れた、のどちらか。
    static func bundled() throws(CommandFailure) -> Catalogue {
        guard let url = Bundle.module.url(forResource: directoryName, withExtension: nil) else {
            throw CommandFailure.examplesMissing
        }
        return try Catalogue(directory: url)
    }

    /// 束を読んだもの。
    nonisolated struct Catalogue {
        let directory: URL
        let entries: [Entry]

        /// 束を読む。**索引が無ければ束が無い** (置き場はあっても、束を作る前の手元の組み立て)。
        init(directory: URL) throws(CommandFailure) {
            let index = directory.appendingPathComponent(Examples.indexName)
            guard let text = try? String(contentsOf: index, encoding: .utf8) else {
                throw CommandFailure.examplesMissing
            }
            self.directory = directory
            self.entries = Self.parse(text)
            guard !entries.isEmpty else { throw CommandFailure.examplesMissing }
        }

        /// 索引を読む。欄の足りない行は落とす — 束を作る道具 (`scripts/bundle-examples.py`) は 3 欄の
        /// 行しか書かない。
        static func parse(_ text: String) -> [Entry] {
            text.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { return nil }
                return Entry(
                    spelling: String(fields[0]), file: String(fields[1]), summary: String(fields[2]))
            }
        }

        /// 綴りで 1 本を引く。**1 本に決まらなければ断る。**
        ///
        /// 引き方は 2 段である。番号まで書いた綴りがそのまま在ればそれ。無ければ、番号を除いた綴り
        /// (`circle(_:_:_:)`) か短い名前 (`circle`) が名乗る例の全部を候補にする。
        func select(_ spelling: String) throws(CommandFailure) -> Chosen {
            let exact = entries.filter { $0.spelling == spelling }
            let found =
                exact.isEmpty
                ? entries.filter { $0.heading == spelling || $0.shortName == spelling } : exact
            guard let first = found.first else { throw CommandFailure.exampleUnknown(spelling: spelling) }
            guard found.count == 1 else {
                throw CommandFailure.exampleAmbiguous(spelling: spelling, candidates: found)
            }
            let url = directory.appendingPathComponent(first.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw CommandFailure.exampleUnreadable(spelling: first.spelling)
            }
            return Chosen(spelling: first.spelling, source: source)
        }

        /// `mokume examples` が印字する文。**行は綴りと説明の 2 欄**で、`grep` で絞れる。
        func listing(toolVersion: String) -> String {
            let width = entries.map(\.spelling.count).max() ?? 0
            var lines = [
                "\(entries.count) examples from the reference this tool was built with (\(toolVersion)).",
                "Start a sketch from one:",
                "",
                "  \(Command.name) new <name> --from <example>",
                "",
                "A name with parentheses or # needs quotes in the shell (--from 'fill(_:_:)#2'). "
                    + "A shorter name works when only one example answers to it (--from triangle).",
                "",
            ]
            for entry in entries {
                let padding = String(repeating: " ", count: width - entry.spelling.count)
                lines.append("\(entry.spelling)\(padding)  \(entry.summary)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// 決まらなかった名前を断る文。候補の綴りと、そのまま貼れる 1 行を添える。
    static func ambiguousText(spelling: String, candidates: [Entry]) -> String {
        let shown = candidates.prefix(candidateLimit)
        let width = shown.map(\.spelling.count).max() ?? 0
        var lines = ["More than one example answers to \(GivenPath.shellWord(display: spelling)):"]
        for entry in shown {
            lines.append(
                "  \(entry.spelling)\(String(repeating: " ", count: width - entry.spelling.count))  \(entry.summary)"
            )
        }
        if candidates.count > shown.count {
            lines.append(
                "  … and \(candidates.count - shown.count) more (\(Command.name) examples lists them all)")
        }
        let pick = candidates[0].spelling
        lines.append("Pick one by its whole spelling (quoted, as it has parentheses):")
        lines.append("  \(Command.name) new <name> --from \(GivenPath.shellWord(display: pick))")
        return lines.joined(separator: "\n")
    }
}

/// `mokume examples`。
enum ExamplesCommand {
    static func run(_ arguments: [String]) throws(CommandFailure) {
        if arguments.contains(where: { Arguments.helpSpellings.contains($0) }) { throw .helpRequested }
        // 位置引数も選択肢も取らない。**黙って捨てると、絞り込みを期待した人が全件を読まされる**
        if let extra = arguments.first {
            throw .usage(
                "\(Command.name) examples takes no arguments (got \(GivenPath.shellWord(display: extra))). "
                    + "It lists every example; pipe it through grep to narrow it down")
        }
        print(try Examples.bundled().listing(toolVersion: ToolVersion.describe()))
    }
}
