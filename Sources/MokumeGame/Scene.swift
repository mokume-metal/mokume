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
/// **始まりの場面は `Scene(starting: Screen.title)` か `Scene<Screen>(starting: .title)` と書く。**
/// `Scene(starting: .title)` は、どの `enum` の `.title` か決まらず組めない。切り替えは型が決まっているので
/// `change(to: .game)` と書ける。
///
/// 観測 (`mokume` の MCP の `observe`) でいまの場面を読みたいときは、`expose("scene", …)` へ自分で渡す。
/// 渡すのは自分の `enum` を文字列にしたもの (`String` を元にした `enum` なら `rawValue`)。`Scene` が
/// 勝手に公開することはない — 公開する名前と値は作品が決める。
///
/// **SwiftUI にも `Scene` がある。** `import SwiftUI` と同じファイルで `some Scene` と書くと、どちらの `Scene`
/// か決まらず組めない。`SwiftUI.Scene`・`mokume.Scene` と書き分ける。
///
/// ## 切り替えは次のフレームの頭で効く
///
/// **``change(to:)`` を呼んだフレームは、最後まで元の場面のまま描き終わる。** フレーム 10 の `draw()`
/// の途中で ``change(to:)`` を呼べば、その `draw()` の ``current`` は元の場面のままで、フレーム 11 の
/// `draw()` の頭から新しい場面になる。同じ `draw()` の中で場面が途中から変わらないので、`switch` の
/// 一方の枝が描きかけの絵を、もう一方の枝が引き継ぐことがない。先例は ``Movie`` の再生の口 (``Movie/play()``
/// など。次のフレームで効く)。
///
/// 効くフレームは、**``change(to:)`` を呼んだ時点で決まる**。`draw()` を始めた回数で数えるので、時計
/// (``SketchSettings/clock``) が実時間でも ``SketchSettings/ClockMode/frames`` でも同じで、**同じ入力を
/// 流せば、何度走らせても同じフレームで切り替わる。**
///
/// **`draw()` の前に走るものから呼んだ切り替えは、直後の `draw()` で効く。** 入力のコールバック
/// (``Sketch/keyPressed()`` など)・入り口の供給・`Task`・OSC や WebSocket の受け取りは、`draw()` と `draw()`
/// の間に走る。そこで呼べば、すぐ次に描くフレームから新しい場面になり、そのフレームで ``justEntered`` が真になる。
/// ``SketchPart/noLoop()`` で止めている間のコールバックも同じで、``SketchPart/redraw()`` や ``SketchPart/loop()``
/// で次に描くフレームの頭で効く。**効くまでの間、コールバックで読む ``current`` は元の場面のまま。**
/// **`draw()` の中で呼んだものだけが、そのフレームの終わりまで元の場面で、次の `draw()` から効く。**
///
/// ## 入った最初のフレーム
///
/// ``justEntered`` は、その場面に入った最初の 1 フレームだけ真になる (``Keyboard/justPressed(_:)``
/// と同じ「その枚だけ真」)。位置やスコアを戻す処理をここに置く。
///
/// - **始まりの場面は最初のフレーム (最初の `draw()`) から入っていて、そのフレームで真になる。**
/// - ``Sketch/setup()`` の中や、プロパティの初期値のような描く前の所で ``change(to:)`` を呼べば、最初の
///   フレームで効く (``justEntered`` も真)
/// - **同じ場面への ``change(to:)`` も、入り直しとして次のフレームで ``justEntered`` が真になる**
///   (やり直しに使える)
/// - 1 つのフレームの中で ``change(to:)`` を何度か呼べば、最後に呼んだものが効く
/// - `draw()` の途中で `Scene(starting:)` を作った値は、始まりの場面でも ``justEntered`` が立たない
///   (最初のフレームではないため)。入り直すなら ``change(to:)`` を使う
/// - **実行が変わったら、新しい実行とみなす。** 同じ `Scene` を別の実行へ持ち越す (`static` に置く・
///   作り直したスケッチへ渡す) と、`draw()` の数は 1 から数え直される。頼んでいた切り替えがあれば確定させ、
///   その実行の最初のフレームに入ったものとして ``justEntered`` を真にする
///
/// ## 同じ場面を指す
///
/// **`Scene` を代入して渡した先は、同じ場面を指す。** 値を複製しても、場面の持ち主は 1 つ — 部品
/// (`struct Player: SketchPart`) に渡した `Scene` で ``change(to:)`` を呼べば、スケッチが持つ `Scene` が
/// 切り替わる。別の場面を並べて持ちたいときは、`Scene(starting:)` をもう 1 つ作る。
///
/// ## 走っていない所で読む
///
/// ``current`` と ``justEntered`` を、走っているスケッチの外 (`Task` の中・走る前・SwiftUI の `body`) で読むと、
/// いま描いているフレームが無いので、**最後に描いたフレームで見えていた場面** (まだ 1 枚も描いていなければ
/// 始まりの場面) を返し、``justEntered`` は偽になる。1 度だけ警告する (口の名前 `Scene.current`・
/// `Scene.justEntered` で。観測の応答の `warnings` にも載る)。場面を `draw()` の外で使いたいときは、`draw()` の中で
/// 自分の状態へ写すか、`expose` で観測へ渡す。``change(to:)`` はどこから呼んでもよく、警告しない。
///
/// [#3588]: https://github.com/mokume-metal/mokume/issues/3588
public nonisolated struct Scene<Value: Sendable>: Sendable {
    /// 場面の持ち主。**複製した `Scene` が共有する** (「同じ場面を指す」)。
    private let storage: Storage

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
        storage = Storage(starting: scene)
    }

    /// いまの場面。
    ///
    /// ``change(to:)`` を呼んだフレームの間は、まだ元の場面を返す。効くのは次のフレームの頭から。
    /// 走っていない所で読むと、最後に描いたフレームで見えていた場面を返し、1 度だけ警告する。
    @MainActor
    public var current: Value {
        guard DrawLedger.isInsideRun else {
            return lastDrawnScene(at: DrawLedger.progress, calledAs: "Scene.current")
        }
        return sceneVisible(at: DrawLedger.progress)
    }

    /// 今のフレームが、いまの場面に入った最初のフレームか。その 1 フレームだけ真になる。
    ///
    /// 始まりの場面は最初のフレームで真になる (「入った最初のフレーム」)。走っていない所で読むと偽を返し、
    /// 1 度だけ警告する。
    @MainActor
    public var justEntered: Bool {
        guard DrawLedger.isInsideRun else {
            _ = lastDrawnScene(at: DrawLedger.progress, calledAs: "Scene.justEntered")
            return false
        }
        return enteredAtDraw(at: DrawLedger.progress)
    }

    /// 次のフレームの頭から `scene` に切り替える。呼んだフレームの ``current`` は元の場面のまま。
    ///
    /// 1 つのフレームの中で何度か呼べば、最後に呼んだものが効く。いまと同じ場面を渡すと、入り直しになる
    /// (次のフレームで ``justEntered`` が真)。`draw()` の前に走るもの (入力のコールバック・`Task` など) から
    /// 呼んでもよく、直後に描くフレームの頭で効く。
    @MainActor
    public func change(to scene: Value) {
        requestChange(to: scene, at: DrawLedger.progress)
    }

    // MARK: - 目盛りを渡して読む (検査と上の口が使う)

    /// 目盛り `progress` で見える場面。
    @MainActor
    func sceneVisible(at progress: DrawProgress) -> Value {
        storage.see(progress).value
    }

    /// 目盛り `progress` が、いまの場面に入った最初の `draw()` か。
    @MainActor
    func enteredAtDraw(at progress: DrawProgress) -> Bool {
        storage.see(progress).since == progress.draws
    }

    @MainActor
    func requestChange(to scene: Value, at progress: DrawProgress) {
        storage.change(to: scene, at: progress)
    }

    /// 走っていない所で読まれたとき: 警告して、最後に描いた `draw()` で見えていた場面を返す。
    ///
    /// 警告は走っている実行の外から呼ばれた語彙の控え (`OutsideRun`) へ言う。観測の応答にも載る。`justEntered`
    /// の口は偽を返すので、返す値の綴りを言い分ける。
    @MainActor
    func lastDrawnScene(at progress: DrawProgress, calledAs call: String) -> Value {
        let value = storage.see(progress).value
        OutsideRun.log.warn(
            call,
            .readLast(
                returning: call == "Scene.justEntered" ? "false" : "the scene that was visible in the last drawn frame"))
        return value
    }

    // MARK: - 場面の持ち主

    /// 場面の持ち主。main actor の上でだけ触る。
    ///
    /// **効くフレームは、頼まれた時点で決まる。** 頼んだときに始まっていた `draw()` の回数 k を控え、回数が
    /// k より大きくなった最初の `draw()` で効く。読むたびに決める作りは、止めている間・読まれないフレーム・
    /// `Task` の中で頼まれたフレームが割れた (#3588)。
    @MainActor
    private final class Storage {
        /// 切り替えが効いた後に変わる、確定した場面。
        private var settled: Value
        /// ``settled`` に入った最初の `draw()` の回数。始まりの場面は 1 (最初の `draw()`)。
        private var settledSince = 1
        /// 頼まれて、まだ確定していない切り替えの行き先。
        private var pending: Value?
        /// ``pending`` を頼んだときに始まっていた `draw()` の回数 k。効くのは k + 1 回目の `draw()` から。
        private var pendingAfter = 0
        /// 最後に見た実行の識別。変わったら新しい実行 (番号の大小では推し量らない)。
        private var run: Int?

        nonisolated init(starting scene: Value) {
            settled = scene
        }

        /// 目盛り `progress` で見える場面と、そこへ入った `draw()` の回数。
        func see(_ progress: DrawProgress) -> (value: Value, since: Int) {
            adopt(progress.run)
            return resolved(at: progress.draws)
        }

        func change(to scene: Value, at progress: DrawProgress) {
            adopt(progress.run)
            // すでに効いている切り替えを確定してから、次の頼みを置く (入った位置を失わない)
            fold(at: progress.draws)
            pending = scene
            pendingAfter = progress.draws
        }

        /// 実行が変わっていれば、新しい実行として確定し直す。頼んでいた切り替えは確定させ、その実行の最初の
        /// `draw()` を入ったフレームにする。
        private func adopt(_ run: Int) {
            defer { self.run = run }
            guard let seen = self.run, seen != run else { return }
            if let pending { settled = pending }
            pending = nil
            settledSince = 1
        }

        private func resolved(at draws: Int) -> (value: Value, since: Int) {
            if let pending, draws > pendingAfter {
                return (pending, pendingAfter + 1)
            }
            return (settled, settledSince)
        }

        /// 効いている切り替えがあれば確定させ、頼みを空にする。
        private func fold(at draws: Int) {
            let now = resolved(at: draws)
            settled = now.value
            settledSince = now.since
            pending = nil
        }
    }
}
