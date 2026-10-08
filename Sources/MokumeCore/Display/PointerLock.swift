// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import MokumeDiagnostics

/// 1 つの面がカーソルを捕まえるかを決め、OS へ頼む ([#1144])。
///
/// ## 判定をここに集める
///
/// 捕まえるかどうかは、スケッチの要求・面が押されたか・窓が前に出ているか・ポインタが面の
/// 上にあるか の 4 つで決まり、外れ方は 4 通りある (``Sketch/requestPointerLock()`` の説明)。
/// **窓の部品 (``SketchSurface``) はそれを観て伝えるだけ**で、決めるのはここ 1 か所である。
/// 直に走らせた窓も、道具の 2 つの窓も同じ部品なので、捕まえ方の規則は 1 つで済む。
///
/// OS の呼び出しは差し替えられる口 (``System``) で持つ。**判定は窓も OS も使わずに検査で
/// 回せ**、実際にカーソルを奪うのは本番の口だけである。
///
/// ## 押しを受けた印
///
/// 捕まえるのは、**前に外れてから (または作ってから) 面が押しを受けた後**だけである。
/// 押していないのに捕まえると、見ていない間にカーソルが消える (手本のブラウザも捕まえる前に
/// 押しを求める)。外れたら — Escape でも、窓が退いても、要求が消えても — 印を下ろす。
/// だから `draw()` から毎フレーム要求し続けるスケッチでも、Escape の後は押すまで掛け直さない。
///
/// ## プロセスで 1 つ
///
/// 道具は作品の窓とプレビューの 2 つを出す。捕まえるのは前に出ている窓だけなので普通は
/// 重ならないが、窓が入れ替わる通知の順に頼らず、**持ち手 (``Arbiter``) を 1 つにして構造で
/// 守る** — 別の面が捕まえるときは、持っていた面が利用者に外されたものとして先に放す。
/// カーソルの隠し方 (`NSCursor.hide()`) も切り離し方もプロセス全体に効くので、2 つが重なると
/// 片方を放しただけでは戻らない。
///
/// [#1144]: https://github.com/mokume-metal/mokume/issues/1144
@MainActor
final class PointerLock {
    /// OS への頼み方。**検査から差し替える** — 本番の口のままでは、検査を走らせている人の
    /// カーソルを奪う。
    struct System {
        /// カーソルを隠し、手の動きから切り離す。**できなければ何も残さず `false`。**
        var capture: @MainActor () -> Bool
        /// 繋ぎ直し、見せる。``capture`` が `true` を返した回とだけ対になって呼ばれる。
        var release: @MainActor () -> Void

        /// 本番の口。切り離している間 (`CGAssociateMouseAndMouseCursorPosition(false)`) も、
        /// 手を動かした量は移動の出来事の `deltaX` / `deltaY` に載って届く。
        ///
        /// **隠すのは切り離せた後。** 隠すのは数を数える仕組み (`hide` と `unhide` の対) なので、
        /// 切り離せずに隠したままにすると、こちらからは見せ直す回が来ない。
        static let appKit = System(
            capture: {
                guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { return false }
                NSCursor.hide()
                return true
            },
            release: {
                CGAssociateMouseAndMouseCursorPosition(1)
                NSCursor.unhide()
            })
    }

    /// プロセスで捕まえている面を 1 つに絞る持ち手。
    final class Arbiter {
        /// いま捕まえている面。
        fileprivate weak var holder: PointerLock?

        /// 本番の持ち手。**検査は自分の持ち手を作って渡す** — 共有すると、別の検査が残した
        /// 面を放しに行く。
        static let process = Arbiter()

        init() {}
    }

    /// 面がいまどこに居るか。**窓が答える** — 検査は値を渡す。
    struct Situation: Equatable {
        /// 窓が前に出ていて、キーを受け取っているか。
        var isKeyWindow: Bool
        /// ポインタが面の上にあるか。外で捕まえると、隠れたまま移動が届かない (押していない間の
        /// 移動を届けるトラッキング領域は面の上でしか効かない)。
        var pointerIsInside: Bool
    }

    private let system: System
    private let arbiter: Arbiter

    /// いま捕まえているか。
    private(set) var isLocked = false
    /// スケッチが要求しているか。**最後に渡された値**で、``update(requested:in:)`` が書き換える。
    private(set) var isRequested = false
    /// 前に外れてから (または作ってから)、面が押しを受けたか。
    private(set) var hasPress = false

    init(system: System = .appKit, arbiter: Arbiter = .process) {
        self.system = system
        self.arbiter = arbiter
    }

    /// **手放したら放す。** 窓が畳まれる通知を逃しても、カーソルを切り離したまま残さない。
    isolated deinit {
        release()
    }

    /// スケッチの要求を渡し、捕まえ直すか放すかを決める。**毎リフレッシュ呼ばれる。**
    ///
    /// 要求が消えた (``Sketch/exitPointerLock()``) なら放す。窓が退いていたら、利用者に外された
    /// ものとして放す — 退いた知らせ (``releaseByUser()``) を取りこぼした回の備えである。
    func update(requested: Bool, in situation: Situation) {
        isRequested = requested
        if isLocked, !requested { end() }
        if isLocked, !situation.isKeyWindow { releaseByUser() }
        settle(situation)
    }

    /// 面が押された。**面そのものへの押しだけを渡す** — 重ねたつまみへの押しは数えない。
    ///
    /// 要求が既に出ていれば、この押しで捕まえる (`mouseClicked()` の中で要求する書き方では、
    /// 次のリフレッシュの ``update(requested:in:)`` で捕まえる)。
    func notePress(in situation: Situation) {
        hasPress = true
        settle(situation)
    }

    /// 利用者が外した (Escape・窓が退いた)。**捕まえていなければ何もしない。**
    ///
    /// 要求は残す。押しを受けた印を下ろすので、もう一度押すまで掛け直さない。
    func releaseByUser() {
        guard isLocked else { return }
        end()
    }

    /// 窓が畳まれる・終わる。**捕まえていれば放す。**
    func tearDown() {
        end()
    }

    /// 掛けられるなら掛ける。
    private func settle(_ situation: Situation) {
        guard !isLocked, isRequested, hasPress, situation.isKeyWindow, situation.pointerIsInside
        else { return }
        // **別の面が持っていれば先に放す** — カーソルの隠し方は数で効くので、重ねると戻らない
        if let other = arbiter.holder, other !== self { other.releaseByUser() }
        guard system.capture() else {
            // 押し直すまで試し直さない。毎リフレッシュ失敗して言い続けることになる
            hasPress = false
            Diagnostics.warn("Could not capture the pointer — press the sketch to try again")
            return
        }
        isLocked = true
        arbiter.holder = self
    }

    /// 外れる。**外れ方によらず、押しを受けた印を下ろす。**
    private func end() {
        release()
        hasPress = false
    }

    /// 捕まえていれば放す。
    private func release() {
        guard isLocked else { return }
        system.release()
        isLocked = false
        if arbiter.holder === self { arbiter.holder = nil }
    }
}
