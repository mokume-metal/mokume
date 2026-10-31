// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 入口。
///
/// **引数の解釈は自前で持つ。** 外の道具を足すほどの形ではなく (コマンド 2 つと
/// 少数の選択肢)、依存はそれ自体が更新と互換の面倒を連れてくる。
enum Command {
    /// 打たれた名前。
    ///
    /// **案内文は書き固めず、起動された名前から出す。** 配布物は `mokume` という名前で
    /// 入り、開発中は `swift run mokume-cli` で呼ばれる — どちらか一方を書き固めると、
    /// 印字した行がもう一方ではそのまま打てない。名前の正典を 2 つ持たないための一手
    /// でもある (Package.swift の product 名は SwiftPM の制約で `mokume-cli` のまま)。
    ///
    /// **どこからでも読めるようにする** (`nonisolated`)。案内文は失敗の側にも書かれて
    /// おり ([CommandFailure])、そちらは隔離を持たないため。値は起動時に決まって
    /// 変わらない文字列なので、隔離を外しても競合しない。
    nonisolated static let name = invokedName()

    /// 起動に使われた道の末尾。取れなければ配布時の名前に倒す。
    ///
    /// **URL に通さず自分で切る。** 空の道を URL(fileURLWithPath:) に渡すと今いる
    /// ディレクトリとして解決され、末尾は作業ディレクトリの名前になる — 案内文が
    /// 打てない名前を名乗ることになる (検査が拾った)。
    nonisolated static func invokedName(_ path: String = CommandLine.arguments.first ?? "")
        -> String
    {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? "mokume" : last
    }

    /// どの口でも、値を取る選択肢の宣言の和集合。**宣言は各口が 1 つずつ持ち、ここは並べるだけ。**
    ///
    /// `doctor` が使う。値を取る選択肢を知らないと、`doctor --fps 60` の `60` が場所として診られる
    /// ([#2484](https://github.com/mokume-metal/mokume/issues/2484))。口に選択肢を足したら、
    /// ここに並べる — 並べ忘れは `ArgumentsTests` が全口の綴りで見つける。`mcp` は選択肢を取らない。
    static var valueOptions: [Arguments.Option] {
        Invocation.options + RecordOption.options + RenderCommand.options + BundleCommand.options
            + NewCommand.options
    }

    /// 打てる口。
    ///
    /// **綴りの正典はここ 1 つ。** かつては口の名前が dispatch の `switch` と案内文に
    /// 別々の文字列リテラルで並んでおり、対応を保つ機械が居なかった
    /// ([#814](https://github.com/mokume-metal/mokume/issues/814))。いまは口を足すと
    /// ``dispatch(_:)`` の網羅 `switch` と ``usageEntry`` の両方が**コンパイラに
    /// 問われる** — 案内に並べないなら、並べないと書くことになる。
    enum Verb: String, CaseIterable {
        case new, examples, run, watch, render, mcp, bundle, doctor, help, version

        /// 慣習の綴り。名前とは別に受けるだけで、案内には並べない。
        var aliases: [String] {
            switch self {
            case .help: ["--help", "-h"]
            case .version: ["--version", "-v"]
            default: []
            }
        }

        /// 打たれた綴りから口を解く。
        static func named(_ spelling: String) -> Verb? {
            allCases.first { $0.rawValue == spelling || $0.aliases.contains(spelling) }
        }

        /// 案内文に並べる 1 項目。**並べないものは `nil`。**
        ///
        /// `version` が `nil` なのは意図である — 古い版を持つ人はこの綴りを知らないので、
        /// 到達できる口は help のほうであり (#634 の完了条件 3)、案内は末尾で道具の版を
        /// 既に名乗っている。ここは慣習の綴りを受けるだけの口である。
        var usageEntry: (signature: String, description: String)? {
            switch self {
            case .new:
                (
                    "new <name> [--from <example>] [--path <directory>] [--local <library path>]",
                    """
                    Create a sketch package. Pass --from to start from one of the examples (see examples)
                    instead of the spinning circle. Pass --local to point at this repository (for development).
                    --local goes into the new Package.swift as is, so a relative one starts from the
                    new sketch, not from where you run this
                    """
                )
            case .examples:
                (
                    "examples",
                    """
                    List the examples that ship with the tool, by the names the reference uses.
                    Open one as a new sketch with new <name> --from <example>
                    """
                )
            case .run:
                (
                    "run [<directory>] [-c <configuration>] [--scratch-path <directory>] [--record <path>]",
                    """
                    Build a sketch and run it. Defaults to the current directory.
                    -c takes debug or release (defaults to whatever the toolchain uses).
                    Build products are shared per version by default. Pass --scratch-path
                    to put them in a directory of your own instead (doctor reports where they are).
                    Relative paths start from where you run this, --scratch-path included
                    Pass --record to write the run, from its first frame to its end, into one file
                    that can be replayed. There is no default place for it: --record takes the file
                    (a relative one starts from where you run this too). Only a sketch on the frame
                    clock (clock: .frames) is recorded; on the wall clock it says why, does not
                    record, and keeps running
                    """
                )
            case .watch:
                (
                    """
                    watch [<directory>] [-c <configuration>] [--scratch-path <directory>] \
                    [--keep-time] [--record <path>]
                    """,
                    """
                    Rebuild the sketch and swap it in whenever you save.
                    Pass --record to write each build's run, from its first frame to its end, into a file
                    that can be replayed. Every rebuild starts a new record, a cut between two files:
                    --record take.json writes take-1.json, take-2.json and so on, one per build.
                    Pass --keep-time to carry the sketch's clock across a rebuild: the new version starts
                    from where the old one was (a time you stopped with pauseTime() stays stopped), instead
                    of at 0. It carries only that clock's seconds and whether it is stopped, not frameCount,
                    random numbers or anything built up from deltaTime; with clock .frames the time continues
                    from the carried second while frameCount starts at 1 again, and a pauseTime(), playTime()
                    or jumpTime() in setup() wins. If the old version crashed or had stopped drawing
                    with noLoop(), the new one starts from the second it last wrote or last showed,
                    without the time that passed. run and render always start at 0.
                    What it watches: Package.swift, every .swift under Sources/, and the regular files
                    under Sources/<target>/assets/ (not hidden files or symbolic links). A .metal
                    fragment is not rebuilt: it swaps in while the sketch keeps running.
                    A change anywhere else does not rebuild — resources Package.swift declares outside
                    assets/ (.process("Resources"), .copy("data.json"), a changed path:), Package.resolved,
                    a dependency given by path (--local). Stop watch and start it again after those
                    """
                )
            case .render:
                (
                    """
                    render [<directory>] [-c <configuration>] [--scratch-path <directory>] \
                    --fps <n> --seconds <s> --out <path> [--scale <n>]
                    """,
                    """
                    Build the sketch and write its motion at a fixed frame rate, with no window.
                    The time the sketch sees steps by 1/fps per frame, so the same arguments give
                    the same motion. --out takes a .mov (ProRes 4444) or a numbered series with a
                    run of # in the file name for the number (out/frame-####.png) — the forms to
                    keep, which give the same pixels from the same arguments — or a .mp4 (H.264)
                    or .gif to share, which do not promise that. A .gif holds 256 colours, shows
                    colour as sRGB, and writes each pixel opaque or transparent (alpha 128 or
                    more is opaque), and its frame time is a whole number of 1/100 seconds, so
                    --fps must divide 100 (50, 25, 20 …); a .mp4 writes colour as sRGB with no
                    transparency, and H.264 can drop a pixel from an odd width or height (65x49
                    comes out 64x48) — it says so on stderr when it does. Ends by itself after
                    fps × seconds frames. --scale <n> (a whole
                    number from 1, default 1) writes n times the pixels each way without changing the
                    sketch's coordinates: a 1920×1080 sketch is written at 3840×2160 with --scale 2.
                    Drawing targets from createGraphics are scaled too, and one whose size times n is
                    past 16384 pixels a side is refused where setup() or draw() creates it
                    """
                )
            case .mcp:
                ("mcp [<directory>]", "Serve the agent interface (speaks over stdin and stdout)")
            case .bundle:
                (
                    "bundle [<directory>] [--out <directory>]",
                    """
                    Package the sketch to run on another machine (its identity goes in \(AppIdentity.fileName)).
                    Relative paths start from where you run this, --out included
                    """
                )
            case .doctor:
                (
                    "doctor [<directory>]",
                    "List what the environment provides and what is here, for when things do not run"
                )
            case .help:
                (
                    "help [<command>]",
                    "Show the commands, or pass one to see only what it takes"
                )
            case .version:
                nil
            }
        }
    }

    /// 口の説明の各行。**全体の使い方と口のヘルプが同じ値から出る** (写しを持たない・#3425)。
    private static func descriptionLines(_ entry: (signature: String, description: String)) -> [String] {
        entry.description.split(separator: "\n").map { "      \($0)" }
    }

    static func usage(_ name: String = name) -> String {
        var lines = ["Usage: \(name) <command>", ""]
        for verb in Verb.allCases {
            guard let entry = verb.usageEntry else { continue }
            lines.append("  \(entry.signature)")
            lines += descriptionLines(entry)
            lines.append("")
        }
        lines.append("Tool: \(ToolVersion.describe())")
        return lines.joined(separator: "\n")
    }

    /// その口だけの使い方 (`<口> --help`・`help <口>`)。**`usageEntry` から作る** — 新しい説明は書かない。
    ///
    /// 使い方の宣言を持たない口 (`version`) は、全体の使い方を返す (版はその末尾の `Tool:` が名乗る・#634)。
    static func help(for verb: Verb, _ name: String = name) -> String {
        guard let entry = verb.usageEntry else { return usage(name) }
        return (["Usage: \(name) \(entry.signature)", ""] + descriptionLines(entry))
            .joined(separator: "\n")
    }

    /// 誤りの後ろに置く 1 行。**全体の使い方は繰り返さない** (#3425)。
    static func pointer(to verb: Verb) -> String {
        "See \(name) help \(verb.rawValue) for what \(verb.rawValue) takes."
    }

    static func dispatch(_ arguments: [String]) throws(CommandFailure) {
        guard let first = arguments.first else { throw .usage(usage()) }
        let rest = Array(arguments.dropFirst())
        guard let verb = Verb.named(first) else {
            throw .usage("Unknown command: \(first)\nSee \(name) help for the commands.")
        }
        switch verb {
        case .help:
            try help(arguments: rest)
        case .version:
            try version(arguments: rest)
        default:
            do {
                try perform(verb, rest)
            } catch .helpRequested {
                print(help(for: verb))
            } catch .usage(let text) {
                // 誤りの文と、どこを読めばよいかの 1 行だけ。全体の使い方は付けない
                throw .usage(text + "\n" + pointer(to: verb))
            }
        }
    }

    /// `help [<command>]`。**余る引数を黙って捨てない** (#2321 と同じ約束)。
    private static func help(arguments: [String]) throws(CommandFailure) {
        guard let spelling = arguments.first else {
            print(usage())
            return
        }
        guard let target = Verb.named(spelling) else {
            throw .usage("Unknown command: \(spelling)\nSee \(name) help for the commands.")
        }
        if let extra = arguments.dropFirst().first {
            throw .usage(
                "\(name) help takes at most one command (got \(GivenPath.shellWord(display: extra)))\n"
                    + pointer(to: .help))
        }
        print(help(for: target))
    }

    /// `version`。引数を取らない。`--help` / `-h` は全体の使い方を出す (版はその末尾が名乗る)。
    private static func version(arguments: [String]) throws(CommandFailure) {
        if arguments.contains(where: { Arguments.helpSpellings.contains($0) }) {
            print(usage())
            return
        }
        if let extra = arguments.first {
            throw .usage(
                "\(name) version takes no arguments (got \(GivenPath.shellWord(display: extra)))")
        }
        print(ToolVersion.describe())
    }

    /// 口を走らせる。`help` と `version` は ``dispatch(_:)`` が先に受ける。
    private static func perform(_ verb: Verb, _ rest: [String]) throws(CommandFailure) {
        switch verb {
        case .new:
            try NewCommand.run(rest)
        case .examples:
            try ExamplesCommand.run(rest)
        case .run:
            try RunCommand.run(rest)
        case .watch:
            try WatchCommand.run(rest)
        case .render:
            try RenderCommand.run(rest)
        case .mcp:
            try MCPCommand.run(rest)
        case .bundle:
            try BundleCommand.run(rest)
        case .doctor:
            // ヘルプを頼まれたら診断を走らせない。それ以外の知らない引数は、これまでどおり脇へ置いて診る
            // (切り分けの口が使い方で止まると、いちばん要るときに読めない)
            if DoctorCommand.asksForHelp(rest) { throw .helpRequested }
            DoctorCommand.run(rest)
        case .help, .version:
            // ``dispatch(_:)`` が先に受けるので、ここへは来ない
            preconditionFailure("handled by dispatch")
        }
    }
}
