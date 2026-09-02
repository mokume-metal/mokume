// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
}
