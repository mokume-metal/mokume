// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 窓をどう出すか。
///
/// ## なぜ起動の性質で変えるのか
///
/// 見張り (`watch`) は保存のたびに子プロセスを入れ替えるので、**窓は毎回作り直される**。
/// 窓を画面の中央に置き、前面へ持ってくるのは「そのスケッチが初めて立ち上がるとき」の
/// 作法であって、入れ替えは利用者から見れば 1 つのスケッチが走り続けている途中である。
/// 区別せずに毎回やると、1 文字直して保存するたびに窓が中央へ戻り、打っている手から
/// 前面が奪われる ([#679](https://github.com/mokume-metal/mokume/issues/679))。
///
/// ## 合図は既にある
///
/// 「見張りが起こした入れ替えか」は**版の刻印**が既に名乗っている ([SourceStamp])。道具が
/// 渡すもので、新しい合図を作る必要は無い。読むのは一覧が名指しした場所だけなので、
/// ここは**受け取った値で判定する**。
///
/// ## 位置は自分で覚えない
///
/// 覚えて次に復元することは AppKit が持っており、画面構成が変わって画面外になる場合の
/// 扱いもあちらにある。自分で記録を持つと、その判定まで自前で抱えることになる
/// ([ADR-0008](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md)
/// 決定 5 の第 2 段 — 既存ツールが native に持つもので済ませる)。
enum WindowPlacement {
    /// 窓の位置を覚えるときの名前。
    ///
    /// 記憶は実行ファイルごとに分かれるので、名前は 1 つでよい — スケッチが違えば
    /// 別の場所に覚えられる。
    static let autosaveName = "mokume.sketch.window"

    /// プレビューの位置を覚えるときの名前。
    ///
    /// **作品の窓と別にする。** 同じ名前だと互いの位置を上書きし合い、2 枚が重なって
    /// 開く ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 1)。
    static let previewAutosaveName = "mokume.watch.preview"

    /// 見張りが起こした入れ替えか。
    static func isRelaunch(stamp: String?) -> Bool { stamp != nil }

    /// 前面を取ってよいか。**入れ替えでは取らない。**
    static func takesFocus(isRelaunch: Bool) -> Bool { !isRelaunch }

    /// 覚えた位置に立てた窓を返す。**面は載せない。**
    ///
    /// ## 持っている契約は 2 つ
    ///
    /// **閉じたときに窓が自分を解放しないようにする。** 素の `NSWindow` の既定は「閉じたら
    /// 解放する」で、窓を出す 2 つの経路はどちらも強い参照を持ったまま閉じるので、そのままだと
    /// 解放が 1 回余分になる。しかも駆動源は窓ではなく画面に紐づいているので
    /// (``ScreenDisplayLink``)、窓を閉じてもプロセスが消えるまでフレームは回り続け、その間
    /// ずっと消えた先を触る。**症状は原因から遠いところにしか出ない** — 走っている
    /// スケッチでは #714、道具の台では検査の走り終わりでの落下 (signal 11) として出た。
    ///
    /// **覚えている位置があれば、そこへ戻す。** 無いときだけ中央に置き、ずらしを足す。
    /// `setFrameAutosaveName` は**位置を決めた後**に打つ。覚えることも、画面構成が変わって
    /// 画面外になる場合の扱いも AppKit が持っている (上の「位置は自分で覚えない」)。
    ///
    /// ## 面を載せないのはなぜか
    ///
    /// 2 つの経路で違いすぎるからである — 面の大きさの取り方 (設定の半分 / 復元した窓の
    /// `contentLayoutRect`)、入力の繋ぎ方、重ねるもの、delegate、第一応答者、前面の取り方。
    /// 引き受けると引数が 6 つになり、そのうち 1 つは「窓を受け取って面を作る」closure に
    /// なる。畳んでよいのは**割れたときに黙って壊れる**写しだけである
    /// ([ADR-0008](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md)
    /// 決定 6)。
    ///
    /// - Parameters:
    ///   - title: 窓の名前。
    ///   - autosaveName: 位置を覚えるときの名前。
    ///   - defaultSize: 覚えている位置が無いときの大きさ。
    ///   - nudge: 中央に置いたときにずらす量。**覚えた位置へ戻したときは足さない** —
    ///     開くたびにずれていく。
    @MainActor
    static func makeWindow(
        title: String, autosaveName: String, defaultSize: NSSize, nudge: NSSize = .zero
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(autosaveName) {
            window.center()
            if nudge != .zero {
                let origin = window.frame.origin
                window.setFrameOrigin(
                    NSPoint(x: origin.x + nudge.width, y: origin.y + nudge.height))
            }
        }
        window.setFrameAutosaveName(autosaveName)
        return window
    }
}
