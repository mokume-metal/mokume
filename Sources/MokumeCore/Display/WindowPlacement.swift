// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeDiagnostics

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

    // MARK: - 開く大きさの指定 (#1624)

    /// 開く大きさの指定を覚えるときの鍵。**位置を覚える名前から導く。**
    ///
    /// 名前ごとに導くので、窓が違えば指定も別に覚える (作品の窓とプレビュー)。覚える名前を
    /// 後から分けても (画面ごと・同じ実行ファイルの何本目か — [#2020]) 指定はそれに付いて
    /// 分かれ、こちらは何も変えなくてよい。
    ///
    /// **位置の記憶 (`NSWindow Frame <名前>`) とは別の鍵に置く。** 指定を名前に混ぜて
    /// 覚え分ける形にすると、名前は「どの窓か」と「どの大きさを頼まれたか」の 2 つを背負い、
    /// #2020 が名前を分けるときに綴りの組み方まで決め直すことになる。
    ///
    /// [#2020]: https://github.com/mokume-metal/mokume/issues/2020
    static func requestKey(for autosaveName: String) -> String { "\(autosaveName).requestedSize" }

    /// 描く大きさ (画素) と倍率 (``SketchSettings/windowScale``) から、開く大きさ (点)。
    static func requestedSize(width: Int, height: Int, scale: Float) -> NSSize {
        NSSize(width: CGFloat(width) * CGFloat(scale), height: CGFloat(height) * CGFloat(scale))
    }

    /// 枠に収まるまで、**縦横比を保って**縮める。収まっていればそのまま返す。
    ///
    /// 縦横比を崩して収めると、絵は引き伸ばされずに帯が付く
    /// (``ViewportFit``) — 頼んだ形とも違う窓になるので、相似のまま縮める。
    static func fitted(_ size: NSSize, within bounds: NSSize) -> NSSize {
        guard size.width > bounds.width || size.height > bounds.height,
            bounds.width > 0, bounds.height > 0
        else { return size }
        let ratio = min(bounds.width / size.width, bounds.height / size.height)
        return NSSize(width: (size.width * ratio).rounded(.down), height: (size.height * ratio).rounded(.down))
    }

    /// 開く大きさの指定が、覚えている指定と違うか。**違えば新しい指定を覚え直す。**
    ///
    /// 覚えている指定が無いとき (初めて開く・指定を覚える前の版で開いていた) も「違う」と
    /// 答える。前の版が覚えた大きさは、どの指定で開いたものか分からないからである。
    static func takesNewRequest(
        _ requested: NSSize, autosaveName: String, defaults: UserDefaults
    ) -> Bool {
        let key = requestKey(for: autosaveName)
        let spelled = NSStringFromSize(requested)
        guard defaults.string(forKey: key) != spelled else { return false }
        defaults.set(spelled, forKey: key)
        return true
    }

    /// 開く大きさの指定を窓へ当てる。**指定が前と変わっていたときだけ**、覚えていた大きさと
    /// 位置を捨てて、指定の大きさで中央へ置き直す (``centred(_:in:)`` — プレビューが
    /// その位置を計算で辿れるように、ちょうど中央に置く)。
    ///
    /// ## なぜ変わったときだけか
    ///
    /// 毎回当てると、手で広げた大きさが開くたびに戻る。見張りの下では保存のたびに当たるので
    /// (作品の窓)、[#679] が直した「保存のたびに窓が戻る」がそのまま帰ってくる。逆に一度も
    /// 当てないと、覚えた大きさが指定に勝ち、指定を変えても前の窓の大きさで開く
    /// ([#1624] — 320x240 から 1920x1080 へ変えても 160x152 点のまま開いた)。
    ///
    /// ## 全画面の間は当てない
    ///
    /// 見張りから本番を回している窓は全画面のことがあり、保存で全画面が外れてはならない
    /// ([ADR-0032] 決定 1)。指定も覚え直さないので、全画面を抜けた後に開いたときに当たる。
    ///
    /// ## 画面に収まらなければ縮める
    ///
    /// 縦横比を保って、窓のある画面の使える範囲へ収める (``fitted(_:within:)``)。値は断らない
    /// — 同じスケッチでも画面が大きければ頼んだとおりに開く。縮めたことは 1 行言う。
    ///
    /// - Parameters:
    ///   - requested: 開く大きさの指定 (点)。
    ///   - window: 当てる窓。
    ///   - autosaveName: 窓の位置を覚えている名前 (``requestKey(for:)`` の元)。
    ///   - defaults: 指定を覚える先。**検査から差し替える。**
    ///   - warn: 縮めたことを言う口。**検査から差し替える。**
    /// - Returns: 当てたか。
    ///
    /// [#679]: https://github.com/mokume-metal/mokume/issues/679
    /// [#1624]: https://github.com/mokume-metal/mokume/issues/1624
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @MainActor
    @discardableResult
    static func honour(
        _ requested: NSSize, in window: NSWindow, autosaveName: String,
        defaults: UserDefaults = .standard,
        warn: (String) -> Void = { Diagnostics.warn($0) }
    ) -> Bool {
        guard !window.styleMask.contains(.fullScreen),
            takesNewRequest(requested, autosaveName: autosaveName, defaults: defaults)
        else { return false }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            // 画面の無い実行環境。縮める先も中央も無いので、大きさだけ当てる
            window.setContentSize(requested)
            return true
        }
        let size = fitted(requested, within: window.contentRect(forFrameRect: visible).size)
        if size != requested {
            warn(
                "The window asked for \(Int(requested.width))×\(Int(requested.height)) points, "
                    + "more than the screen holds — opening it at "
                    + "\(Int(size.width))×\(Int(size.height)) instead (windowScale)")
        }
        window.setContentSize(size)
        window.setFrameOrigin(centred(window.frame.size, in: visible))
        return true
    }

    // MARK: - プレビューを作品の窓の下へ (#1624)

    /// プレビューと作品の窓の間に足す量 (点)。窓枠 (題名の帯) と隙間のぶん。
    static let previewGap: CGFloat = 44

    /// 中央に置いた作品の窓の真下へプレビューを出すには、同じく中央に置いたプレビューを
    /// どれだけずらすか。**2 枚の丈から決める。**
    ///
    /// かつては「2 枚が同じ丈 (480x270) で中央に出る」ことを前提に、プレビューの丈だけから
    /// 決めていた。作品の窓が描く大きさ × 倍率で開くようになったので (``honour(_:in:autosaveName:defaults:warn:)``)、
    /// 作品の窓が高いスケッチでは 2 枚が重なる。既定の 480x270 どうしなら、これまでと同じ
    /// 量 (`-(270 + 44)`) になる。
    ///
    /// - Parameters:
    ///   - artworkHeight: 作品の窓の中身の丈。
    ///   - previewHeight: プレビューの中身の丈。
    static func nudgeBelow(artworkHeight: CGFloat, previewHeight: CGFloat) -> NSSize {
        NSSize(width: 0, height: -((artworkHeight + previewHeight) / 2 + previewGap))
    }

    /// 枠の大きさの窓を、使える範囲のちょうど中央に置くときの原点。
    ///
    /// **`NSWindow.center()` を使わない。** あちらは「中央よりやや上」で、どれだけ上かは
    /// 文書に無い。作品の窓とプレビューは別の窓 (別の台) なので、プレビューが作品の窓の
    /// 位置を計算で知るには、置き方が式で書けている必要がある。
    static func centred(_ frameSize: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(
            x: (visible.midX - frameSize.width / 2).rounded(.down),
            y: (visible.midY - frameSize.height / 2).rounded(.down))
    }

    /// 作品の窓が頼まれた大きさで中央に置き直されたとき、**プレビューをその真下へ置き直す。**
    ///
    /// 作品の窓とプレビューは同じ区画を独立に見る兄弟で、互いの窓を知らない
    /// (``SharedFramePreview`` の「作品の窓の子ではない」)。そこで作品の窓が置き直される条件
    /// (``honour(_:in:autosaveName:defaults:warn:)`` — 指定が変わったとき) を、プレビューも
    /// 自分の名前で同じ指定を覚えて辿る。作品の窓の大きさは、同じ画面へ同じ縮め方
    /// (``fitted(_:within:)``) を当てて求める。
    ///
    /// **プレビューの大きさは変えない。** 動かすのは位置だけで、指定が変わらなければ
    /// 手で動かした位置が残る。
    ///
    /// - Parameters:
    ///   - requestedArtwork: 作品の窓が頼まれた大きさ (描く大きさ × 倍率)。
    ///   - window: プレビューの窓。
    ///   - autosaveName: プレビューの位置を覚えている名前。
    ///   - defaults: 指定を覚える先。**検査から差し替える。**
    /// - Returns: 置き直したか。
    @MainActor
    @discardableResult
    static func placeBeneathArtwork(
        _ requestedArtwork: NSSize, window: NSWindow, autosaveName: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !window.styleMask.contains(.fullScreen),
            takesNewRequest(requestedArtwork, autosaveName: autosaveName, defaults: defaults),
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return false }
        // 作品の窓も同じ形の枠 (``makeWindow``) なので、中身の範囲は自分の窓から求めてよい
        let artwork = fitted(
            requestedArtwork, within: window.contentRect(forFrameRect: visible).size)
        let origin = centred(window.frame.size, in: visible)
        let nudge = nudgeBelow(
            artworkHeight: artwork.height, previewHeight: window.contentLayoutRect.height)
        window.setFrameOrigin(NSPoint(x: origin.x + nudge.width, y: origin.y + nudge.height))
        return true
    }

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
