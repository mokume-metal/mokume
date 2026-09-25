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

    static func run(_ arguments: [String]) throws(CommandFailure) {
        // **ビルドの前に解く。** 引数の誤りを、数分のビルドの後で知らせない
        let options = try parse(arguments)
        let directory = options.invocation.directory
        let package = directory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw .packageNotFound(path: directory.path)
        }
        try ResourceDeclaration.check(in: directory)

        print("Tool: \(ToolVersion.describe())")
        let context = try RunCommand.context(in: directory, invocation: options.invocation)
        if let notice = context.place.notice { print(notice) }
        let executable = try RunCommand.buildAndResolve(in: directory, context: context)
        try launch(executable, in: directory, request: options.request)
        print(report(options.request))
    }

    /// 走らせて、書き終えるまで待つ。
    ///
    /// **待ち方と合図の運び方は `run` と同じ 1 本を通る** (``RunCommand/launch(_:in:environment:forwarding:)``)。
    /// 受けた終わりの合図は子へ SIGTERM として渡り、子は終わりの経路で撮る係を閉じる —
    /// それまでの枚が入った開けるファイルが残り、道具は子が閉じ終えるのを待ってから終わる。
    ///
    /// 子が 0 以外で終わったら、揃わなかったと名乗る。理由は子が既に名乗っている。
    static func launch(_ executable: URL, in directory: URL, request: RenderRequest) throws(
        CommandFailure
    ) {
        do {
            try RunCommand.launch(
                executable, in: directory,
                environment: RunCommand.childEnvironment(rendering: request),
                forwarding: stopSignals())
        } catch {
            guard case .sketchExited(let status) = error else { throw error }
            throw .renderIncomplete(destination: request.destination, status: status)
        }
    }

    /// 道具が受けて子へ渡す終わりの合図。**`run` の合図に SIGINT を足す。**
    ///
    /// **端末の Control + C は子へ届かない。** `Process` は子を別のプロセスグループに置く
    /// (書き出しの途中で `ps -o pgid` を見て確かめた) ので、端末が前面のグループへ配る SIGINT は
    /// 道具にしか届かない。受けずにいると道具だけがその場で終わり、子は窓も無いまま書き出しを
    /// 最後まで続ける — 止めたつもりの人の手元で、見えない書き出しが走り続ける。
    ///
    /// **無視で継いだ SIGINT には置かない。** 背面 (`&`) で起こされた起動の約束で、子も同じ
    /// 無視を継ぐので、両方が同じく受け流す (子の側の規則は `StopSignals` と同じ)。
    ///
    /// - Parameter current: いまの SIGINT の受け口。**検査から渡す** — 既定はこのプロセスのもの。
    static func stopSignals(sigint current: sigaction = currentAction(SIGINT)) -> [Int32] {
        StopSignals.isIgnored(current) ? RunCommand.stopSignals : RunCommand.stopSignals + [SIGINT]
    }

    /// その合図のいまの受け口。
    static func currentAction(_ number: Int32) -> sigaction {
        var action = sigaction()
        sigaction(number, nil, &action)
        return action
    }

    /// 書き終えたときの 1 行。**どこへ何枚書いたか**を名乗る。
    static func report(_ request: RenderRequest) -> String {
        "Wrote \(request.frameCount) frames at \(request.frameRate) fps to \(request.destination)"
    }

    // MARK: - 引数

    /// 引数を解く。
    ///
    /// **枚数は丸めない。** `fps × seconds` が整数にならない組は使い方の誤りとして断る —
    /// 丸めると、頼んだ長さと書き出した長さが黙って食い違う。
    ///
    /// - Parameter currentDirectory: `--out` の相対パスを解く基準。**打った場所である** —
    ///   子の作業ディレクトリはスケッチの場所なので、渡す前に絶対パスにする。
    static func parse(
        _ arguments: [String],
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) throws(CommandFailure) -> Options {
        let (invocation, values) = try Invocation.parse(
            arguments,
            adding: [
                Arguments.Option(frameRateFlags) {
                    "\($0) needs a frame rate after it (frames per second, a whole number)"
                },
                Arguments.Option(secondsFlags) { "\($0) needs a length after it (in seconds)" },
                Arguments.Option(outFlags) {
                    "\($0) needs somewhere to write after it (a .mov, or out/frame-####.png)"
                },
            ])

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
        let destination = URL(
            fileURLWithPath: NSString(string: out).expandingTildeInPath, relativeTo: currentDirectory
        ).standardizedFileURL.path
        guard
            let request = RenderRequest(
                frameRate: frameRate, frameCount: frameCount, destination: destination)
        else {
            throw .usage(
                "\(outFlags[0]) takes a movie ending in .mov, or a numbered series with a run of #"
                    + " where the number goes (out/frame-####.png): \(out)")
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
