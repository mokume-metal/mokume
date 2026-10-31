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

    /// 記録の、作業の場所からの相対の置き場所 (人へ見せる)。
    static var statusRelativePath: String {
        String(statusURL(under: URL(fileURLWithPath: "/")).path.dropFirst())
    }

    /// 組む口は 3 つで、**理由の無い `ok: true, launched: false` は作れない**
    /// ([#2574](https://github.com/mokume-metal/mokume/issues/2574))。約束「`launched: false` の
    /// 記録は理由を名乗る」を型が守らせず、読み手が理由の無い記録に出会う形が残っていた。
    /// メンバーワイズの口は閉じてある。
    private init(
        ok: Bool, status: Int32, output: String, stamp: String?, configuration: String,
        launched: Bool, notStartedReason: String?, timings: Timings
    ) {
        self.ok = ok
        self.status = status
        self.output = output
        self.stamp = stamp
        self.configuration = configuration
        self.launched = launched
        self.notStartedReason = notStartedReason
        self.timings = timings
    }

    /// 作り直しが通り、子も起こせた回。
    static func launched(
        output: String, stamp: String?, configuration: String, timings: Timings
    ) -> BuildReport {
        BuildReport(
            ok: true, status: 0, output: output, stamp: stamp, configuration: configuration,
            launched: true, notStartedReason: nil, timings: timings)
    }

    /// 作り直しが通らなかった回 (途中で止めた回・始める前に終わった回を含む)。**子は起こしていない。**
    static func failed(
        status: Int32, output: String, stamp: String?, configuration: String, timings: Timings
    ) -> BuildReport {
        BuildReport(
            ok: false, status: status, output: output, stamp: stamp, configuration: configuration,
            launched: false, notStartedReason: nil, timings: timings)
    }

    /// 作り直しは通ったが、子を起こさなかった (起こせなかった) 回。**理由は必ず持つ。**
    ///
    /// 理由は記録の本文の頭に置き、作り直しの出力を空行を挟んで後ろに続ける (作り直しの出力は
    /// 長く、末尾に置いた理由は読まれない)。**記録の欄 (`notStartedReason`) にも持つ** — 本文の
    /// 頭の規約は、この規則の前に書かれた記録には無いので、規約だけでは新旧を見分けられない。
    ///
    /// - Parameter reason: 理由。**空・空白だけのときは、理由が無いことを名乗る文に倒す。**
    ///   空行は含められない (最初の空行までが理由と読まれる) ので、行を詰める。
    static func notStarted(
        reason: String, buildOutput: String, stamp: String?, configuration: String,
        timings: Timings
    ) -> BuildReport {
        let reason = normalized(reason)
        return BuildReport(
            ok: true, status: 0, output: WatchSession.notLaunched(reason, buildOutput),
            stamp: stamp, configuration: configuration, launched: false,
            notStartedReason: reason, timings: timings)
    }

    /// 試聴の版を、本番が乗り換えを待つ間は起こさず保留した回の理由 ([#3565](https://github.com/mokume-metal/mokume/issues/3565))。
    /// 乗り換えが決着してから起こす。**起こせなかった回とは言葉を分ける。**
    static let auditionDeferredNotice =
        "Audition waits: the work's window is still switching to the version just started"

    /// 理由が無いと言う文 (理由として空を渡された回)。
    static let unknownReason = "The sketch was not started, and no reason was given"

    private static func normalized(_ reason: String) -> String {
        let lines = reason.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? unknownReason : lines.joined(separator: "\n")
    }

    /// 与えた基準の下の、記録の在処。
    ///
    /// **綴りはここ 1 つ。** 書くのは見張り、読むのは切り分けの口と窓口の 3 者いるので、
    /// 別々に組むと基準を揃えても同じ形で割れる
    /// ([#730](https://github.com/mokume-metal/mokume/issues/730))。
    static func statusURL(under facetBase: URL) -> URL {
        WorkDirectory.facet(WorkDirectory.buildFacetName, under: facetBase)
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
    /// 作り直しは通ったが子を起こさなかった回の理由。**その回だけが持ち、空でない。**
    ///
    /// 本文 (``output``) の頭にも同じものを置くが、頭の規約はこの欄が出来る前の記録には無い。
    /// 欄があれば新しい形、無ければ理由が書かれていない古い記録、と読み手が見分けられる。
    let notStartedReason: String?
    /// 分解した所要時間。
    ///
    /// **これだけは後から書き換わる。** 新しい絵が出るまで (``Timings/firstFrameMs``) は
    /// 記録を置いた後に分かるので、見張りが足して置き直す。
    var timings: Timings
    /// 試聴の版の作り直しか ([#3565](https://github.com/mokume-metal/mokume/issues/3565))。
    ///
    /// **試聴に入っている間の記録だけが `true` を持つ。** 試聴の版は作品の窓に出ない — 記録の `launched` は
    /// 「プレビューに起こした」で、「作品の窓が映す版」ではない。試聴を出ると記録は本番の版に戻り、この欄は無くなる。
    /// 試聴に入っていない記録は、欄ごと持たない。
    var audition: Bool?

    /// 1 行の要約。端末に出す形で、測定の道具もこれを読める。
    var summary: String {
        var parts = ["build_ms=\(round(timings.buildMs))"]
        if let detect = timings.detectMs { parts.insert("detect_ms=\(round(detect))", at: 0) }
        if let relaunch = timings.relaunchMs { parts.append("relaunch_ms=\(round(relaunch))") }
        parts.append("configuration=\(configuration)")
        if let stamp { parts.append("stamp=\(stamp)") }
        // **起こせなかった回を「作り直した」で終わらせない。** そこが最も分かりにくい
        // 壊れ方 (絵が止まっているのに成功と出る) だからである (#1066)
        //
        // **終われと言われて起こさなかった回を「起こせなかった」と言わない** (#2521)。本文の頭
        // (``stopRequestedNotice``) と食い違うと、読む人はどちらが起きたのか分からない
        let lead =
            switch (ok, launched) {
            case (true, true): "Rebuilt: "
            case (true, false) where notStartedReason?.hasPrefix(Self.auditionDeferredNotice) == true:
                "Rebuilt, audition not started yet: "
            case (true, false) where notStartedReason?.hasPrefix(Self.stopRequestedNotice) == true:
                "Rebuilt, not started because watching was ending: "
            case (true, false): "Rebuilt, but could not start it: "
            case (false, _): "Build failed: "
            }
        return lead + parts.joined(separator: " ")
    }

    /// 作り直しは通ったのに子を起こさなかった回の、理由の頭 1 行。**それ以外の回は `nil`。**
    ///
    /// 読み手 (プレビューと `doctor`) が `(ok, launched)` の片方だけを見て、この回を成功と同じ
    /// に扱っていた ([#2574](https://github.com/mokume-metal/mokume/issues/2574))。
    var notStartedHead: String? {
        notStartedReason.flatMap(Self.firstLine)
    }

    /// 理由の頭 1 行。**記録 (JSON) から読んだ理由にも使う** (`doctor`)。
    static func firstLine(_ reason: String) -> String? {
        reason.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// プレビューの 1 行の長さの上限。
    ///
    /// プレビューの印は 1 行の小さな字で、折り返しも省略もしない (窓の幅で切れる)。**肝心なのは
    /// 末尾 (`(Permission denied)`) なので、長いときは中を詰める。**
    static let noticeLimit = 80

    /// プレビューへ重ねる、起こせなかった回の 1 行。**該当しない回は `nil`。**
    ///
    /// 要約 (``summary``) の頭と同じ言葉で言う — 端末が正で、プレビューはそれを映す。
    /// **終われと言われて起こさなかった回は、その文をそのまま出す** (#2521)。「起こせなかった」
    /// を前に付けると、起きたこととは別のことを言う。
    ///
    /// **「could not start」を重ねない。** 起こせなかった理由はふつう `Could not start <tool> in
    /// <place>: …` で始まるので、前置きを足すと同じ言葉が 2 回出て、窓幅のぶんを使い切る。
    var notStartedNotice: String? {
        guard let head = notStartedHead else { return nil }
        if head.hasPrefix(Self.stopRequestedNotice) { return head }
        // **最初の絵を出す前に終わった子は、終わり方 (終了コード・合図) を詰めても残す** (#3172)。理由は
        // `Could not start <道具> in <場所>: it exited with code 7 before drawing its first frame` で、場所が
        // 長いと、末尾を残す詰め方でも終わり方が落ちる。場所を落として頭だけを詰める
        if head.hasSuffix(Self.firstFrameSuffix), let cut = head.range(of: ": it ", options: .backwards) {
            var lead = String(head[..<cut.lowerBound])
            if let place = lead.range(of: " in ") { lead = String(lead[..<place.lowerBound]) }
            let tail = String(head[cut.lowerBound...])
            if tail.count < Self.noticeLimit - 12 {
                return Self.abbreviated(lead, to: Self.noticeLimit - tail.count) + tail
            }
        }
        let tool = "Could not start"
        let line =
            head.hasPrefix(tool)
            ? "Rebuilt, but could not start" + String(head.dropFirst(tool.count))
            : "Rebuilt, but could not start it: " + head
        return Self.abbreviated(line, to: Self.noticeLimit)
    }

    /// 通らなかった作り直しの出力のうち、**最初の `error:` の行** ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
    /// 無ければ `nil`。
    ///
    /// 拾う形は **行の頭が** `<パス>:<行>:<桁>: error: <文>` (桁の無い `<パス>:<行>: error: <文>` も)。
    /// - パスは `<` で始まらない (`<unknown>:0: error: …` のような、ファイルを指さない疑似位置は拾わない)
    /// - 行は 1 以上 (行 0 は、行を指さない)
    /// - 位置は行の頭に限る — 文中にたまたま `:1: error: ` を含む警告・注記の行は拾わない
    /// - **C 系ターゲットの失敗は拾わない。** `swift build` は clang の失敗を `error: <パス>:<行>:<桁> <文>`
    ///   (`: error:` を持たず、`fatal error:` でもない) の形で出す (ヘッダが見つからない等・実測) ので、この形には
    ///   当たらない。Swift の失敗だけが対象で、C 系は今の行のまま (端末には出ている)
    ///
    /// ファイルと行が付かない `error:` の行 (リンクの失敗など) は拾わない — 窓の行は、直す場所が分かる行だけを
    /// 出す。端末に出た行を言い換えず、色の制御列だけを落とす。長いときは、肝心な文が末尾にあるので**中を詰める**
    /// (プレビューの他の行と同じ規則・同じ上限 — ``abbreviated(_:to:)``・``noticeLimit``)。
    var firstErrorLine: String? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = Self.stripEscapes(String(raw))
            guard line.range(of: Self.errorLinePattern, options: .regularExpression) != nil else {
                continue
            }
            return Self.abbreviated(line.trimmingCharacters(in: .whitespaces), to: Self.noticeLimit)
        }
        return nil
    }

    /// 行の頭の `<パス>:<行>(:<桁>)?: error: `。パスは `:` を含まず `<` で始まらない、行は 1 以上。
    private static let errorLinePattern = #"^[^<:\s][^:]*:[1-9][0-9]*(:[0-9]+)?: error: "#

    /// 色の制御列 (`ESC [ … m`) を落とす。`swift build` の出力は端末向けに色が付くことがある。
    private static func stripEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// 長い 1 行を、頭と末尾を残して中を詰める。
    static func abbreviated(_ line: String, to limit: Int) -> String {
        guard line.count > limit else { return line }
        let mark = " … "
        let head = limit * 55 / 100
        let tail = limit - head - mark.count
        return String(line.prefix(head)) + mark + String(line.suffix(tail))
    }

    /// 作り直しの失敗ではないのに `ok: false` で書かれる記録 (見張りを終えたときの最後の記録)。
    ///
    /// 本文の頭が「失敗ではない」と名乗る ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    /// 読み手が `ok` だけで「failed」と言うと、その名乗りを捨てることになる。
    enum Interruption: Equatable {
        /// 作り直しを途中で止めた。
        case rebuildStopped
        /// 最初の作り直しを始める前に終わった。
        case beforeFirstBuild

        /// 記録の本文から読む。**この規則の前の記録にも同じ頭が付いている。**
        static func of(output: String) -> Interruption? {
            if output.hasPrefix(WatchSession.stoppedRebuildNotice) { return .rebuildStopped }
            if output.hasPrefix(WatchSession.notStartedNotice) { return .beforeFirstBuild }
            return nil
        }
    }

    /// 最初の絵を出す前に失敗で終わった子の理由の結び。理由の組み立て (``WatchSession/failedStartReason(tool:place:departure:)``)
    /// と、プレビューの詰め方 (``notStartedNotice``) が同じ綴りを見る。
    static let firstFrameSuffix = " before drawing its first frame"

    /// 起動できなかった理由の 2 行目の頭。**子が自分で渡した理由の最初の行**が続く
    /// ([#3169](https://github.com/mokume-metal/mokume/issues/3169))。
    ///
    /// 見張りが書き (``WatchSession``)、窓口が読む (``Facets/notStartedAnswer()``)。**この行が有るときだけ、
    /// 子の言葉が `output` の頭に続く。** 子が理由を置けなかった回 (落ちた・起こせなかった) の理由には無いので、
    /// 窓口は無い言葉を約束しない。
    static let sketchReportedPrefix = "The sketch reported: "

    /// 終われと言われた後に作り直しが通った回の、起こさなかった理由 (本文の頭に置く)。
    static let stopRequestedNotice =
        "Not started, because watching was ending — the build itself succeeded"

    private func round(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
