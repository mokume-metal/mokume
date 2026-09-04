// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチ一式を作る。
enum NewCommand {
    struct Options: Equatable {
        var name: String
        /// 作る場所 (親ディレクトリ)。
        var path: String = "."
        /// ライブラリをパスで指すときの場所。開発時に使う。
        var local: String?
    }

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let options = try parse(arguments)
        let root = URL(fileURLWithPath: options.path, isDirectory: true)
            .appendingPathComponent(options.name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw .directoryExists(path: root.path)
        }
        for (path, contents) in try files(for: options) {
            let url = root.appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw .cannotCreate(path: url.path, reason: "\(error)")
            }
        }
        print(
            """
            \(root.path) を作った。

              cd \(options.name)
              \(Command.name) run
            """)
    }

    /// 引数を解く。骨格は ``Arguments`` が持ち、ここは宣言だけを書く。
    static func parse(_ arguments: [String]) throws(CommandFailure) -> Options {
        let parsed = try Arguments.parse(
            arguments,
            options: [
                Arguments.Option(["--path"]) { "\($0) のあとに場所が要る" },
                Arguments.Option(["--local"]) { "\($0) のあとにライブラリの場所が要る" },
            ],
            surplus: .reject { "名前は 1 つだけ: \($0)" })
        guard let name = parsed.positional else { throw .nameMissing }
        guard isValid(name: name) else { throw .invalidName(name) }
        return Options(
            name: name, path: parsed.values["--path"] ?? ".", local: parsed.values["--local"])
    }

    /// 作るファイルと中身。
    static func files(for options: Options) throws(CommandFailure) -> [(String, String)] {
        let target = options.name
        let type = typeName(for: options.name)
        let dependency =
            if let local = options.local {
                ".package(path: \"\(local)\")"
            } else {
                """
                .package(
                    url: "https://github.com/mokume-metal/mokume.git",
                    from: "\(Templates.libraryMinimumVersion)")
                """
            }
        let values = [
            "NAME": options.name,
            "TARGET": target,
            "TYPE": type,
            "DEPENDENCY": dependency,
            "PACKAGE": packageIdentity(local: options.local),
        ]
        do {
            return [
                ("Package.swift", try Templates.render("Package.swift.template", values)),
                (
                    "Sources/\(target)/\(type).swift",
                    try Templates.render("Sketch.swift.template", values)
                ),
                (".gitignore", try Templates.render("gitignore.template", values)),
                // 宣言した置き場は実在しなければならない。空のままでも道具立てが
                // 受け付けるよう、読み手への説明を 1 枚置く
                (
                    "Sources/\(target)/assets/README.md",
                    """
                    画像・音・データはこの場所へ置く。

                    `Package.swift` が `resources: [.copy("assets")]` と宣言しているので、
                    ここへ置いたものは実行ファイルの隣へ運ばれ、`loadImage("assets/名前.png")`
                    のように名前で読める。**置き場を変えるなら宣言も変えること。**
                    """
                ),
                // エージェントに道具の使い方を渡す 1 枚。**作品の側の運用は決めない**
                // (ADR-0022 決定 5) — 線は「道具の構造から導かれるか」で引く (#632)
                ("AGENTS.md", try Templates.render("AGENTS.md.template", values)),
                // Claude Code が自動で読むのは CLAUDE.md なので、案内を指す 1 行を置く。
                // **写しは持たない** — 本体もこの形を採っている
                ("CLAUDE.md", try Templates.render("CLAUDE.md.template", values)),
                // 窓口の呼び方。**案内に書くだけでは届かない** — 窓口は呼ぶ側が起動する
                // 前に登録されているものしか使えないので、作った後で打っても、そのとき
                // 動いているエージェントからは呼べない (#683)。置くのは呼び方だけで、
                // 道具の性質は変わらない (窓口は走っているスケッチを起こさない)
                (".mcp.json", try Templates.render("mcp.json.template", values)),
            ]
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw .templatesMissing
        }
    }

    /// 依存を指すときの名前 (package identity)。
    ///
    /// **パスで指すときは末尾のディレクトリ名が identity になる** — リポジトリの
    /// 名前ではない。作業用の複製 (worktree) を指したときに食い違うので、パスから導く。
    static func packageIdentity(local: String?) -> String {
        guard let local else { return "mokume" }
        let name = URL(fileURLWithPath: local, isDirectory: true)
            .standardizedFileURL.lastPathComponent
        return name.isEmpty ? "mokume" : name.lowercased()
    }

    /// 名前として使えるか。パッケージ名にもディレクトリ名にもなるので、両方で
    /// 困らない範囲に絞る。
    static func isValid(name: String) -> Bool {
        guard let first = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// `my-sketch` から `MySketch` を作る。型の名前は識別子でなければならない。
    static func typeName(for name: String) -> String {
        let parts = name.split { $0 == "-" || $0 == "_" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
