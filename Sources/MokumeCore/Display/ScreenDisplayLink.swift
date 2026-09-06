// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import QuartzCore

/// 表示のリフレッシュを受け取る側。
///
/// **`CADisplayLink` が渡してくる仕掛けは渡さない。** 持ち主は 2 つあるが (走っている
/// スケッチと、別のプロセスの絵を出す台)、どちらも受け取った仕掛けを使っていない。
/// 要る日が来たら足す ([ADR-0001] 原則 4)。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
@MainActor
protocol ScreenDisplayLinkOwner: AnyObject {
    /// リフレッシュが来た。
    func displayLinkFired()
}

/// フレームの駆動源を**画面**のリフレッシュに紐づけ、窓が移った先へ張り替える。
///
/// ## なぜ面ではなく画面から取るのか
///
/// 面 (`NSView`) から取った駆動源は、面が hidden になると呼ばれなくなる — AppKit の
/// ヘッダが `NSView` の側にだけ「If the view is hidden, or not on any display, the
/// callback will not be invoked」と書いている。窓を最小化すると面は hidden になるので、
/// フレームループごと止まり、絵だけでなく観測も入力も応答しなくなっていた
/// ([#223](https://github.com/mokume-metal/mokume/issues/223))。
///
/// 画面 (`NSScreen`) に紐づければ、最小化・被覆・Space の切り替えのどれでも止まらない。
/// **最小化を特別扱いする経路も、時間で叩く 2 本目の駆動源も要らない** — どれも「駆動源を
/// どこに紐づけるか」1 つの問題だった (ADR-0012 決定 3 の「表示のリフレッシュはその駆動源
/// の 1 つ」はそのまま)。
///
/// ## なぜ 1 つの部品にしたのか
///
/// 窓を出す経路は 2 つある。**張り替えの判定は逐語同文だったのに、理由は片方にしか
/// 書かれていなかった** — 「最小化でも同じ通知が飛び、そのとき `window.screen` は `nil` を
/// 返す」という契約が一方の doc にしか無く、もう一方では冗長な二重 guard にしか見えない。
/// 読める側を「整理」した日に、**道具の窓を最小化すると駆動源が消えて二度と戻らない** —
/// 症状は「固まった」だけで、原因からは遠い
/// ([#956](https://github.com/mokume-metal/mokume/issues/956))。
///
/// 仕掛けと紐づけた画面も、**必ず対で書き換えなければならない 2 つ**である。片方を
/// 落とすと張り替えが黙って止まる。
@MainActor
final class ScreenDisplayLink: NSObject {
    /// 進める先。
    ///
    /// **格納された `weak` で持つ。** `CADisplayLink` は自分の target を強く持ち、走らせる
    /// 実行ループがその仕掛けを持つので、持ち主が自分で仕掛けを持つと環になる — 手放した
    /// 持ち主が永久に解放されず、しかもリフレッシュのたびに回り続ける
    /// ([#738](https://github.com/mokume-metal/mokume/issues/738))。
    ///
    /// クロージャの `[weak self]` に逃がさないのは、**書き落とせる形にしないため**である。
    /// 格納された `weak` なら、繋ぐ側がどう書いても弱いままになる。
    weak var owner: (any ScreenDisplayLinkOwner)?

    /// 求めるフレームレート。**`nil` なら画面に任せる。**
    ///
    /// 据えるのは絵を作っている側だけである。画面が 120 Hz なら 120 回呼ばれてしまい、
    /// スケッチが求めた速さが無視されるので、求めた値を上限にも下限にも据えて画面の性能に
    /// 引きずられないようにする。
    ///
    /// 別のプロセスの絵を出す台は据えない — こちらは絵を作っていないので、差し出し元より
    /// 速く回っても出す枚数は増えない (同じ枚数なら出さない)。画面の速さに任せるほうが、
    /// 相手が何 fps でも遅れが最小になる。
    private let frameRate: Float?

    private var link: CADisplayLink?
    /// 紐づけている画面。張り替えの要否をこれで判断する。
    private var linkedScreen: NSScreen?

    /// - Parameter frameRate: 求める速さ。省くと画面のリフレッシュに任せる。
    init(frameRate: Float? = nil) {
        self.frameRate = frameRate
        super.init()
    }

    /// 画面に紐づけ、窓が移ったら追う。
    ///
    /// **窓を渡さない呼び方を許す。** 外のプロセスへ差し出す経路は窓を持たないまま駆動源
    /// だけを回すので、追う対象が無い。
    ///
    /// - Parameters:
    ///   - screen: 紐づける画面。`nil` なら何もしない (画面が 1 枚も無い実行がある)。
    ///   - window: 移動を追う窓。
    func attach(to screen: NSScreen?, following window: NSWindow? = nil) {
        // 二重に登録すると 1 回の移動で 2 度張り替える。張り直す前に必ず外す
        stopFollowing()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowChangedScreen(_:)),
                name: NSWindow.didChangeScreenNotification, object: window)
        }
        bind(to: screen)
    }

    /// 駆動源を畳み、窓を追うのもやめる。**何度呼んでもよい。**
    func invalidate() {
        stopFollowing()
        link?.invalidate()
        link = nil
        linkedScreen = nil
    }

    /// 窓が別の画面へ移ったら張り替える。
    ///
    /// 画面ごとにリフレッシュ率が違うので、移った先に付け替えないと駆動が噛み合わない。
    ///
    /// **窓がどの画面にも乗っていないときは触らない。** 最小化でも同じ通知が飛び、その
    /// とき `window.screen` は `nil` を返す — 素直に張り替えると、直そうとした最小化で
    /// こそ駆動源を失う。
    ///
    /// **窓は通知から取る。** 自分で持つと、持ち主を手放しても窓だけが生き残る — 環を
    /// 見張っている検査は持ち主しか見ないので、その漏れは素通りする。`object:` を指定して
    /// 登録している以上、届く通知の `object` はその窓そのものである。
    @objc private func windowChangedScreen(_ notification: Notification) {
        guard let screen = (notification.object as? NSWindow)?.screen,
            screen !== linkedScreen
        else { return }
        bind(to: screen)
    }

    private func bind(to screen: NSScreen?) {
        guard let screen else { return }
        link?.invalidate()

        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        if let frameRate {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: frameRate, maximum: frameRate, preferred: frameRate)
        }
        link.add(to: .main, forMode: .common)

        self.link = link
        linkedScreen = screen
    }

    /// **名指しで外す。** 自分が登録したのはこの 1 本だけなので、種別で指定すれば足りる —
    /// `removeObserver(self)` のように全部外す書き方をすると、通知を 1 本足した日に
    /// 意図しないほうまで外れる。
    private func stopFollowing() {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeScreenNotification, object: nil)
    }

    @objc private func step(_ link: CADisplayLink) {
        owner?.displayLinkFired()
    }

    // `deinit { invalidate() }` は置かない。実行ループが仕掛けを持っている間 `deinit` は
    // 走らないので効かず、Swift 6 の nonisolated な `deinit` からは AppKit を触れない。
    // 畳むのは持ち主の後始末の仕事である。
}
