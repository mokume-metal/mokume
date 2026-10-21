// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import Synchronization

/// 残り時間を測る値。決めた秒数が経ったかを、スケッチの時間で数える ([#2602])。
///
/// ブロック崩しなら、球を落とした後の 1 秒待ちに使う:
///
/// <!-- example: 文脈 var ball = Circle(x: 240, y: 60, radius: 8); var velocity = Vector2(3, 4) -->
/// ```swift
/// var respawn = Countdown(seconds: 1)
///
/// func draw() {
///     background(20)
///     if respawn.isFinished { ball.move(by: velocity) }
///     if ball.center.y > height {
///         ball.center = Vector2(240, 60)
///         respawn.restart()           // ここから 1 秒待つ
///     }
///     ball.draw()
/// }
/// ```
///
/// ## スケッチの時間で減る
///
/// 描いたフレームの経過 (``SketchPart/deltaTime``) を足し込んだぶんだけ減る。``SketchPart/time`` には
/// 従わない — 時刻を指定した観測で `time` が差し替わった 1 枚で終わると、**観測がゲームの状態を変える**
/// ことになる。
///
/// | 口 | 残り時間 |
/// | --- | --- |
/// | 普通のフレーム | その枚の `deltaTime` だけ減る |
/// | ``SketchPart/pauseTime()`` の間 | 減らない |
/// | ``SketchPart/jumpTime(_:)`` の枚・時刻を指定した観測の 1 枚 | 減らない (`deltaTime` が 0) |
/// | ``SketchPart/noLoop()`` の間・外からの停止 (`watch`・MCP) の間 | 減らない (フレームが来ない) |
///
/// **フレームの時計** (``SketchSettings/clock`` を ``SketchSettings/ClockMode/frames``) では `deltaTime` が
/// ちょうど 1 / fps なので、60 fps の `Countdown(seconds: 1)` は数え始めてから 60 枚目で終わり、何度
/// 走らせても同じ枚で終わる。実時間の時計では、終わる枚が実行ごとに揺れる。
///
/// ゲームの一時停止は「自分の印 + ``SketchPart/pauseTime()``」で書く。`pauseTime()` を呼べば
/// `Countdown` も止まる。自分の印だけで止めると、`Countdown` は進み続ける。
///
/// ## どこから数えるか
///
/// **``init(seconds:)`` で作った値は、スケッチの時間の原点 (最初のフレームの頭) から数える。** 作る口は
/// スケッチが走っていない所 (プロパティの初期値・`Task` の中) からも呼べるので、作った瞬間の時間を
/// 読まない。走っている途中から数えるなら ``restart()`` を呼ぶ — `draw()` の途中で
/// `Countdown(seconds: 1)` と作り直すと、既に 1 秒以上走っていればその場で終わっている。
///
/// ## 残り時間を保てるのは、同じ実行の中だけ
///
/// 値なので `Codable` で書き出して読み戻せるが、**残り時間を保ったまま読み戻せるのは、同じ実行の中
/// (同じスケッチの時間の上) だけ**である。書かれるのは長さと数え始めた位置で、位置は**その実行の**
/// スケッチの時間 (``SketchPart/deltaTime`` の積み上げ) で測ったものだからである。起動し直した実行は
/// 積み上げが 0 から始まるので、別の実行へ持ち越した値は残りが合わない — 10 秒の `Countdown` を
/// 積み上げが 100 秒の位置で `restart()` して書き出し、起動し直した実行で読み戻すと、最初の枚の
/// ``remaining`` は 110 秒になる (長さを超える)。
///
/// 別の実行へ残したいときは、**長さと残りを自分の値として持つ**。復元したら残りで
/// `Countdown(seconds:)` を作って ``restart()`` し、それが終わったら長さで作り直して、以後は
/// それを ``restart()`` する:
///
/// <!-- example: 文脈 var respawn = Countdown(seconds: 10); var resumed = Countdown(seconds: 2) -->
/// ```swift
/// // 残すもの: 長さと残りを自分の値で (例: 10 秒の Countdown の残り 2 秒)
/// let saved = (length: Float(10), remaining: respawn.remaining)
///
/// // 起動し直した実行で復元する: 残りで数え始める
/// resumed = Countdown(seconds: saved.remaining)
/// resumed.restart()
///
/// // 終わったら、長さで作り直す。以後はこれを restart() して 10 秒を繰り返す
/// if resumed.isFinished {
///     resumed = Countdown(seconds: saved.length)
///     resumed.restart()
/// }
/// ```
///
/// 手本に同じ型は無い。名前は Foundation の `Timer` との衝突を避けて採った ([ADR-0020] 決定 1)。
///
/// [#2602]: https://github.com/mokume-metal/mokume/issues/2602
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated struct Countdown: Sendable, Hashable, Codable {
    /// 長さ (秒)。0 以上の有限の数。
    private let seconds: Float
    /// 数え始めた位置 (描いたフレームの経過の積み上げ・秒)。`nil` ならスケッチの時間の原点。
    private var start: Double?

    /// `seconds` 秒を測る値を作る。スケッチの時間の原点から数える (「どこから数えるか」)。
    ///
    /// 数でない値・無限・負の値は、0 秒として受け取る (作ったときから終わっている)。黙って倒さず、
    /// 1 度だけ警告する ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public init(seconds: some ScalarConvertible) {
        let value = seconds.asFloat
        if value.isFinite, value >= 0 {
            self.seconds = value
        } else {
            Self.warnInvalid(value)
            self.seconds = 0
        }
        self.start = nil
    }

    /// 残り時間 (秒)。0 を下回らない。
    ///
    /// 走っているスケッチの外 (プロパティの初期値・`Task` の中など) で読むと、長さそのものを返し、
    /// 1 度だけ警告する。
    @MainActor
    public var remaining: Float {
        guard let elapsed = Self.elapsed("Countdown.remaining", returning: "the full length") else {
            return seconds
        }
        return remaining(at: elapsed)
    }

    /// 決めた秒数が経ったか。
    ///
    /// 走っているスケッチの外で読むと `false` を返し、1 度だけ警告する。
    @MainActor
    public var isFinished: Bool {
        guard let elapsed = Self.elapsed("Countdown.isFinished", returning: "false") else {
            return false
        }
        return isFinished(at: elapsed)
    }

    /// いまから数え直す。長さは作ったときのまま。
    ///
    /// 走っているスケッチの外で呼ぶと何もせず、1 度だけ警告する。
    @MainActor
    public mutating func restart() {
        guard let runtime = runningSketch else {
            return OutsideRun.log.warn("Countdown.restart()", .act)
        }
        restart(at: runtime.elapsed)
    }

    // MARK: - スケッチの時間を渡して読む (検査と上の口が使う)

    /// 積み上げが `elapsed` の位置から数え直す。
    mutating func restart(at elapsed: Double) {
        start = elapsed
    }

    /// 積み上げが `elapsed` のときの残り時間。
    func remaining(at elapsed: Double) -> Float {
        max(0, seconds - passed(at: elapsed))
    }

    /// 積み上げが `elapsed` のとき、終わっているか。**単精度の秒で比べる** — 長さは単精度で受け取って
    /// いるので、倍精度で比べると `0.1` 秒が 6 枚 (60 fps) で終わらない。
    func isFinished(at elapsed: Double) -> Bool {
        passed(at: elapsed) >= seconds
    }

    /// 数え始めてから経った秒 (単精度)。
    private func passed(at elapsed: Double) -> Float {
        Float(elapsed - (start ?? 0))
    }

    // MARK: - 知らせ

    /// 走っているスケッチの積み上げ。外なら 1 度だけ警告して `nil`。
    @MainActor
    private static func elapsed(_ call: String, returning value: String) -> Double? {
        guard let runtime = runningSketch else {
            OutsideRun.log.warn(call, .read(returning: value))
            return nil
        }
        return runtime.elapsed
    }

    /// 長さに受け取れない値を渡されたことを、プロセスで 1 度だけ言った印。作る口はどこからでも
    /// 呼べるので、隔離の外から書ける形にしてある。
    private static let warnedInvalid = Mutex(false)

    private static func warnInvalid(_ value: Float) {
        let first = warnedInvalid.withLock { warned in
            defer { warned = true }
            return !warned
        }
        guard first else { return }
        Diagnostics.warn(
            "Countdown(seconds:) takes a length of 0 seconds or more, so \(value) was taken as 0 "
                + "and the countdown is already finished")
    }
}
