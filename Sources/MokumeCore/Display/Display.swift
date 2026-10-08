// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 繋がっているディスプレイ 1 枚。``Sketch/displays`` が番号順に並べ、
/// ``SketchSettings/fullScreen(_:)`` が番号で選ぶ。
///
/// ## 番号の振り方
///
/// **1 はメニューバーのある画面。2 から先は、配置の左から** (システム設定 › ディスプレイ で
/// 並べた位置。左端が揃っていれば上から)。手本 (Processing の `fullScreen(display)`) と同じく
/// 1 から数える。
///
/// 繋いだ順では振らない。macOS は配置をディスプレイごとに覚えて戻すので、**同じ顔ぶれなら、
/// 抜き差しの順によらず同じ番号になる。** 代わりに、**間の 1 台が欠けると後ろの番号が 1 つずつ
/// 詰まる** — 画面ごとに 1 本ずつ起こす展示では、欠けた 1 台に出すはずの作品が隣の画面へ出うる。
/// 数や名前を確かめてから選ぶ形は ``SketchSettings/fullScreen(_:)`` の例にある。
///
/// ## 大きさ
///
/// ``width`` と ``height`` は、**そのディスプレイで全画面にしたときに描く大きさ** (画素) で
/// ある。画面の点に画素密度 (Retina なら 2) を掛けた数なので、描いた 1 画素が画面の 1 画素に
/// 載る。カメラの切り欠きのある画面では、macOS が全画面の窓をメニューバーの帯の下に置くので、
/// その帯のぶん低い。
///
/// **隔離しない値である** — 起動の失敗 (``RenderFailure/displayNotConnected(_:connected:)``) が
/// いまの一覧を運び、そちらはどこからでも読まれる。
public nonisolated struct Display: Equatable, Sendable, CustomStringConvertible {
    /// 番号。1 から数える (上の「番号の振り方」)。
    public let number: Int
    /// OS が名乗る名前 (`Built-in Retina Display` など)。**同じ型番の機材は同じ名前になる。**
    public let name: String
    /// 全画面にしたときに描く幅 (画素)。
    public let width: Int
    /// 全画面にしたときに描く高さ (画素)。
    public let height: Int
    /// OS がこのディスプレイに振った番号 (`CGDirectDisplayID`)。窓を出すときに、画面を
    /// 引き直す鍵にする (`screen(for:among:)`)。**面には出さない** — 選ぶ形は番号の 1 本である。
    let screenID: UInt32

    /// `2: DELL U2720Q (3840×2160)` の形。
    public var description: String { "\(number): \(name) (\(width)×\(height))" }
}

// MARK: - 一覧の組み方 (#2020)

extension Display {
    /// OS が名乗る画面 1 枚の読み。``readings(of:)`` が `NSScreen` から写す。
    ///
    /// **検査はこれを直に組む。** 一覧の番号の振り方・全画面の大きさ・選び方は、この読みから
    /// 先がすべて純粋な関数なので、ディスプレイが 1 枚の機械でも、何枚・どんな配置でも確かめ
    /// られる (ADR-0041 決定 2 の基準 4)。
    struct Reading: Equatable, Sendable {
        /// OS が振った番号 (`CGDirectDisplayID`)。
        var screenID: UInt32
        /// OS が名乗る名前。
        var name: String
        /// 画面の枠 (点・全画面の座標。原点はメニューバーのある画面の左下)。
        var frame: CGRect
        /// 使える範囲 (点)。メニューバーと Dock の帯を除いたもの。
        var visibleFrame: CGRect
        /// 上の縁でカメラの切り欠きにかかる丈 (点)。切り欠きの無い画面では 0。
        var cameraHousing: CGFloat
        /// 1 点あたりの画素。
        var scale: CGFloat
    }

    /// 全画面にした窓の中身の大きさ (点)。
    ///
    /// **切り欠きの無い画面では枠そのもの** — メニューバーは全画面の間は隠れる。
    ///
    /// **切り欠きのある画面では、メニューバーの帯の下まで。** macOS は全画面の窓を切り欠きの
    /// 下に置く。実測 (#2020・1800×1169 点の内蔵画面・メニューバーを隠さない既定の設定) では
    /// 全画面の窓は 1800×1130 点で、切り欠きの丈 (38) ではなく、使える範囲の上端 (1130 —
    /// メニューバーの帯と、その下の 1 点の線を除いた所) で止まった。メニューバーを常に隠す設定
    /// では使える範囲が上まで伸びるので、切り欠きの丈の下で抑える。そちらは測っていない —
    /// 食い違えば、窓を出す側が全画面に入った後に言う (`WindowPlacement.fullScreenMismatch`)。
    static func fullScreenPoints(of reading: Reading) -> CGSize {
        guard reading.cameraHousing > 0 else { return reading.frame.size }
        let top = min(reading.visibleFrame.maxY, reading.frame.maxY - reading.cameraHousing)
        return CGSize(width: reading.frame.width, height: top - reading.frame.minY)
    }

    /// 読みから一覧を組む。**先頭の読みがメニューバーのある画面**で、番号 1 になる
    /// (`NSScreen.screens` がそう並べる)。残りは配置の左から、左端が揃えば上から振る。
    ///
    /// **読みの並び (繋いだ順) は番号に効かない。** 配置まで同じなら、OS が残りをどんな順で
    /// 並べても同じ番号になる。配置も揃っている (重なっている) ものは OS の番号の順に置き、
    /// 並びが揺れないようにする。
    static func list(from readings: [Reading]) -> [Display] {
        guard let primary = readings.first else { return [] }
        let others = readings.dropFirst().sorted { left, right in
            if left.frame.minX != right.frame.minX { return left.frame.minX < right.frame.minX }
            if left.frame.maxY != right.frame.maxY { return left.frame.maxY > right.frame.maxY }
            return left.screenID < right.screenID
        }
        return ([primary] + others).enumerated().map { index, reading in
            let points = fullScreenPoints(of: reading)
            return Display(
                number: index + 1, name: reading.name,
                width: Int((points.width * reading.scale).rounded()),
                height: Int((points.height * reading.scale).rounded()),
                screenID: reading.screenID)
        }
    }

    /// 番号で 1 枚選ぶ。
    ///
    /// **見つからなければ型のついたエラーで断り、別の画面へは倒さない** ([ADR-0020] 決定 5 の
    /// 2 行目 — 起動の組み立てで呼ばれる)。展示でプロジェクタへ出すつもりの作品が、黙って手元の
    /// 画面を全画面で塞ぐことになるからである。窓で開くほうへ倒したい作品は、``Sketch/displays``
    /// を読んで自分で選ぶ。
    ///
    /// - 1 を割る番号は ``RenderFailure/invalidDisplay(_:)`` (頼み方の誤り)
    /// - 一覧に無い番号は ``RenderFailure/displayNotConnected(_:connected:)`` (いまの一覧を添える)
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    static func choose(_ number: Int, from displays: [Display]) throws(RenderFailure) -> Display {
        guard number >= 1 else { throw .invalidDisplay(number) }
        guard let display = displays.first(where: { $0.number == number }) else {
            throw .displayNotConnected(number, connected: displays)
        }
        return display
    }

    /// 画面の読み。**既定はいま繋がっている画面。**
    static func readings(of screens: [NSScreen] = NSScreen.screens) -> [Reading] {
        screens.map { screen in
            Reading(
                screenID: screen.screenID, name: screen.localizedName, frame: screen.frame,
                visibleFrame: screen.visibleFrame, cameraHousing: screen.safeAreaInsets.top,
                scale: screen.backingScaleFactor)
        }
    }

    /// いま繋がっているディスプレイ。**決して落ちない** — 画面の無い実行環境では空。
    static var connected: [Display] { list(from: readings()) }

    /// このディスプレイの画面を、繋がっている中から引く。外れていれば `nil`。
    static func screen(for display: Display, among screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first { $0.screenID == display.screenID }
    }
}

extension NSScreen {
    /// OS がこの画面に振った番号 (`CGDirectDisplayID`)。読めなければ 0。
    var screenID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension Sketch {
    /// いま繋がっているディスプレイ。番号 (``Display/number``) の順に並ぶ。
    ///
    /// ```swift
    /// for display in displays { print(display) }   // 1: Built-in Retina Display (3600×2260) …
    /// ```
    ///
    /// **読むたびにいまの顔ぶれを返し、決して落ちない** — 画面の無い実行環境では空になる。
    /// ``Sketch/settings`` の中から読めるので、繋がっているかどうかで開き方を選べる
    /// (``SketchSettings/fullScreen(_:)`` の例)。走っている間に抜き差しすれば、次に読んだときの
    /// 一覧が変わる。描く大きさと全画面にした画面は、起動のときに決まったまま変わらない。
    public var displays: [Display] { Display.connected }
}
