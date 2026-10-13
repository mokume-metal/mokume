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
        ///
        /// **相対なら、作られるスケッチから見た相対である** (CONTRIBUTING)。`Package.swift` の
        /// `.package(path:)` へそのまま入り、SwiftPM はそれをパッケージの場所から解く。
        var local: String?

        /// 作るスケッチの場所。`--path` を走らせた場所から解き、名前を足す (#2323)。
        ///
        /// - Parameter base: 走らせた場所。検査から渡せる形にしてある。
        func root(from base: URL = GivenPath.currentDirectory) -> URL {
            GivenPath.resolve(path, from: base).appendingPathComponent(name, isDirectory: true)
        }
    }

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let options = try parse(arguments)
        let root = options.root()
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
        print(guidance(for: root))
    }

    /// 作った後に言うこと。
    ///
    /// **案内は、走らせた場所からそのまま貼って動く形にする** (#2320)。`cd <名前>` では
    /// `--path` を付けたときに入れず、空白を含む場所なら引用も要った。作った場所を絶対
    /// パスで名指しし、シェルの 1 語に包む (``GivenPath/shellWord(_:)``)。
    static func guidance(for root: URL) -> String {
        """
        Created \(root.path)

          cd \(GivenPath.shellWord(root))
          \(Command.name) run
        """
    }

    /// 引数を解く。骨格は ``Arguments`` が持ち、ここは宣言だけを書く。
    static func parse(_ arguments: [String]) throws(CommandFailure) -> Options {
        let parsed = try Arguments.parse(
            arguments,
            options: [
                Arguments.Option(["--path"]) { "\($0) needs a directory after it" },
                Arguments.Option(["--local"]) { "\($0) needs the library's path after it" },
            ],
            surplus: .reject { "Only one name: \($0)" })
        guard let name = parsed.positional else { throw .nameMissing }
        guard isValid(name: name) else { throw .invalidName(name) }
        return Options(
            name: name, path: parsed.values["--path"] ?? ".", local: parsed.values["--local"])
    }

    /// 作るファイルと中身。
    ///
    /// - Parameter base: 走らせた場所。`--local` の名前を作る場所から解くのに要る。
    static func files(for options: Options, base: URL = GivenPath.currentDirectory)
        throws(CommandFailure) -> [(String, String)]
    {
        let target = options.name
        let type = typeName(for: options.name)
        // **`--local` から来る値は Swift の文字列として逃がす** (#2322)。生のまま貼ると、
        // `"` を含む場所で Package.swift が読めなくなる。名前 (`NAME`・`TARGET`) は
        // ``isValid(name:)`` が `"` を通さないので逃がす必要が無い
        let dependency =
            if let local = options.local {
                ".package(path: \"\(swiftStringContents(local))\")"
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
            "PACKAGE": swiftStringContents(
                packageIdentity(local: options.local, sketch: options.root(from: base))),
        ]
        return [
            ("Package.swift", try Templates.render("Package.swift.template", values)),
            (
                "Sources/\(target)/\(type).swift",
                try Templates.render("Sketch.swift.template", values)
            ),
            (".gitignore", try Templates.render("gitignore.template", values)),
            // 宣言した置き場は実在しなければならない。空のままでも道具立てが
            // 受け付けるよう、読み手への説明を 1 枚置く
            // **中身は読み物なので日本語で、`Templates/` のファイルに置く** — Swift の中に
            // 書くと、道具が話す言葉の検査 (`scripts/check-tool-language.py`) に掛かる
            (
                "Sources/\(target)/assets/README.md",
                try Templates.render("assets-README.md.template", values)
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
    }

    /// 依存を指すときの名前 (package identity)。
    ///
    /// **パスで指すときは末尾のディレクトリ名が identity になる** — リポジトリの
    /// 名前ではない。作業用の複製 (worktree) を指したときに食い違うので、パスから導く。
    ///
    /// **`.package(path:)` と同じ基準で解く** (#2322)。`--local` は `.package(path:)` へ
    /// そのまま入り、SwiftPM はそれを**作られるスケッチの場所から**解く (CONTRIBUTING の
    /// 「作られるスケッチから見た相対」)。名前だけを走らせた場所から解いていたので、末尾が
    /// `..`・`.` の場所では 2 つが別の場所を指し、`swift package resolve` が
    /// `unknown package` で止まっていた。
    ///
    /// **SwiftPM と同じ規則で解く** (#2323 の反証):
    ///
    /// - スケッチの場所は**実体** (symlink を解いたもの) — SwiftPM はパッケージの場所を
    ///   作業ディレクトリ (`getcwd`) から持つ。字面のまま `..` を畳むと、symlink を通って
    ///   作ったスケッチでは別のディレクトリの名前になる。まだ無い末尾 (作るスケッチ) は、
    ///   在る祖先を解いた後に足す
    /// - `..` と `.` は、そこから**字面で**畳む (SwiftPM の `AbsolutePath` と同じ)
    /// - `~/` で始まる場所だけは home から解く
    /// - 名前の末尾の `.git` は落とす
    ///
    /// - Parameter sketch: 作られるスケッチの場所 (``Options/root(from:)``)。
    static func packageIdentity(local: String?, sketch: URL) -> String {
        guard let local else { return "mokume" }
        let (base, relative) =
            local.hasPrefix("~/")
            ? (NSHomeDirectory(), String(local.dropFirst(2))) : (onDisk(sketch).path, local)
        var parts = relative.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        var name = parts.last ?? ""
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? "mokume" : name.lowercased()
    }

    /// 場所の実体 (symlink を解いた絶対パス)。**まだ無い末尾は、在る祖先を解いた後に足す。**
    ///
    /// `realpath(3)` で解く — `resolvingSymlinksInPath()` は先頭の `/private` を落とすので、
    /// SwiftPM が持つ場所 (`getcwd` は `/private/tmp/…` を返す) と綴りが変わる。
    static func onDisk(_ place: URL) -> URL {
        var existing = place.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return place }
        defer { free(resolved) }
        return missing.reduce(URL(fileURLWithPath: String(cString: resolved), isDirectory: true)) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }

    /// Swift の文字列リテラル (`"…"`) の中身として書ける形にする。
    ///
    /// `\` と `"` を逃がし、改行などの制御文字は `\u{…}` にする — 生のまま入ると、
    /// 文字列が閉じるか、行をまたいで読めなくなる。
    static func swiftStringContents(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                escaped += "\\u{\(String(scalar.value, radix: 16))}"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
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
