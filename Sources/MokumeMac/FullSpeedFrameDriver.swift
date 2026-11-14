// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

/// 画面を持たない全速の駆動 ([#3474])。
///
/// 画面のリフレッシュ (``ScreenDisplayLink``) の代わりに、**main の run loop の 1 回ごとに 1 度だけ**
/// 持ち主を進める。叩く入口は画面の駆動源と同じ (``ScreenDisplayLinkOwner/displayLinkFired(at:)``) で、
/// [ADR-0012] 決定 3 の「同じ入口を別の駆動で叩く」に当たる — 終わりの合図・書き出しの終わりの判定・メニューバーの
/// 表示は、その入口に揃ったまま通る。進む速さを縛るのは描画・符号化・書き込みと書き手の背圧 (``Backpressure``) だけで、
/// 作品が宣言した `frameRate` にも画面のリフレッシュにも縛られない。
///
/// **表示の予定の時刻は渡さない** (`nil`)。画面に出さないので予定が無く、使う側の時計はフレーム番号から
/// 時刻を導く (``Clock/frameIndex(frameRate:)``) ので読まない。
///
/// 使うのは書き出し (`mokume render`) である。持ち主は ``ScreenDisplayLinkOwner`` の入口を持つものなら何でもよく、
/// 書き出し専用の作りにはしていない。
///
/// ## 1 枚ごとに run loop へ戻す
///
/// main actor の上で `for { advance() }` と回す密なループにすると、ループを抜けるまで run loop が回らない。
/// 終わりの合図 (``StopSignals``) を見に来るのは駆動の回の頭で、受けた後の AppKit の終わりの経路
/// (`terminate(_:)` と後始末の見回り) も run loop の上で進むので、Control + C で止められなくなる。
/// メニューバーの表示も出ない ([ADR-0032] 決定 1。run loop を回す人が居ることが、その表示の前提である)。
///
/// ## タイマーで叩く
///
/// run loop は 1 回の中で 1 本のタイマーを高々 1 度しか発火させない (CFRunLoop の振る舞いによる。検査は
/// `FullSpeedFrameDriverTests` が run loop の回数と比べて見る)。間隔 (``stepInterval``) はごく短く、1 枚を
/// 進め終えた時点で次の発火の時刻は過ぎているか目前なので、run loop は待たずに (待っても高々その間隔で)
/// 次の回へ進む — **間隔は速さを縛らず、run loop へ戻る区切りだけを作る。** `.common` に載せるのは、
/// メニューバーの表示のメニューを開いている間も止めないためである (``ScreenDisplayLink`` の予備と同じ)。
///
/// 畳むのは持ち主の仕事である。もう進めるものが無くなったら畳む (書き出しでは ``SketchApplication`` が描き終えた後の
/// 最初の回で畳む)。
///
/// [#3474]: https://github.com/mokume-metal/mokume/issues/3474
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class FullSpeedFrameDriver {
    /// 進める先。**格納された `weak` で持つ** (``ScreenDisplayLink/owner`` と同じ理由・#738)。
    weak var owner: (any ScreenDisplayLinkOwner)?

    /// 発火の間隔 (秒)。**速さの上限ではない** (上の「タイマーで叩く」)。0 を渡すと Foundation が同じ値に
    /// 読み替えるので、読み替えに頼らず書いておく。
    static let stepInterval: TimeInterval = 0.0001

    private var timer: Timer?

    /// 回っているか。**検査が読む** (書き出す経路が繋いだか・描き終えて畳んだか)。
    var isAttached: Bool { timer != nil }

    /// 回し始める。**据え直しでは前のものを畳んでから** — 2 本回ると 1 回の run loop で 2 枚進む。
    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.stepInterval, repeats: true) { [weak self] timer in
            // **自分ごと消えていたら、タイマーを畳む。** 実行ループがタイマーを持つので、畳まないと
            // 誰も進めないまま回り続ける (``ScreenDisplayLink`` の予備と同じ)
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.owner?.displayLinkFired(at: nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 畳む。**何度呼んでもよい。**
    func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    // `deinit { invalidate() }` は置かない (``ScreenDisplayLink`` の末尾と同じ理由)。
}
