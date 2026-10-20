// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// スケッチを作り、固定の fps で動きを書き出す (`render`・[#1282])。
///
/// ## なぜ `run` の引数ではなく口を分けるのか
///
/// **寿命が違う。** `run` は窓を閉じるまで走るが、こちらは決めた枚数を描いたら自分で終わり、
/// 終了コードが「書けたか」を意味する。加えて `run` と `watch` は同じ ``Invocation`` を解く
/// ので、`run` に足した選択肢は `watch` にも届き、断る分岐が要る。
///
/// ## 子がすること
///
/// 窓を開かず、時刻をフレーム番号から導き (`time = (frameCount - 1) / fps`)、最初のフレームの
/// 前から撮る係へ渡し、決めた枚数で終わる — 読み手は `SketchApplication` で、合図は
/// `StartupReads.render` の環境変数 1 つである。作品のコードは 1 行も変えない。
///
/// **全速では回さない。** 1 枚を描く速さは画面のリフレッシュ (作品が宣言した `frameRate` が
/// 上限) のままで、全速で回す駆動源は足さない (ADR-0012 決定 3)。`--fps` が宣言と同じなら、
/// 書き出しには実時間と同じだけかかる。
///
/// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
enum RenderCommand {
    /// 解いた引数。
    struct Options: Equatable {
        /// 走らせる部分 (場所・構成・置き場)。`run` と同じ解き方で解く。
        var invocation: Invocation
        /// 子へ渡す頼み。**行き先は既に絶対パスになっている。**
        var request: RenderRequest
    }

    static let frameRateFlags = ["--fps"]
    static let secondsFlags = ["--seconds"]
    static let outFlags = ["--out"]

    /// 書き出しの選択肢の宣言 (`run` の選択肢に足すぶん)。``Command/valueOptions`` が `doctor` に
    /// 同じ宣言を渡す。
    static var options: [Arguments.Option] {
        [
            Arguments.Option(frameRateFlags) {
                "\($0) needs a frame rate after it (frames per second, a whole number)"
            },
            Arguments.Option(secondsFlags) { "\($0) needs a length after it (in seconds)" },
            Arguments.Option(outFlags, takesPlace: true) {
                "\($0) needs somewhere to write after it (a .mov, .mp4 or .gif, or out/frame-####.png)"
            },
        ]
    }

    static func run(_ arguments: [String]) throws(CommandFailure) {
        // **ビルドの前に解く。** 引数の誤りを、数分のビルドの後で知らせない
        let options = try parse(arguments)
        let directory = try options.invocation.directory
        let package = directory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw .packageNotFound(path: directory.path)
        }
        try ResourceDeclaration.check(in: directory)

        print("Tool: \(ToolVersion.describe())")
        let context = try RunCommand.context(in: directory, invocation: options.invocation)
        if let notice = context.place.notice { print(notice) }
        let executable = try RunCommand.buildAndResolve(in: directory, context: context)
        try render(executable, in: directory, request: options.request)
        print(report(options.request))
    }

    /// 走らせて、書き出し先に頼んだものが揃ったことまで確かめる。**``report(_:)`` はこの後でだけ出す。**
    ///
    /// 子の終了コードは「子が自分を終えた」としか言わない。頼みを読まずに窓を開いて 0 で終わる古い版の
    /// 子 (道具と依存の版のずれ) は、何も書かずに 0 で終わる。書き出し先を事後に見て、足りなければ
    /// 名乗って 0 以外で終わる ([#2481](https://github.com/mokume-metal/mokume/issues/2481))。
    static func render(_ executable: URL, in directory: URL, request: RenderRequest) throws(
        CommandFailure
    ) {
        // 子を起こす前の時刻。前の回が同じ行き先に残したファイルを、この回のものと取り違えない
        let start = Date()
        try launch(executable, in: directory, request: request)
        if let shortfall = request.inspectOutput(since: start) {
            throw .renderOutputShort(
                destination: request.destination, expected: request.frameCount,
                shortfall: shortfall)
        }
    }

    /// 走らせて、書き終えるまで待つ。
    ///
    /// **待ち方と合図の運び方は `run` と同じ 1 本を通る** (``RunCommand/launch(_:in:environment:forwarding:)``)。
    /// 受ける合図も同じで、端末の Control + C を含む (``RunCommand/stopSignals(sigint:)``)。
    /// 受けた終わりの合図は子へ SIGTERM として渡り、子は終わりの経路で撮る係を閉じる —
    /// それまでの枚が入った開けるファイルが残り、道具は子が閉じ終えるのを待ってから終わる。
    ///
    /// 子が 0 以外で終わったら、揃わなかったと名乗る。理由は子が既に名乗っている。
    /// 0 で終わった後の書き出し先の確かめは、呼び出し側 (``render(_:in:request:)``) が持つ。
    static func launch(_ executable: URL, in directory: URL, request: RenderRequest) throws(
        CommandFailure
    ) {
        do {
            try RunCommand.launch(
                executable, in: directory,
                environment: RunCommand.childEnvironment(rendering: request))
        } catch {
            // **合図で落ちた回も揃わなかった回である** (#2315)。名乗るのは終わり方そのもの
            switch error {
            case .sketchExited(let status):
                throw .renderIncomplete(destination: request.destination, ending: .exited(status))
            case .sketchSignalled(let signal):
                throw .renderIncomplete(
                    destination: request.destination, ending: .signalled(signal))
            default:
                throw error
            }
        }
    }

    /// 書き終えたときの 1 行。**どこへ何枚書いたか**を名乗る。
    ///
    /// **配る形 (GIF・MP4) は、元にする形ではないことも名乗る** ([#2440])。同じ引数から書いても画素が
    /// 一致するとは約束しない (減色や符号化の器は OS のもので、版で変わりうる)。元にするなら `.mov` か
    /// PNG 連番。
    ///
    /// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
    static func report(_ request: RenderRequest) -> String {
        let wrote =
            "Wrote \(request.frameCount) frames at \(request.frameRate) fps to \(request.destination)"
        guard RenderRequest.isDistribution(destination: request.destination) else { return wrote }
        return wrote + "\n" + distributionNotice
    }

    /// 配る形を書き終えたときの 1 行 ([#2440])。
    static let distributionNotice =
        "This is a form for sharing, not for keeping: writing it again from the same arguments is not "
        + "promised to give the same pixels (to keep the motion, write a .mov or a numbered series)"

    // MARK: - 引数

    /// 引数を解く。
    ///
    /// **枚数は丸めない。** `fps × seconds` が整数にならない組は使い方の誤りとして断る —
    /// 丸めると、頼んだ長さと書き出した長さが黙って食い違う。
    ///
    /// - Parameter currentDirectory: 相対パスを解く基準。**打った場所である** — 子の作業
    ///   ディレクトリはスケッチの場所なので、`--out` は渡す前に絶対パスにする。場所と
    ///   `--scratch-path` も同じ基準で解く (#2320 — `--scratch-path` だけがスケッチの場所から
    ///   解かれ、隣に並ぶ `--out` と基準が割れていた)。
    static func parse(
        _ arguments: [String], currentDirectory: URL? = GivenPath.currentDirectory
    ) throws(CommandFailure) -> Options {
        let (invocation, values) = try Invocation.parse(
            arguments, adding: options, from: currentDirectory)

        guard let rateText = values[frameRateFlags[0]], let secondsText = values[secondsFlags[0]],
            let out = values[outFlags[0]]
        else {
            let missing = [frameRateFlags[0], secondsFlags[0], outFlags[0]].filter {
                values[$0] == nil
            }
            throw .usage(
                "\(Command.name) \(Command.Verb.render.rawValue) needs "
                    + "\(missing.joined(separator: ", ")) — pass all three:\n"
                    + "  \(Command.name) \(Command.Verb.render.rawValue) --fps 60 --seconds 4"
                    + " --out motion.mov")
        }
        let frameRate = try parseFrameRate(rateText)
        let frameCount = try parseFrameCount(seconds: secondsText, frameRate: frameRate)
        let destination = try GivenPath.resolve(out, from: currentDirectory, isDirectory: false).path
        // **形は打った綴りでも見る** (#2313)。絶対パスにすると末尾の `/` と `.`・`..` が消え、
        // 最後の部品が変わる — `take#1/` (フォルダ) が `…/take#1` になり、`take#1` の `#` を
        // 番号にして連番として通ってしまう。書く API は `take#1/` を断るので、道具だけが通すと
        // 同じ綴りで判定が食い違う
        //
        // **`.mov` へは刻みより速く書けない** (#2307)。形が通る行き先でだけ見て、形の誤りは
        // 下の `--out` の文面で名乗る
        //
        // **GIF は 1/100 秒の整数倍にならない刻みを断る** ([#2440])。黙って遅延を丸めず、枚を間引かない。
        // 使える近い fps を名指す
        if RenderRequest.isGIF(destination: out), RenderRequest.accepts(destination: out),
            !RenderRequest.accepts(destination: out, frameRate: frameRate)
        {
            throw .usage(
                "\(frameRateFlags[0]) \(rateText) cannot be written to a .gif: "
                    + RenderRequest.gifRateReason(frameRate: frameRate))
        }
        if RenderRequest.accepts(destination: out),
            !RenderRequest.accepts(destination: out, frameRate: frameRate)
        {
            let kind = out.lowercased().hasSuffix(".mp4") ? ".mp4" : ".mov"
            throw .usage(
                "\(frameRateFlags[0]) takes at most \(RenderRequest.movieFrameRateLimit) frames per"
                    + " second when writing a \(kind) (its time is counted in"
                    + " 1/\(RenderRequest.movieFrameRateLimit) of a second, which cannot hold a"
                    + " shorter frame, so frames would be lost): \(rateText)")
        }
        guard RenderRequest.accepts(destination: out),
            let request = RenderRequest(
                frameRate: frameRate, frameCount: frameCount, destination: destination)
        else {
            throw .usage(
                "\(outFlags[0]) takes a movie ending in .mov, .mp4 or .gif, or a numbered series with a"
                    + " run of # in the file name where the number goes (out/frame-####.png): \(out)")
        }
        // **ファイル名の長さも、ビルドの前に見る** (#2774)。子の中で落ちると、ビルドの後に、長さが理由
        // だと言われずに分かる。連番は番号が桁に収まらずに伸びた後の、最後の枚の名前で見る
        if let long = RenderRequest.nameTooLong(destination: destination, frameCount: frameCount) {
            throw .usage("\(outFlags[0]): \(RenderRequest.tooLongReason(long))")
        }
        return Options(invocation: invocation, request: request)
    }

    /// `--fps` の値。**1 以上の整数だけ** — 時計がフレーム番号から導く刻みは整数である。
    static func parseFrameRate(_ text: String) throws(CommandFailure) -> Int {
        guard let rate = Int(text), rate > 0 else {
            throw .usage(
                "\(frameRateFlags[0]) takes a whole number of frames per second above 0: \(text)")
        }
        return rate
    }

    /// 書く枚数。**`fps × seconds` が整数になるときだけ。**
    ///
    /// 掛け算は 10 進で行う。`100 × 1.1` を 2 進の浮動小数で掛けると 110 にならず、丸めない
    /// 規則が正しい組まで断る。
    static func parseFrameCount(seconds text: String, frameRate: Int) throws(CommandFailure)
        -> Int
    {
        // 形は浮動小数で確かめる — 10 進の読み取りは頭の数字だけを拾って残りを黙って捨てる
        guard let approximate = Double(text), approximate.isFinite, approximate > 0,
            let seconds = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
            seconds > 0
        else {
            throw .usage("\(secondsFlags[0]) takes a length in seconds above 0: \(text)")
        }
        var product = Decimal(frameRate) * seconds
        var whole = Decimal()
        NSDecimalRound(&whole, &product, 0, .plain)
        guard whole == product else {
            throw .usage(
                "\(frameRateFlags[0]) \(frameRate) × \(secondsFlags[0]) \(text) is \(product) frames,"
                    + " not a whole number. Pick a length that makes whole frames"
                    + " (the count is not rounded)")
        }
        guard whole <= Decimal(Int(Int32.max)) else {
            throw .usage("That is too many frames to write: \(whole)")
        }
        return NSDecimalNumber(decimal: whole).intValue
    }
}
