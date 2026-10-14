// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 走っている実行の外から呼ばれた語彙の控え。**何を、どう扱ったか**を口の名前ごとに 1 度だけ言う
/// ([#2265])。
///
/// 語彙が描く先・読む元は ``runningSketch`` で、差さっているのは `setup()`・`draw()`・入力の
/// コールバックの間だけである。外 — 初期化子の中 (`struct Player: SketchPart` の `init()`)・
/// 後片付けの後・そこで起こした `Task` の中 — から呼ばれたとき、以前は `fatalError` で
/// プロセスごと落ちていた。ADR-0020 決定 5 は、描く口は「警告して安全な既定へ倒す」、読み取りは
/// 「決して落ちない」と決めている。ここはその警告の側を持つ。
///
/// **口の名前を鍵に 1 度だけ言う。** 名前は呼ぶ側の `#function` で、重ね定義 (`fill(_:)` の
/// 各形) は 1 つの口として数える。毎フレーム呼ばれる口でも 1 行で済み、控えは口の種類の数で
/// 止まる。
///
/// **控えは観測の応答にも載る** (``SketchRuntime`` の観測の目録)。標準エラーの 1 行は MCP から
/// 読めず、部品が (0, −30) に居続ける理由を AI が観測で辿れなくなるためである。
///
/// **「走っていない」とは言わない** (``OutsideCall`` と同じく [#1322])。`draw()` が回っている
/// 最中に `Task` から呼んでもここへ来るので、どちらでも事実である「どこからなら受け付けるか」を
/// 言う。
///
/// [#1322]: https://github.com/mokume-metal/mokume/issues/1322
/// [#2265]: https://github.com/mokume-metal/mokume/issues/2265
@MainActor
final class OutsideRun {
    /// 外から呼ばれたとき、どう倒したか。
    enum Use {
        /// 描く・状態を書く口。何もしなかった。
        case act
        /// 読み取りの口。代わりに `value` (人が読む綴り: `0`・`.wallClock` など) を返した。
        case read(returning: String)
    }

    /// 検査が自分の控えを差す口。差していなければ ``shared``。
    ///
    /// 控えはプロセスで 1 つなので、並んで走る検査が同じ口を呼ぶと「1 度だけ」を数え合う。
    /// 差しておけば、その検査の中で起きたことだけを数えられる。
    @TaskLocal static var current: OutsideRun?

    /// プロセスの控え。
    static let shared = OutsideRun()

    /// いま言う先の控え。
    static var log: OutsideRun { current ?? shared }

    private var said = WarningLog<String>()
    /// 言った順。観測の応答はこの順で載せる (対応表の順は定まらない)。
    private(set) var messages: [String] = []

    /// その口について、まだ言っていなければ 1 度だけ言う。
    func warn(_ call: String, _ use: Use) {
        guard !said.hasWarned(call) else { return }
        said.warnOnce(call, Self.notice(call, use))
        if let text = said.message(for: call) { messages.append(text) }
    }

    /// その口について言った文面。まだ言っていなければ `nil`。**検査が読む。**
    func message(for call: String) -> String? { said.message(for: call) }

    /// 言う中身。**2 通りを完全な文として持つ** (ADR-0038 決定 3)。差し込むのは口の名前と
    /// 返した値だけで、どちらも語順に関わらない識別子である。
    static func notice(_ call: String, _ use: Use) -> String {
        switch use {
        case .act:
            "\(call) only works inside setup(), draw() or an input callback. It was called "
                + "outside them — from an initialiser, after the sketch ended, or from a Task — so "
                + "it did nothing. Call it from setup() or draw()"
        case .read(let value):
            "\(call) is only known inside setup(), draw() or an input callback. It was read "
                + "outside them — from an initialiser, after the sketch ended, or from a Task — so "
                + "\(value) was returned instead. Make anything that depends on it inside setup()"
        }
    }

    /// 資源を作る口を外から呼んだときに止める文面。返す値そのものを面からしか作れないので、
    /// 既定へ倒せない (#2265 の完了条件 5)。
    static func stopNotice(_ call: String) -> String {
        "\(call) only works inside setup(), draw() or an input callback, because what it returns "
            + "is made on the running sketch's surface. It was called outside them — from an "
            + "initialiser, a property initialiser, after the sketch ended, or from a Task — "
            + "where there is no surface. Call it from setup()"
    }
}
