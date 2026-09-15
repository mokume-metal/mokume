// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 直近の作り直しの結果。
///
/// 観測 ([ADR-0018]) と同じ流儀で `.mokume/build/` に書く — 別の置き場も別の形も
/// 作らず、区画をもう 1 つ足すだけにする。窓口はこれを読むだけでよくなる。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
struct BuildReport: Encodable, Equatable {
    /// 面の版。
    ///
    /// **格納プロパティで持つ。** `CodingKeys` と手書きの `encode(to:)` で注入していた頃は、
    /// フィールドを 1 つ足すたびに宣言・鍵・書き出しの 3 箇所を手で合わせることになって
    /// いた ([#814](https://github.com/mokume-metal/mokume/issues/814))。`ParamStore.Saved`
    /// が既にこの形で、**同じリポジトリに流儀が 2 つ並んでいた**。
    ///
    /// 出力は変わらない — 合成された `encode(to:)` は宣言順に書き、`Optional` には
    /// `encodeIfPresent` を使う (同じ形の ``Timings`` が既に合成で通っている)。
    /// 既定値のある `let` はメンバーワイズの初期化子に現れないので、組む側も変わらない。
    let schemaVersion = 1

    /// 与えた基準の下の、記録の在処。
    ///
    /// **綴りはここ 1 つ。** 書くのは見張り、読むのは切り分けの口と窓口の 3 者いるので、
    /// 別々に組むと基準を揃えても同じ形で割れる
    /// ([#730](https://github.com/mokume-metal/mokume/issues/730))。
    static func statusURL(under facetBase: URL) -> URL {
        WorkDirectory.facet("build", under: facetBase)
            .appendingPathComponent("status.json", isDirectory: false)
    }

    /// 分解した所要時間 (ミリ秒)。
    ///
    /// **気付いてから新しい絵が出るまでは `detectMs + buildMs + firstFrameMs` である。**
    /// `firstFrameMs` は `relaunchMs` と同じ時刻から数えるので、`relaunchMs` を丸ごと含む —
    /// 足すと重ねて数えることになる。保存してから巡回が気付くまで (巡回の間隔ぶん) は
    /// どれにも入らない ([#930](https://github.com/mokume-metal/mokume/issues/930))。
    struct Timings: Encodable, Equatable {
        /// 変化に気付いてから、作り直しを始めるまで (前の作り直しの順番待ち)。
        /// 最初の作り直しでは省く。
        ///
        /// **保存した時刻は数えていない。** 見ているのはソースの世代の刻印だけで、保存の
        /// 時刻を持たないためである — 数え始めは巡回が変化を見つけた時刻になる。
        var detectMs: Double?
        /// 作り直しにかかった時間。
        var buildMs: Double
        /// 差し替え (古いものを畳み、新しいものを起こし終えるまで)。失敗したときは省く。
        ///
        /// **起こし終えた時点で止まる。** 窓が新しい絵を出すまでは ``firstFrameMs`` が持つ。
        var relaunchMs: Double?
        /// 差し替えを始めてから、次の世代の 1 枚目が道具の面へ乗り換わるまで。
        ///
        /// **窓を出せた見張りだけが書く。** 乗り換えの合図は道具の窓から来るので、窓の無い
        /// 実行では誰も知らせてくれない。合図が絵の出た時点を指すと言えない回
        /// (``WatchSession/generationPromoted()`` が挙げる) も省く — 嘘の数字より空欄を取る。
        ///
        /// **最初の記録には載らない。** 記録は起こし終えた時点で一度書き、合図が来てから
        /// これを足して書き直す。
        var firstFrameMs: Double?
    }

    /// 作り直せたか。
    let ok: Bool
    /// 作り直しの終了コード。
    let status: Int32
    /// 出力 (失敗の内容を含む)。**成否によらず載せる** — 警告は成功しても読みたい。
    let output: String
    /// この作り直しが対象にしたソースの世代。
    let stamp: String?
    /// どの構成で作ったか。数字がどの土俵のものか分からないと比べられない。
    let configuration: String
    /// 差し替えたスケッチが立ち上がったか。
    ///
    /// **作り直せたことと、走っていることは別である。** かつてここが無かったとき、
    /// 実行ファイルを解決できなかった回も `ok: true` で記録されていた — 症状は
    /// 「保存した → 作り直したと出た → 絵が止まっている」で、**記録のどこにも理由が
    /// 出なかった** ([#1066](https://github.com/mokume-metal/mokume/issues/1066))。
    let launched: Bool
    /// 分解した所要時間。
    ///
    /// **これだけは後から書き換わる。** 新しい絵が出るまで (``Timings/firstFrameMs``) は
    /// 記録を置いた後に分かるので、見張りが足して置き直す。
    var timings: Timings

    /// 1 行の要約。端末に出す形で、測定の道具もこれを読める。
    var summary: String {
        var parts = ["build_ms=\(round(timings.buildMs))"]
        if let detect = timings.detectMs { parts.insert("detect_ms=\(round(detect))", at: 0) }
        if let relaunch = timings.relaunchMs { parts.append("relaunch_ms=\(round(relaunch))") }
        parts.append("configuration=\(configuration)")
        if let stamp { parts.append("stamp=\(stamp)") }
        // **起こせなかった回を「作り直した」で終わらせない。** そこが最も分かりにくい
        // 壊れ方 (絵が止まっているのに成功と出る) だからである (#1066)
        let lead =
            switch (ok, launched) {
            case (true, true): "Rebuilt: "
            case (true, false): "Rebuilt, but could not start it: "
            case (false, _): "Build failed: "
            }
        return lead + parts.joined(separator: " ")
    }

    private func round(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
