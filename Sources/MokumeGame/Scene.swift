// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics
import Synchronization

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
/// フレームで切り替わる。**
///
/// **描いている最中でない所から呼んだときは、次に描くフレームの頭で効く。** `draw()` が返った後 —
/// OSC・WebSocket の受け取りや、読み込みが終わった `Task` の中 — から ``change(to:)`` を呼ぶと、
/// そのすぐ後に描く最初のフレームから新しい場面になり、そのフレームで ``justEntered`` が真になる。
/// ``SketchPart/noLoop()`` で止めている間も同じで、止めている間のコールバックで呼んだ切り替えは、
/// ``SketchPart/redraw()`` や ``SketchPart/loop()`` で次に描くフレームの頭で効く。それまでのコールバックで
/// 読む ``current`` は、元の場面のまま。
///
/// ## 入った最初のフレーム
///
/// ``justEntered`` は、その場面に入った最初の 1 フレームだけ真になる (``Keyboard/justPressed(_:)``
/// と同じ「その枚だけ真」)。位置やスコアを戻す処理をここに置く。
///
/// - **始まりの場面は最初のフレーム (`frameCount` が 1) から入っていて、そのフレームで真になる。**
/// - ``Sketch/setup()`` の中や、プロパティの初期値のような描く前の所で ``change(to:)`` を呼べば、最初の
///   フレームで効く (``justEntered`` も真)
/// - **同じ場面への ``change(to:)`` も、入り直しとして次のフレームで ``justEntered`` が真になる**
///   (やり直しに使える)
/// - 1 つのフレームの中で ``change(to:)`` を何度か呼べば、最後に呼んだものが効く
/// - `draw()` の途中で `Scene(starting:)` を作った値は、始まりの場面でも ``justEntered`` が立たない
///   (最初のフレームではないため)。入り直すなら ``change(to:)`` を使う
/// - **フレーム番号が戻ったら、新しい実行とみなす。** 同じ `Scene` を別の実行へ持ち越す (`static` に置く・
///   作り直したスケッチへ渡す) と、フレーム番号は 1 から数え直される。読んだ番号が前に読んだ番号より小さければ、
///   頼んでいた切り替えがあればそれを確定させ、その実行の最初のフレームに入ったものとして
///   ``justEntered`` を真にする
///
/// ## 同じ場面を指す
///
/// **`Scene` を代入して渡した先は、同じ場面を指す。** 値を複製しても、場面の持ち主は 1 つ — 部品
/// (`struct Player: SketchPart`) に渡した `Scene` で ``change(to:)`` を呼べば、スケッチが持つ `Scene` が
/// 切り替わる。別の場面を並べて持ちたいときは、`Scene(starting:)` をもう 1 つ作る。
///
/// ## 走っていない所で読む
///
/// ``current`` と ``justEntered`` を、走っているスケッチの外 (`Task` の中・走る前) で読むと、いま描いている
/// フレームが無いので、**最後に描いたフレームで見えていた場面** (まだ 1 枚も描いていなければ始まりの
/// 場面) を返し、``justEntered`` は偽になる。1 度だけ警告する (口の名前 `Scene.current`・`Scene.justEntered`
/// で)。``change(to:)`` はどこから呼んでもよく、警告しない。
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
        current(at: Self.liveFrame, calledAs: "Scene.current")
    }

    /// 今のフレームが、いまの場面に入った最初のフレームか。その 1 フレームだけ真になる。
    ///
    /// 始まりの場面は最初のフレームで真になる (「入った最初のフレーム」)。走っていない所で読むと偽を返し、
    /// 1 度だけ警告する。
    @MainActor
    public var justEntered: Bool {
        justEntered(at: Self.liveFrame, calledAs: "Scene.justEntered")
    }

    /// 次のフレームの頭から `scene` に切り替える。呼んだフレームの ``current`` は元の場面のまま。
    ///
    /// 1 つのフレームの中で何度か呼べば、最後に呼んだものが効く。いまと同じ場面を渡すと、入り直しになる
    /// (次のフレームで ``justEntered`` が真)。`Task` の中など描いている最中でない所から呼んでもよく、次に描く
    /// フレームの頭で効く。
    @MainActor
    public func change(to scene: Value) {
        change(to: scene, at: Self.liveFrame)
    }

    // MARK: - フレーム番号を渡して読む (検査と上の口が使う)

    /// フレーム `frame` の場面。`frame` が `nil` なら走っていない所で、最後に描いたフレームで見えていた場面。
    @MainActor
    func current(at frame: Int?, calledAs call: String = "Scene.current") -> Value {
        guard let frame else {
            SceneNotices.current.warnOutsideRun(call)
            return storage.visibleOutsideRun().value
        }
        return storage.see(frame).value
    }

    @MainActor
    func justEntered(at frame: Int?, calledAs call: String = "Scene.justEntered") -> Bool {
        guard let frame else {
            SceneNotices.current.warnOutsideRun(call)
            return false
        }
        return storage.see(frame).since == frame
    }

    @MainActor
    func change(to scene: Value, at frame: Int?) {
        storage.change(to: scene, at: frame)
    }

    // MARK: - フレーム番号を読む

    /// 走っているスケッチのフレーム番号。走っていなければ `nil` (警告しない)。
    @MainActor
    private static var liveFrame: Int? { FrameReader().runningFrameCount }

    // MARK: - 場面の持ち主

    /// 場面の持ち主。main actor の上でだけ触る。
    @MainActor
    private final class Storage {
        /// 切り替えが効いた後に変わる、確定した場面。
        private var settled: Value
        /// ``settled`` に入った最初のフレーム。始まりの場面は 1 (最初のフレーム)。
        private var settledSince = 1
        /// 頼まれて、まだ確定していない切り替えの行き先。
        private var pending: Value?
        /// ``pending`` を頼んだフレーム。効くのはその次のフレームから。**`nil` は、頼んだときにフレームが
        /// 分からなかった** (描いている最中でない所) — 次に読まれたフレームの頭で効く。
        private var pendingFrame: Int?
        /// 最後に読んだフレーム。フレーム番号が戻ったか (新しい実行か) を見るのと、走っていない所で
        /// 読まれたときに「最後に描いたフレームで見えていた場面」を引くのに使う。
        private var lastSeen: Int?

        nonisolated init(starting scene: Value) {
            settled = scene
        }

        /// フレーム `frame` で見える場面と、そこへ入ったフレーム。読んだ番号を控える。
        func see(_ frame: Int) -> (value: Value, since: Int) {
            observe(frame)
            return resolved(at: frame)
        }

        /// 走っていない所で読まれたときの場面。控えは進めない。
        func visibleOutsideRun() -> (value: Value, since: Int) {
            resolved(at: lastSeen ?? 0)
        }

        func change(to scene: Value, at frame: Int?) {
            if let frame {
                observe(frame)
                fold(at: frame)
                pending = scene
                pendingFrame = frame
            } else {
                // フレームが分からない所から。頼んでいた切り替えが、最後に読んだフレームまでに効いていれば確定してから置く
                if let pendingFrame, let lastSeen, lastSeen > pendingFrame { fold(at: lastSeen) }
                pending = scene
                pendingFrame = nil
            }
        }

        /// `frame` を読んだことを控える。番号が戻っていれば新しい実行とみなす。頼まれたときにフレームが
        /// 分からなかった切り替えには、いまのフレームの頭で効くよう番号を与える。
        private func observe(_ frame: Int) {
            if let lastSeen, frame < lastSeen {
                // 新しい実行。頼んでいた切り替えは確定させ、そのフレームを入ったフレームにする
                if let pending { settled = pending }
                pending = nil
                pendingFrame = nil
                settledSince = max(frame, 1)
            }
            lastSeen = frame
            if pending != nil, pendingFrame == nil {
                pendingFrame = max(frame - 1, 0)
            }
        }

        private func resolved(at frame: Int) -> (value: Value, since: Int) {
            if let pending, let pendingFrame, frame > pendingFrame {
                return (pending, pendingFrame + 1)
            }
            return (settled, settledSince)
        }

        /// 効いている切り替えがあれば確定させ、頼みを空にする。
        private func fold(at frame: Int) {
            let now = resolved(at: frame)
            settled = now.value
            settledSince = now.since
            pending = nil
            pendingFrame = nil
        }
    }
}

/// ``SketchPart/frameCount`` と同じ番号を、警告せずに読むための入れ物。``Scene`` 自体は ``SketchPart`` に
/// 準拠しない — 準拠すると、描く語彙 (`fill`・`circle` など) が ``Scene`` の補完に出る。
private struct FrameReader: SketchPart {}

/// 走っていない所で読んだことの控え。**口の名前ごとに 1 度だけ言う。** 作者の `frameCount` の警告とは
/// 別の鍵で数える (口の名前が違うので、互いに黙らせない)。
nonisolated final class SceneNotices: Sendable {
    /// 検査が自分の控えを差す口。差していなければ ``shared``。
    @TaskLocal static var override: SceneNotices?

    static let shared = SceneNotices()

    static var current: SceneNotices { override ?? shared }

    private let said = Mutex<Set<String>>([])
    private let lines = Mutex<[String]>([])

    /// 言った警告の文面 (検査が読む)。
    var messages: [String] { lines.withLock { $0 } }

    func warnOutsideRun(_ call: String) {
        let first = said.withLock { $0.insert(call).inserted }
        guard first else { return }
        let message =
            "\(call) was read outside a running sketch (in a Task, or before the first frame), "
            + "so it returned the scene that was visible in the last drawn frame"
            + (call == "Scene.justEntered" ? " (justEntered is false there)" : "")
            + ". Read it inside draw() or setup() (said once)"
        lines.withLock { $0.append(message) }
        Diagnostics.warn(message)
    }
}
