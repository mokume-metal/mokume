// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import IOKit.pwr_mgt

/// 表示のリフレッシュが止まっても、フレームを進め続けるための判断。
///
/// **判断だけをここに置く。** 実際に叩くのは ``SketchApplication`` と
/// ``SharedFrameStage`` で、どちらも同じ構造 (画面に紐づけた駆動源 1 本) を持つ。
/// 純関数にしてあるのは **GPU 無しで検査できる**ようにするためで、
/// ``FramePresenter/shouldPresent(windowIsVisible:hasPresented:)`` と同じ形である。
///
/// ## なぜ予備の駆動源が要るか
///
/// 駆動源を画面 (`NSScreen`) に紐づけたことで、最小化・被覆・Space の切り替えでは
/// 止まらなくなった ([#223](https://github.com/mokume-metal/mokume/issues/223))。だが
/// **画面そのものがスリープすると、その垂直同期ごと止まる** — 絵も観測も入力も同時に
/// 黙る ([#874](https://github.com/mokume-metal/mokume/issues/874))。
///
/// スリープの通知を購読して切り替える形は採らない。**「何が原因であれ、進んでいなければ
/// 進める」**なら、スリープ以外で駆動源が止まったときにも同じ手当てが効く。
enum FrameDriver {
    /// 予備の駆動源が、この機会に自分で進めるべきか。
    ///
    /// - Parameters:
    ///   - now: いまの時刻 (秒)。
    ///   - lastAdvancedAt: 最後にフレームを進めた時刻。**どちらの駆動源が進めたかは問わない。**
    ///   - stallThreshold: これだけ進んでいなければ「止まっている」とみなす間 (秒)。
    ///   - isAlreadyDriving: 既に予備が進めている最中か。
    ///
    /// **一度引き受けたら、表示のリフレッシュが戻るまで進め続ける** (`isAlreadyDriving`)。
    /// 経過だけで判断すると、自分が進めた直後は必ず「進んでいる」になるので、
    /// 止まっている間のフレームレートが閾値ぶんに落ちる。
    static func shouldAdvanceFromFallback(
        now: Double, lastAdvancedAt: Double, stallThreshold: Double, isAlreadyDriving: Bool
    ) -> Bool {
        isAlreadyDriving || now - lastAdvancedAt >= stallThreshold
    }

    /// 止まっているとみなすまでの間 (秒)。
    ///
    /// **目標フレーム間隔の 4 倍。** 固定値にすると、遅いフレームレートを求めた
    /// スケッチで「1 枚ぶんの間隔」が閾値を越えてしまい、予備が常に割り込む。
    /// 4 倍は 60 fps のとき 0.066 秒で、``SketchRuntime`` が名乗りの側で使っている
    /// 停滞の判定と同じ水準になる。
    static func stallThreshold(frameRate: Int) -> Double {
        4 / Double(max(1, frameRate))
    }

    /// 予備の駆動源を回す間隔 (秒)。**目標フレーム間隔そのもの。**
    ///
    /// 表示のリフレッシュが生きている間は空振りするだけなので、細かく回してよい。
    /// 止まっている間はこの間隔がそのままフレームレートになるので、粗くすると
    /// [ADR-0012](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md)
    /// 決定 5 (画面に出ていなくてもフレームレートを維持する) を満たせない。
    static func fallbackInterval(frameRate: Int) -> Double {
        1 / Double(max(1, frameRate))
    }
}

/// ディスプレイが勝手に消えるのを断る。
///
/// **消えると絵が止まる**からである ([#874](https://github.com/mokume-metal/mokume/issues/874))。
/// macOS のディスプレイスリープは「利用者のアイドル」で起きるが、そこで言う活動は
/// キーボード・マウス・トラックパッドであって、**カメラや距離センサー、OSC、シリアル
/// から届く入力は活動として数えられない**。人が作品の前で手をかざしていても、
/// キーボードを触らなければ画面は消える。
///
/// **窓を出しているときだけ取る。** 書き出しや観測だけの実行 (窓を持たない) は画面を
/// 使わないので、断る理由が無い。
@MainActor
final class DisplaySleepBlock {
    private var assertion: IOPMAssertionID = 0
    private var isHeld = false

    /// 断りを立てる。**立てられなくても走り続ける** — これは保証ではなく手当てで、
    /// 外部ディスプレイの電源を切る・蓋を閉じるといった経路は元より断れない。
    /// 止まったときに拾うのは予備の駆動源 (``FrameDriver``) の仕事である。
    init(reason: String) {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        if result == kIOReturnSuccess {
            assertion = id
            isHeld = true
        }
    }

    /// 断りを返す。**返し忘れると、プロセスが終わるまで画面が消えなくなる。**
    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertion)
        isHeld = false
    }
}
