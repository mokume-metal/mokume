// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 走り続けているスケッチをメニューバーで名乗る係の口。
///
/// **MokumeCore は OS の UI 部品を知らない** (#3804)。名乗りの本体 (メニューバーの印とメニュー) は外枠の
/// MokumeMac にあり、``SketchRuntime/makePresence`` で差し込まれる。ランタイムはこの口を通して、毎フレームの
/// 経過と、絵を渡している相手を伝えるだけである。
@MainActor
package protocol PresenceAnnouncing: AnyObject {
    /// 名乗っているか。
    var isAnnounced: Bool { get }
    /// 絵を渡している相手 (受け手が名乗った名前)。空でなければ猶予を待たずに名乗る。
    var receivers: [String] { get set }
    /// フレームが 1 つ進んだことを伝える。**毎フレーム呼ばれる。**
    ///
    /// - Parameter elapsed: 最初のフレームからの経過 (秒)。
    func advanced(runningFor elapsed: Double)
}
