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
        Invocation.options + RenderCommand.options + BundleCommand.options + NewCommand.options
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
                    "run [<directory>] [-c <configuration>] [--scratch-path <directory>]",
                    """
                    Build a sketch and run it. Defaults to the current directory.
                    -c takes debug or release (defaults to whatever the toolchain uses).
                    Build products are shared per version by default. Pass --scratch-path
                    to put them in a directory of your own instead (doctor reports where they are).
                    Relative paths start from where you run this, --scratch-path included
                    """
                )
            case .watch:
                (
                    "watch [<directory>] [-c <configuration>] [--scratch-path <directory>] [--keep-time]",
                    """
                    Rebuild the sketch and swap it in whenever you save.
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
                    sketch's coordinates: a 1920×1080 sketch is written at 3840×2160 with --scale 2
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
                ("help", "This message")
            case .version:
                nil
            }
        }
    }

    static func usage(_ name: String = name) -> String {
        var lines = ["Usage: \(name) <command>", ""]
        for verb in Verb.allCases {
            guard let entry = verb.usageEntry else { continue }
            lines.append("  \(entry.signature)")
            lines += entry.description.split(separator: "\n").map { "      \($0)" }
            lines.append("")
        }
        lines.append("Tool: \(ToolVersion.describe())")
        return lines.joined(separator: "\n")
    }

    static func dispatch(_ arguments: [String]) throws(CommandFailure) {
        guard let first = arguments.first else { throw .usage(usage()) }
        let rest = Array(arguments.dropFirst())
        guard let verb = Verb.named(first) else {
            throw .usage("Unknown command: \(first)\n\n" + usage())
        }
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
            // 投げない。切り分けの口が失敗で終わると、いちばん要るときに読めない
            DoctorCommand.run(rest)
        case .help:
            print(usage())
        case .version:
            print(ToolVersion.describe())
        }
    }
}
