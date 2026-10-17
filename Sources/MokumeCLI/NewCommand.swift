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
                Arguments.Option(["--path"], takesPlace: true) { "\($0) needs a directory after it" },
                Arguments.Option(["--local"], takesPlace: true) { "\($0) needs the library's path after it" },
            ],
            surplus: .reject { "Only one name: \($0)" })
        guard let name = parsed.positional else { throw .nameMissing }
        guard isValid(name: name) else { throw .invalidName(name) }
        if let reason = unusableReason(name: name) { throw .unusableName(name: name, reason: reason) }
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
        let identity = packageIdentity(local: options.local, sketch: options.root(from: base))
        // **作るパッケージの名前と、依存の名前が同じだと組めない** — 作るディレクトリの名前が
        // identity になるので、同じ名前で終わる場所を指すと、自分自身に依存する形になる (#2310)
        if options.name.lowercased() == identity {
            throw .unusableName(
                name: options.name,
                reason: "The package would have the same name as the one it depends on (\(identity)).")
        }
        let values = [
            "NAME": options.name,
            "TARGET": target,
            "TYPE": type,
            "DEPENDENCY": dependency,
            "PACKAGE": swiftStringContents(identity),
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
        guard let local else { return libraryPackageName }
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
        return name.isEmpty ? libraryPackageName : name.lowercased()
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

    /// 依存する mokume のパッケージの名前 (url で指すときの identity)。
    static let libraryPackageName = "mokume"

    /// 作るパッケージが (推移で) 依存するパッケージの identity。**作るディレクトリの名前が identity に
    /// なるので、同じ名前 (大小は問わない) だと組めない** (`new swift-syntax` は
    /// `product 'SwiftSyntaxMacros' … not found in package 'swift-syntax'`)。検査が `Package.swift` の
    /// 依存の宣言から導いて突き合わせる。
    static let dependencyPackageNames: Set<String> = [libraryPackageName, "swift-syntax"]

    /// ひな形 `Sketch.swift` が mokume から使う型。**作る型の名前がこれと同じだと組めない**
    /// (`'Sketch' inherits from itself`・使いたい型を隠す)。ひな形に型の参照を足したら、ここへ
    /// 足す (検査が突き合わせる)。
    static let templateTypes: Set<String> = ["Sketch", "SketchSettings"]

    /// 型の名前にできない綴り (`keyword 'Self' cannot be used as an identifier here`)。
    /// **大文字で始まる Swift のキーワードは `Self` と `Any` だけ** (言語仕様) なので、型名
    /// (`typeName(for:)` は各部分の先頭を大文字にする) で衝突しうるのはこの 2 つで足りる。
    /// `Type`・`Protocol`・`Never`・`Error`・`Main` は型の名前にできた (`swift build` で実測)。
    /// 小文字のキーワード (`init`・`func`・`default`・`import`・`let`・`struct`) はモジュール名にも
    /// 型名 (先頭が大文字になる) にもでき、組めた (実測)。
    static let keywordTypes: Set<String> = ["Self", "Any"]

    /// 作るパッケージの名前 (= ターゲットの名前) にできないモジュール。
    ///
    /// **同じ名前のモジュールが、作るパッケージの依存の中に在る。** 依存のターゲットとは
    /// `multiple packages … declare targets with a conflicting name`、SDK のモジュールとは
    /// `module dependency cycle` で組めない。`swift build` で名前ごとに確かめた (2026-10-13・
    /// Swift 6.3・macOS 26)。
    ///
    /// - mokume の library product が辿るターゲット (検査が `Package.swift` の宣言から導いて
    ///   突き合わせる)
    /// - **mokume のライブラリのソースが `import` するモジュール** — SDK のもの (`Foundation`・
    ///   `Metal`・`Network`・`Observation`・`SwiftUI` など) と swift-syntax のもの (`SwiftSyntax`・
    ///   `SwiftCompilerPlugin` など)。検査が `Sources/` の `import` から導いて突き合わせるので、
    ///   一覧を手で足さなくても、ライブラリが新しいモジュールを import したら赤になって知らせる
    /// - ひな形が import するモジュール (`Foundation`・`mokume`)・標準ライブラリ (`Swift` は
    ///   `module name "Swift" is reserved for the standard library`)
    ///
    /// **限界: 導ける範囲に限る。** swift-syntax のターゲットのうち mokume が import しないもの
    /// (`SwiftParser` など) と、mokume が import しない SDK のモジュールも同じ形で組めなくなるが
    /// (swift-syntax 側は実測)、導けないので一覧に無い。一覧は CLI と同じ版の宣言から導いたもので、
    /// 生成物が引く最新のライブラリが足したターゲットとは食い違いうる。
    ///
    /// **大小は区別する。** `mokumecore` は組めた (実測)。区別しない名前は
    /// ``caseFoldedModules`` で別にする。
    static let unusableModules: Set<String> = [
        // mokume の library product が辿るターゲット
        "mokume", "MokumeCore", "MokumeCamera", "MokumeAudio", "MokumeNetwork",
        "MokumeDiagnostics", "MokumeMacros",
        // ひな形が import するモジュールと標準ライブラリ
        "Foundation", "Swift",
        // ライブラリのソースが import する SDK のモジュール
        "simd", "Metal", "Synchronization", "AppKit", "Darwin", "QuartzCore", "CoreGraphics",
        "AVFAudio", "Observation", "SwiftUI", "Accelerate", "AVFoundation", "Network", "CoreText",
        "ImageIO", "IOSurface", "CoreMedia", "CoreAudio", "VideoToolbox", "UniformTypeIdentifiers",
        "ModelIO", "IOKit", "CoreVideo",
        // ライブラリのソースが import する swift-syntax のモジュール
        "SwiftSyntax", "SwiftSyntaxMacros", "SwiftCompilerPlugin", "SwiftDiagnostics",
    ]

    /// 大小を畳んで断るモジュール (小文字・大文字の綴り違いでも組めないもの)。
    ///
    /// **ひな形が `import` するモジュールだけ** (`Foundation`・`mokume`)。作るターゲットの
    /// 出力 (`<名前>.swiftmodule`) は大小を区別しない置き場の同じファイルになり、ひな形の
    /// `import Foundation` が自分自身の出力を読む (`foundation` は 4 回とも `swiftc` の失敗)。
    /// 小文字の `metal`・`appkit`・`network`・`swift`・`mokumecore` などは組めた (実測) ので畳まない。
    /// `mokume` は ``dependencyPackageNames`` の大小違いとして別に断る。
    static let caseFoldedModules: Set<String> = ["foundation"]

    /// ひな形が `Sketch.swift` で import するモジュール。
    static let templateModules: Set<String> = ["Foundation", "mokume"]

    /// 名前として使えるか。パッケージ名にもディレクトリ名にもなるので、両方で
    /// 困らない範囲に絞る。
    static func isValid(name: String) -> Bool {
        guard let first = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// 名前が、組めないパッケージを作るなら、その理由 (英語の 1 文)。組めるなら `nil`。
    ///
    /// **文字の種類は見ない** (``isValid(name:)``)。ここは文字としては使える名前のうち、型の名前・
    /// ターゲットの名前が mokume や Swift の名前と衝突するものを断る
    /// ([#2310](https://github.com/mokume-metal/mokume/issues/2310))。実際に `swift build` で
    /// 確かめた結果が土台で、`new` が `Created` と言ったものは組める、を守る。
    ///
    /// 依存の名前 (`--local` の末尾) との衝突は、場所を解いてからでないと分からないので
    /// ``files(for:base:)`` が見る。
    static func unusableReason(name: String) -> String? {
        let type = typeName(for: name)
        if templateTypes.contains(type) {
            return "The sketch's class would be called \(type), the same as a type in mokume that the template builds on."
        }
        if keywordTypes.contains(type) {
            return "The sketch's class would be called \(type), which Swift does not allow as a type name."
        }
        if let package = dependencyPackageNames.first(where: { $0 == name.lowercased() }) {
            return "The package would have the same name as \(package), which it depends on."
        }
        if unusableModules.contains(name) {
            return "\(name) is already the name of a module the sketch builds with."
        }
        if caseFoldedModules.contains(name.lowercased()) {
            return "\(name) differs only in letter case from a module the sketch imports, and the build writes both to the same file."
        }
        return nil
    }

    /// `my-sketch` から `MySketch` を作る。型の名前は識別子でなければならない。
    static func typeName(for name: String) -> String {
        let parts = name.split { $0 == "-" || $0 == "_" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
