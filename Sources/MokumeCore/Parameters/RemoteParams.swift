// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Observation

/// 別のプロセスが宣言したつまみを、面越しに読み書きする。
///
/// ## なぜ要るか
///
/// 見張り (`watch`) が出すプレビューは**スケッチのオブジェクトを持っていない** — 走って
/// いるのは別のプロセスである。いままでのつまみは宣言をスケッチから直に引くところから
/// 始まるので、そのままでは道具側で組めない ([ADR-0032] 決定 5)。
///
/// ## 面には既に全部載っている
///
/// `.mokume/params` の応答は、名前・型・いまの値・動ける幅・許した候補を**まとめて**
/// 出す — 読み手が別の面を見に行かなくて済むように、そう決めてある ([ADR-0030] 決定 2)。
/// だから読み手をもう 1 人増やすだけで足り、**新しい経路も新しい規約も作らない**
/// ([ADR-0030] 決定 1 は変わらない — 変わるのは重ねる窓だけである)。
///
/// ## 正典は子
///
/// 動かした値はその場で見た目に効かせ、応答が返ってきたら子の言うほうへ合わせる。
/// **その場で効かせないとつまみが戻る** — 応答は書いてから届くので、届くまでの間は
/// 古い値しか無い。自分の要求に対する応答かどうかは、応答が echo する識別子で分かる。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class RemoteParams {
    /// 面の応答のうち、つまみを組むのに要るところ。
    ///
    /// **宣言は 1 件ずつ緩く読む** (``Reading``)。配列ごと厳しく読むと、1 件が読めないだけで応答
    /// 全体が `WatchedFile` に捨てられ、つまみが 1 つも並ばない — 子が新しい版のライブラリで
    /// 知らない `type` を名乗ったときに起きる ([#2856](https://github.com/mokume-metal/mokume/issues/2856))。
    /// 外枠 (`params` が配列でない・JSON でない) が読めない応答は、全体を断り、改訂ごとに 1 度名乗る
    /// ([#2889](https://github.com/mokume-metal/mokume/issues/2889))。
    ///
    /// **外枠も、使わないものと型の外れた付随を理由に捨てない。** `revision` は取り込みに使わないので
    /// 読まない (型がずれても応答ごと捨てられていた)。`id` は自分の要求の echo かを見るのに使うが、
    /// 文字列でなければ「何も応えていない」と同じに読む — 自分の要求の識別子は文字列なので、
    /// 文字列でない値が自分の echo であることはない。
    private struct Report: Decodable {
        let id: String?
        let params: [Reading]

        private enum CodingKeys: String, CodingKey { case id, params }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            params = try container.decode([Reading].self, forKey: .params)
        }
    }

    /// 宣言 1 件の読み。保存の復元が 1 件ずつ読むのと同じ向き (``ParamStore/SavedReading``・#2806)。
    private enum Reading: Decodable {
        case declaration(ParamDeclaration)
        /// 読めなかった 1 件。`name` は名前だけでも読めたとき、`reason` は読めなかった理由。
        case unreadable(name: String?, reason: String)

        private enum NameKey: String, CodingKey { case name }

        init(from decoder: any Decoder) throws {
            do {
                self = .declaration(try ParamDeclaration(from: decoder))
            } catch {
                // 要素がオブジェクトでない・名前が文字列でないときは、名指しできない
                let name = try? decoder.container(keyedBy: NameKey.self)
                    .decode(String.self, forKey: .name)
                self = .unreadable(name: name, reason: Diagnostics.reason(error))
            }
        }
    }

    let directory: URL
    /// いま並べる箱。**顔ぶれが変われば作り直される。**
    private(set) var boxes: [RemoteParam] = []
    /// 並んでいる宣言の顔ぶれ。名前と型が変わったかだけを見る。
    private(set) var signature: [String] = []
    /// 応答の見張り。**変わったときだけ読み直す** — 書きかけを掴んだ改訂は、確定させずに
    /// 次の機会へ回る (``WatchedFile``)。
    private let report: WatchedFile<Report>
    /// 最後に書いた要求の識別子。応答がこれを echo するまでは、自分の値を信じる。
    private var pendingId: String?
    /// 応えを待つ間に置いた、最後のもの以外の自分の要求。**つまみを引いている間は要求が続く**ので、
    /// 前の要求への echo で引いている途中の値へ戻さない。決着したら空にする。
    private var earlierIds: Set<String> = []
    /// 待つ間に要求を置くたび、置く直前に区画の応答が echo していた識別子 (区画でまだ何も応えて
    /// いなければ `nil` も入る)。**これを echo する応答は、そのときの要求より前に書かれたもの**で、
    /// 最後の要求を含まない姿である。待ちの最初の要求の分だけを控えると、2 つ目以降の要求を置く前に
    /// 別の書き手へ応えた応答を「自分の後」と読み、つまみが 1 度跳ぶ (#2795 の反証)。決着したら空にする。
    private var idsBeforeRequests: Set<String?> = []
    /// 最後に取り込んだ応答の識別子。置く直前に応答を読み直せないときに、その代わりに使う。
    private var lastSeenId: String?
    /// いま飛ばしている宣言の鍵 (名前が読めなければ配列の位置、と読めなかった理由)。**応答は値が
    /// 動くたびに書き直され、飛ばした宣言は読み直しのたびに同じ姿で居続ける**ので、前の応答でも
    /// 飛ばしていた宣言は繰り返さない。読めるようになってから再び壊れた・別の理由で読めなくなった
    /// 宣言は、新しく飛ばしたものとして言い直す。
    private var skipped: Set<String> = []

    /// 読めない宣言を飛ばしたこと・読めない応答のことの名乗り。**検査から差し替える** — 既定は標準エラー。
    private let warn: (String) -> Void

    init(directory: URL, warn: @escaping (String) -> Void = Diagnostics.warn) {
        self.directory = directory
        self.warn = warn
        let reportURL = WorkDirectory.reportURL(under: directory)
        // **外枠が読めない応答も名乗る** ([#2889](https://github.com/mokume-metal/mokume/issues/2889))。
        // つまみが 1 つも並ばない理由が残る
        self.report = WatchedFile(url: reportURL) { reason in
            warn(UnreadableRevision.notice(of: "The knob report", at: reportURL, reason: reason))
        }
    }

    /// 応答が変わっていれば読み直す。
    ///
    /// - Returns: 箱の顔ぶれが変わったら `true` (重ねる面を作り直す合図)。
    @discardableResult
    func refresh() -> Bool {
        guard let report = report.changed() else { return false }
        return adopt(report)
    }

    /// 応答を取り込む。
    private func adopt(_ report: Report) -> Bool {
        lastSeenId = report.id
        let settled = settles(report.id)
        if settled {
            pendingId = nil
            earlierIds = []
            idsBeforeRequests = []
        }

        let declarations = readable(report.params)
        let incoming = declarations.map(Self.face(of:))
        guard incoming != signature else {
            if settled {
                for (box, declaration) in zip(boxes, declarations) { box.adopt(declaration.value) }
            }
            return false
        }
        // 顔ぶれが変わった = 別の宣言を持つスケッチが走っている。**組み直す**
        signature = incoming
        boxes = declarations.map { declaration in
            RemoteParam(declaration: declaration) { [weak self] name, value in
                self?.send(name: name, value: value)
            }
        }
        return true
    }

    /// 読めた宣言だけを返す。読めずに飛ばした宣言は、**初めて見たときに 1 度だけ**名乗る。
    ///
    /// 名乗らずに飛ばすと、つまみが足りない理由が追えない ([ADR-0030] 決定 6 の「捨てたことを
    /// 診断に出す」と同じ向き)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private func readable(_ readings: [Reading]) -> [ParamDeclaration] {
        var declarations: [ParamDeclaration] = []
        var skippedNow: Set<String> = []
        defer { skipped = skippedNow }
        for (index, reading) in readings.enumerated() {
            switch reading {
            case .declaration(let declaration):
                declarations.append(declaration)
            case .unreadable(let name, let reason):
                let key = "\(name ?? "#\(index)")|\(reason)"
                skippedNow.insert(key)
                guard !skipped.contains(key) else { continue }
                let subject = name.map { "The knob \"\($0)\"" } ?? "A knob declaration (entry \(index))"
                warn(
                    "\(subject) in the sketch's report could not be read, so it is left out "
                        + "(the other knobs are still shown): \(reason) (said once for this knob)")
            }
        }
        return declarations
    }

    /// この応答で、子の値を採ってよいか。
    ///
    /// **自分の書いたぶんが子に届くまでは、こちらの値を信じる。** 届く前の応答は動かす前の値を
    /// 運んでいるので、そのまま採るとつまみが戻る。届いたかは応答が echo する識別子で見る:
    ///
    /// - 最後に置いた自分の要求 → 届いた
    /// - 前に置いた自分の要求・待つ間に要求を置く直前からあった識別子 → まだ (最後の要求より前の姿)
    /// - **それ以外** → 自分の要求を置いた後に、別の書き手の要求へ応えた応答である。応答は 1 枚で
    ///   直近の識別子しか持たないので、自分の要求は当たった後で上書きされたか、読まれる前に
    ///   置き換えられて消えたかのどちらかで、**どちらでも自分の echo はもう来ない**。待ち続けると、
    ///   宣言の顔ぶれが変わるまで全部のつまみが子に追い付かない
    ///   ([#2795](https://github.com/mokume-metal/mokume/issues/2795))。後勝ち ([ADR-0030] 決定 2)
    ///   で決まった子の値を採る
    ///
    /// 世代の切り替えで 2 世代が重なる間は、次の世代の最初の応答が、作った時点の記録の識別子
    /// (前の世代が応えたもの) を載せる。要求を置く前の識別子にそれがあれば待ち続けるが、
    /// 前の世代がその後に別の要求へ応えていれば「別の書き手」と読み、次の世代が自分の要求に
    /// 応え直すまで 1 度戻りうる。重なりが持つ代償の範囲である
    /// ([#1433](https://github.com/mokume-metal/mokume/issues/1433))。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private func settles(_ echoed: String?) -> Bool {
        guard let pendingId else { return true }
        if echoed == pendingId { return true }
        if idsBeforeRequests.contains(echoed) { return false }
        if let echoed, earlierIds.contains(echoed) { return false }
        return true
    }

    /// 区画の応答が、いま echo している識別子。読めなければ最後に取り込んだもの。
    ///
    /// **要求を置く直前に読み直す。** 最後に取り込んだ応答はフレーム 1 つぶん古いことがあり、
    /// その間に別の書き手へ応えた応答 (自分の要求より前に書かれたもの) を「自分の要求の後」と
    /// 取り違えると、つまみが 1 度戻る。置いた後に読むと、置いた直後に別の書き手へ応えた応答を
    /// 「前からあった」と掴み、その応答で決着できずに止まるので、置く前に読む。
    private func echoedNow() -> String? {
        guard let data = try? Data(contentsOf: WorkDirectory.reportURL(under: directory)),
            let echo = try? JSONDecoder().decode(Echo.self, from: data)
        else { return lastSeenId }
        return echo.id
    }

    /// 応答のうち、置く直前に読み直すところ。
    private struct Echo: Decodable {
        let id: String?
    }

    /// 宣言の顔。**値は入れない** — 値が変わるたびに組み直しては、触っている手から
    /// つまみが消える。
    private static func face(of declaration: ParamDeclaration) -> String {
        "\(declaration.name):\(declaration.typeName)"
    }

    /// 動かされた値を要求として置く。
    ///
    /// **区画の書き方は外から書くときと同じ** ([ADR-0030] 決定 2)。道具だからといって
    /// 近道を作らない — 作れば、面から書いたときにだけ起きる不具合が生まれる。
    private func send(name: String, value: ParamValue) {
        let id = UUID().uuidString
        let request = Request(id: id, values: [Request.Entry(name: name, value: value)])
        // **置くたびに**、置く前の識別子を控える (``echoedNow()``)。待っている間に続けて置いた
        // 要求は、前の自分の要求としても控える
        let before = echoedNow()
        // 置けなければこの 1 回を捨てる (次に動かせばまた書く)。**捨てたことは
        // 口が 1 度だけ名乗る** — つまみを掴んでいる間は入力のたびにここへ来るので、
        // 毎回言うと標準エラーが流れる (#989)
        guard AtomicFile.publishJSON(
            request, to: WorkDirectory.requestURL(under: directory), "the knob request")
        else { return }
        if let earlier = pendingId { earlierIds.insert(earlier) }
        idsBeforeRequests.insert(before)
        pendingId = id
    }

    /// 置く要求。読む側 (``ParamRequest``) と同じ形を、書く側から見たもの。
    private struct Request: Encodable {
        let id: String
        let values: [Entry]

        /// 1 件ぶん。**読む側 (``ParamRequest``) と同じ形** (``NamedParamValue``)。
        typealias Entry = NamedParamValue
    }
}

/// 面越しの 1 つのつまみ。
///
/// ``ParamBox`` と同じ顔 (``DeclaredParam``) をしているので、**つまみの絵は 1 つのまま**
/// でよい — 走らせた窓と道具の窓で見た目が割れない ([ADR-0032] 決定 5)。
@Observable
@MainActor
final class RemoteParam: DeclaredParam {
    /// いまの値。**動かせばその場で変わる** (正典は子だが、届くまではこちらを見せる)。
    private(set) var value: ParamValue

    @ObservationIgnored let name: String
    @ObservationIgnored let range: ParamRange?
    @ObservationIgnored let choices: [String]?
    @ObservationIgnored let step: Double?
    @ObservationIgnored private let post: (String, ParamValue) -> Void

    init(declaration: ParamDeclaration, post: @escaping (String, ParamValue) -> Void) {
        self.value = declaration.value
        self.name = declaration.name
        self.range = declaration.range
        self.choices = declaration.choices
        self.step = declaration.step
        self.post = post
    }

    var declaration: ParamDeclaration {
        ParamDeclaration(name: name, value: value, range: range, choices: choices, step: step)
    }

    /// つまみを動かされた。
    ///
    /// **収めるのも弾くのも子の仕事である** ([ADR-0030] 決定 3 の判断は 1 か所にある)。
    /// ここは見た目をその場で合わせて、要求を置くだけにする — 二重に判断すると、
    /// 道具の版とスケッチの版で違う端に収まる日が来る。
    func write(_ incoming: ParamValue) -> ParamOutcome {
        value = incoming
        post(name, incoming)
        return .applied
    }

    /// 子が名乗った値へ合わせる。
    func adopt(_ settled: ParamValue) {
        guard settled != value else { return }
        value = settled
    }
}
