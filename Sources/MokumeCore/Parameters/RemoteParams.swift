// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
    private struct Report: Decodable {
        let revision: Int
        let id: String?
        let params: [ParamDeclaration]
    }

    let directory: URL
    /// いま並べる箱。**顔ぶれが変われば作り直される。**
    private(set) var boxes: [RemoteParam] = []
    /// 並んでいる宣言の顔ぶれ。名前と型が変わったかだけを見る。
    private(set) var signature: [String] = []
    /// 応答を最後に読んだときの更新時刻。**変わったときだけ読み直す。**
    private var readAt: Date?
    /// 最後に書いた要求の識別子。応答がこれを echo するまでは、自分の値を信じる。
    private var pendingId: String?

    init(directory: URL) {
        self.directory = directory
    }

    /// 応答が変わっていれば読み直す。
    ///
    /// - Returns: 箱の顔ぶれが変わったら `true` (重ねる面を作り直す合図)。
    @discardableResult
    func refresh() -> Bool {
        let url = directory.appendingPathComponent(ParamSurface.reportFileName)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        guard let modified, modified != readAt else { return false }
        readAt = modified
        guard let data = try? Data(contentsOf: url),
            let report = try? JSONDecoder().decode(Report.self, from: data)
        else { return false }
        return adopt(report)
    }

    /// 応答を取り込む。
    private func adopt(_ report: Report) -> Bool {
        // **自分の書いたぶんが子に届くまでは、こちらの値を信じる。** 届く前の応答は
        // 動かす前の値を運んでいるので、そのまま採るとつまみが戻る
        let settled = pendingId == nil || report.id == pendingId
        if settled { pendingId = nil }

        let incoming = report.params.map(Self.face(of:))
        guard incoming != signature else {
            if settled {
                for (box, declaration) in zip(boxes, report.params) { box.adopt(declaration.value) }
            }
            return false
        }
        // 顔ぶれが変わった = 別の宣言を持つスケッチが走っている。**組み直す**
        signature = incoming
        boxes = report.params.map { declaration in
            RemoteParam(declaration: declaration) { [weak self] name, value in
                self?.send(name: name, value: value)
            }
        }
        return true
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
        guard let data = try? JSONEncoder().encode(request) else { return }
        do {
            try AtomicFile.write(
                data, to: directory.appendingPathComponent(ParamSurface.requestFileName))
            pendingId = id
        } catch {
            // 書けなければ、この 1 回を捨てる。次に動かせばまた書く
        }
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
    @ObservationIgnored private let post: (String, ParamValue) -> Void

    init(declaration: ParamDeclaration, post: @escaping (String, ParamValue) -> Void) {
        self.value = declaration.value
        self.name = declaration.name
        self.range = declaration.range
        self.choices = declaration.choices
        self.post = post
    }

    var declaration: ParamDeclaration {
        ParamDeclaration(name: name, value: value, range: range, choices: choices)
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
