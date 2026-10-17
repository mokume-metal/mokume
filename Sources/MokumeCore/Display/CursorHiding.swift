// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 1 つの面が矢印のカーソルを隠すかを決め、OS へ頼む ([#2439])。
///
/// ## 隠すのは、作品の面の上にあるあいだだけ
///
/// 隠すのは、スケッチの要求 (``SketchPart/noCursor()``)・窓が前に出ていること・ポインタが
/// **作品の面そのものの上**にあることの 3 つが揃う間だけである。窓の枠・別の窓・別の画面へ
/// 出せば見える。重ねたつまみ (`KnobOverlay`) の上も面には数えない — つまみは絵の外に立つので
/// (ADR-0030 決定 1)、触るときに矢印が要る。
///
/// 窓の部品 (``SketchSurface``) が状況を観て渡し、決めるのはここ 1 か所である。直に走らせた窓も、
/// 道具の 2 つの窓も同じ部品なので、隠し方の規則は 1 つで済む。OS の呼び出しは差し替えられる口
/// (``System``) で持つので、**判定は窓も OS も使わずに検査で回せる**。
///
/// ## 数の食い違いを作らない
///
/// `NSCursor.hide()` / `unhide()` は**プロセス全体で数える**。カーソルを捕まえる口
/// (``PointerLock``) も同じ数を使うので、重なったときに戻らなくなる・外れなくなるのを防ぐ
/// 約束が要る。ここは**自分が隠した分だけを、対で見せる**: 隠していなければ見せないし、隠したまま
/// 手放されれば見せる。だから次の 2 つが成り立つ ([#2439] の条件 2)。
///
/// - `noCursor()` の後に `requestPointerLock()` → `exitPointerLock()` としても、放した後の矢印は
///   面の上で隠れたまま (こちらの隠しが残る)
/// - 捕まえている間に `cursor()` を呼んでも、捕まえている間の隠しは外れない (こちらの隠しだけが外れる)
///
/// [#2439]: https://github.com/mokume-metal/mokume/issues/2439
@MainActor
final class CursorHiding {
    /// OS への頼み方。**検査から差し替える** — 本番の口のままでは、検査を走らせている人の
    /// カーソルを隠す。
    struct System {
        /// カーソルを隠す。``unhide`` と対で数えられる。
        var hide: @MainActor () -> Void
        /// ``hide`` を 1 回ぶん戻す。
        var unhide: @MainActor () -> Void

        /// 本番の口。**`NSCursor` の数はプロセスで 1 つ** — ``PointerLock`` の隠しも同じ数に積まれる。
        static let appKit = System(hide: { NSCursor.hide() }, unhide: { NSCursor.unhide() })
    }

    /// 面がいまどこに居るか。**窓が答える** — 検査は値を渡す。
    struct Situation: Equatable {
        /// 窓が前に出ていて、キーを受け取っているか。
        var isKeyWindow: Bool
        /// ポインタが作品の面そのものの上にあるか。**重ねたつまみの上は含まない。**
        var pointerIsOverSurface: Bool

        /// 窓が無い・退いている・ポインタが面の外にある状況。
        static let away = Situation(isKeyWindow: false, pointerIsOverSurface: false)
    }

    private let system: System

    /// いま隠しているか。**隠した回数と見せた回数が対になる**ための印で、隠したときに立て、
    /// 見せたときに下ろす。
    private(set) var isHiding = false
    /// スケッチが要求しているか。**最後に渡された値**で、``update(requested:in:)`` が書き換える。
    private(set) var isRequested = false

    init(system: System = .appKit) {
        self.system = system
    }

    /// **手放したら見せる。** 窓が畳まれる通知を逃しても、隠したまま残さない。
    isolated deinit {
        stop()
    }

    /// スケッチの要求と窓の状況を渡し、隠すか見せるかを決める。**毎リフレッシュ呼ばれる。**
    func update(requested: Bool, in situation: Situation) {
        isRequested = requested
        let shouldHide = requested && situation.isKeyWindow && situation.pointerIsOverSurface
        if shouldHide, !isHiding {
            system.hide()
            isHiding = true
        } else if !shouldHide, isHiding {
            stop()
        }
    }

    /// 窓が退いた・畳まれる・移る。**隠していれば見せる。** 要求は残す — 窓が前に戻って
    /// ポインタが面の上に来れば、次のリフレッシュで隠し直す。
    func stop() {
        guard isHiding else { return }
        system.unhide()
        isHiding = false
    }
}
