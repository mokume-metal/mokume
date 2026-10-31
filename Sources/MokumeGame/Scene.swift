// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// ゲームの場面 (タイトル・プレイ中・結果など) を 1 つ持ち、切り替える値 ([#3588])。
///
/// 場面の名前は自分の `enum` で書き、`Scene` はそのうちのどれが「いま」かだけを持つ。
/// ``current`` を `switch` して、場面ごとの `draw()` の中身を分ける:
///
/// ```swift
/// enum Screen { case title, game, result }
///
/// final class Platformer: Sketch {
///     var scene = Scene(starting: Screen.title)
///     var score = 0
///
///     func draw() {
///         background(20)
///         switch scene.current {
///         case .title:
///             text("press enter", 240, 135)
///             if keyboard.justPressed(.enter) { scene.change(to: .game) }  // 効くのは次のフレームの頭
///         case .game:
///             if scene.justEntered { score = 0 }                             // 入った最初のフレームだけ
///             text("score \(score)", 240, 135)
///         case .result:
///             text("game over", 240, 135)
///         }
///     }
/// }
/// ```
///
/// 観測 (`mokume` の MCP の `observe`) でいまの場面を読みたいときは、`expose("scene", …)` へ自分で渡す。
/// 渡すのは自分の `enum` を文字列にしたもの (`String` を元にした `enum` なら `rawValue`)。`Scene` が
/// 勝手に公開することはない — 公開する名前と値は作品が決める。
///
/// ## 切り替えは次のフレームの頭で効く
///
/// **``change(to:)`` を呼んだフレームは、最後まで元の場面のまま描き終わる。** フレーム 10 の `draw()`
/// の途中で ``change(to:)`` を呼べば、その `draw()` の ``current`` は元の場面のままで、フレーム 11 の
/// `draw()` の頭から新しい場面になる。同じ `draw()` の中で場面が途中から変わらないので、`switch` の
/// 一方の枝が描きかけの絵を、もう一方の枝が引き継ぐことがない。先例は ``Movie`` の再生の口 (``Movie/play()``
/// など。次のフレームで効く)。
///
/// 切り替えが効くのはフレーム番号 (``SketchPart/frameCount``) で決まる。時計 (``SketchSettings/clock``)
/// が実時間でも ``SketchSettings/ClockMode/frames`` でも同じで、**同じ入力を流せば、何度走らせても同じ
/// フレームで切り替わる。** ``SketchPart/noLoop()`` で止めている間はフレームが進まないので、切り替えも
/// 効かない。
///
/// ## 入った最初のフレーム
///
/// ``justEntered`` は、その場面に入った最初の 1 フレームだけ真になる (``Keyboard/justPressed(_:)``
/// と同じ「その枚だけ真」)。位置やスコアを戻す処理をここに置く。
///
/// - **始まりの場面は最初のフレーム (`frameCount` が 1) から入っていて、そのフレームで真になる。**
/// - ``Sketch/setup()`` の中で ``change(to:)`` を呼べば、最初のフレームで効く (``justEntered`` も真)
/// - **同じ場面への ``change(to:)`` も、入り直しとして次のフレームで ``justEntered`` が真になる**
///   (やり直しに使える)
/// - 1 つのフレームの中で ``change(to:)`` を何度か呼べば、最後に呼んだものが効く
/// - `draw()` の途中で `Scene(starting:)` を作った値は、始まりの場面でも ``justEntered`` が立たない
///   (最初のフレームではないため)。入り直すなら ``change(to:)`` を使う
///
/// ## 走っているスケッチの外
///
/// ``current``・``justEntered``・``change(to:)`` はフレーム番号を読む。走っているスケッチの外
/// (プロパティの初期値・`Task` の中など) で呼ぶと、``SketchPart/frameCount`` と同じく 0 番目のフレーム
/// として扱い、1 度だけ警告する。0 番目のフレームの ``current`` は始まりの場面で、そこで呼んだ
/// ``change(to:)`` は最初のフレームで効く。
///
/// [#3588]: https://github.com/mokume-metal/mokume/issues/3588
public nonisolated struct Scene<Value: Sendable>: Sendable {
    /// 切り替えが効いた後に変わる、確定した場面。
    private var settled: Value
    /// ``settled`` に入った最初のフレーム。始まりの場面は 1 (最初のフレーム)。
    private var settledSince: Int
    /// 頼まれて、まだ効いていない切り替えの行き先。
    private var pending: Value?
    /// ``pending`` を頼んだフレーム。効くのはその次のフレームから。
    private var pendingFrame: Int

    /// `scene` を始まりの場面にして、最初のフレームから入っている状態で作る。
    ///
    /// ```swift
    /// enum Screen { case title, game }
    ///
    /// final class Tiny: Sketch {
    ///     var scene = Scene(starting: Screen.title)
    ///     func draw() { background(scene.current == .title ? 20 : 120) }
    /// }
    /// ```
    ///
    /// 走っていない所 (プロパティの初期値など) からも作れる。作った瞬間のフレームは読まない。
    public init(starting scene: Value) {
        self.settled = scene
        self.settledSince = 1
        self.pending = nil
        self.pendingFrame = 0
    }

    /// いまの場面。
    ///
    /// ``change(to:)`` を呼んだフレームの間は、まだ元の場面を返す。効くのは次のフレームの頭から。
    @MainActor
    public var current: Value {
        current(at: Self.liveFrame)
    }

    /// 今のフレームが、いまの場面に入った最初のフレームか。その 1 フレームだけ真になる。
    ///
    /// 始まりの場面は最初のフレームで真になる (「入った最初のフレーム」)。
    @MainActor
    public var justEntered: Bool {
        justEntered(at: Self.liveFrame)
    }

    /// 次のフレームの頭から `scene` に切り替える。呼んだフレームの ``current`` は元の場面のまま。
    ///
    /// 1 つのフレームの中で何度か呼べば、最後に呼んだものが効く。いまと同じ場面を渡すと、入り直しになる
    /// (次のフレームで ``justEntered`` が真)。
    @MainActor
    public mutating func change(to scene: Value) {
        change(to: scene, at: Self.liveFrame)
    }

    // MARK: - フレーム番号を渡して読む (検査と上の口が使う)

    /// フレーム `frame` の `draw()` から見える場面と、そこへ入ったフレーム。
    private func resolved(at frame: Int) -> (value: Value, since: Int) {
        if let pending, frame > pendingFrame {
            return (pending, pendingFrame + 1)
        }
        return (settled, settledSince)
    }

    func current(at frame: Int) -> Value {
        resolved(at: frame).value
    }

    func justEntered(at frame: Int) -> Bool {
        resolved(at: frame).since == frame
    }

    mutating func change(to scene: Value, at frame: Int) {
        // 前に頼んだ切り替えが効いていれば、確定してから次を頼む (入った位置を失わない)
        let now = resolved(at: frame)
        settled = now.value
        settledSince = now.since
        pending = scene
        pendingFrame = frame
    }

    // MARK: - フレーム番号を読む

    /// 走っているスケッチのフレーム番号。外なら 0 を返し、1 度だけ警告する
    /// (``SketchPart/frameCount`` の約束のまま)。
    @MainActor
    private static var liveFrame: Int { FrameReader().frameCount }
}

/// ``SketchPart/frameCount`` を読むための入れ物。``Scene`` 自体は ``SketchPart`` に準拠しない —
/// 準拠すると、描く語彙 (`fill`・`circle` など) が ``Scene`` の補完に出る。
private struct FrameReader: SketchPart {}
