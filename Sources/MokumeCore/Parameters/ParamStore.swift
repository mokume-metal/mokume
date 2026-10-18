// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Observation

/// 合わせた値を、次の起動へ持ち越す。
///
/// **既定で効き、道具を通さない素の実行でも効く** ([ADR-0030] 決定 6)。つまみを 20 個
/// 合わせた作業が再起動のたびに消えてよい理由は無く、「昨日の続きから」に道具の導入を
/// 要求しない。
///
/// ## 区画ではない
///
/// 置き場は `.mokume/state/params.json` で、**やりとりの区画 (`.mokume/params/`) とは
/// 別**である。区画は「利用者が作ったときだけ有効」で成り立っているので ([ADR-0018]
/// 決定 2)、既定で効く保存が区画を作ると、2 回目の起動から外からの操作まで誰も頼んで
/// いないのに有効になってしまう。**既定で効くものと、頼まれたときだけ効くものを同じ
/// 入れ物に置かない。**
///
/// ## 保存された値は作品の正典ではない
///
/// 正典はコードに書いた既定値であり ([ADR-0013] 決定 3)、ここが返すのは手元の続きだけ
/// である。作品として残したい値はコードへ書き戻す — だから置き場は版管理から外れて
/// いてよい。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@MainActor
final class ParamStore: DeclarationWatcher {
    /// 静かになったと見なすまでのフレーム数。
    ///
    /// **つまみを引いている最中に毎フレーム書かない** ([ADR-0030] 決定 6)。続けて
    /// 変わっている間はまとめ、手が止まってから 1 回だけ書く。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    static let quietFrames = 30

    /// 保存の形の版。
    static let schemaVersion = 1

    let url: URL
    /// 見張る先 (``DeclarationWatcher``)。
    let registry: ParamRegistry
    /// 値が変わったという印 (``DeclarationWatcher``)。
    let declarationNotice = DeclarationNotice()
    /// 静かになるまでの残り。`nil` なら書くものが無い。
    private var countdown: Int?
    /// 実際に書いた回数。**まとめられていることを検査から見るために持つ。**
    private(set) var writeCount = 0
    /// 人へ 1 行伝える口。**検査から差し替える** — 失敗の文面を標準エラーから拾わずに見る。
    private let warn: (String) -> Void
    /// 最後に名乗った、書けなかった理由。**同じ理由は書けるまで繰り返さない** — 面からの
    /// 要求は当てるたびに書く (``flushNow()``) ので、書けない値が残っていると入力 1 回ごとに
    /// 同じ 1 行が流れる。
    private var lastWriteFailure: String?

    /// 保存を持たせる。宣言が 1 つも無ければ持たせない (書くものが無い)。
    static func makeIfNeeded(for registry: ParamRegistry, at url: URL = WorkDirectory.savedParams)
        -> ParamStore?
    {
        registry.isEmpty ? nil : ParamStore(registry: registry, at: url)
    }

    init(
        registry: ParamRegistry, at url: URL = WorkDirectory.savedParams,
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.registry = registry
        self.url = url
        self.warn = warn
    }

    // MARK: - 戻す

    /// 保存されていた値を戻し、何を捨てたかを返す。**起動時に 1 回だけ。**
    ///
    /// 採るのは**名前と型が一致するものだけ**である ([ADR-0030] 決定 6)。それ以外の
    /// 救済 (型を変換して救う、など) を入れると、絵が理由なく変わる経路が増える。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    @discardableResult
    func restore() -> Restoration {
        defer { watchDeclarations() }
        // 読めない保存は捨てて既定値で立ち上げる。**黙って捨てない** — 「なぜか
        // 既定値に戻る」は理由が出ないと追えない。**黙るのは無いときだけ** (初めての起動)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Restoration()
        } catch {
            // ファイルとして読めない (置き場がディレクトリ・権限が無い) のは、中身を見る前の失敗で、
            // 捨てた値の名指しにならない。標準エラーの 1 行だけにする
            sayUnreadable(error)
            return Restoration()
        }
        let entries: [ParamRequest.Entry]
        do {
            entries = try JSONDecoder().decode(SavedReading.self, from: data).values
        } catch {
            // **外枠が読めない保存も、捨てたことを最初の応答に載せる** (#2806)。名指しする相手が無いので、
            // 要求の外枠が読めないとき (#2550) と同じく名前の読めない 1 件にする
            sayUnreadable(error)
            return Restoration(discarded: [.init(name: "", reason: .typeMismatch)])
        }

        var result = Restoration()
        // 捨てたものは 2 つに分けて控える。言い方が違う (``notice(for:unreadable:)``)
        var mismatched: [ParamReport.Rejection] = []
        var unreadable: [ParamReport.Rejection] = []
        // 当てる順は名前順。保存の並びに結果が依ると、同じ保存から違う姿が出る
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            // **読めなかった 1 件は、その 1 件だけ捨てて名指しし、残りは戻す** (#2806)
            if let refusal = entry.refusal(declaredIn: registry) {
                result.discarded.append(refusal)
                unreadable.append(refusal)
                continue
            }
            guard case .value(let value) = entry.reading else { continue }
            let reason: ParamReport.Rejection.Reason
            switch registry.write(value, to: entry.name) {
            case nil: reason = .unknownName
            case .typeMismatch: reason = .typeMismatch
            case .notInChoices: reason = .notInChoices
            case .notFinite: reason = .notFinite
            case .applied:
                continue
            case .clamped(let requested, let applied):
                result.clamped.append(
                    .init(name: entry.name, requested: requested, value: applied))
                continue
            }
            result.discarded.append(.init(name: entry.name, reason: reason))
            mismatched.append(.init(name: entry.name, reason: reason))
        }
        announce(mismatched: mismatched, unreadable: unreadable)
        return result
    }

    /// 保存そのものが読めなかったことを言う。値は 1 つも戻さない。
    private func sayUnreadable(_ error: any Error) {
        warn(
            "Could not read the saved values (\(url.path)): \(Diagnostics.reason(error)). "
                + "Starting from the defaults")
    }

    /// 捨てたことを名指しで言う。
    ///
    /// **捨てたことを黙らない** ([ADR-0030] 決定 6)。宣言を変えたあとで値が既定に戻る
    /// のは正しい振る舞いだが、理由が出ないと「なぜか既定値に戻る」としか見えない。
    ///
    /// 文言の組み立ては純関数 (``notice(for:unreadable:)``) に置く。標準エラーへ実際に出た行は
    /// 検査から読めないので、**読めるのは組み立てのほうだけ**である。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private func announce(mismatched: [ParamReport.Rejection], unreadable: [ParamReport.Rejection]) {
        guard let notice = Self.notice(for: mismatched, unreadable: unreadable) else { return }
        warn(notice)
    }

    /// 捨てたものを人へ伝える 1 行。捨てていなければ `nil`。
    ///
    /// - Parameters:
    ///   - discarded: 読めたが宣言と合わなかったもの。**宣言が変わったせい**と言う
    ///   - unreadable: 保存の中で読めなかったもの (知らない型・形の違う値・収まらない数・名前の
    ///     無い 1 件)。宣言とは関わりが無いので、**宣言が変わったとは言わない** (#2806)
    static func notice(
        for discarded: [ParamReport.Rejection], unreadable: [ParamReport.Rejection] = []
    ) -> String? {
        var parts: [String] = []
        if !discarded.isEmpty {
            let listed = discarded
                .map { "\($0.name) (\(reason(for: $0.reason)))" }
                .joined(separator: " / ")
            // 非有限で捨てたものも宣言が変わったせい: 保存はこのライブラリが書くので有限の数しか
            // 入っておらず、読み替えて無限になるのは、宣言の型が変わったとき (`Double` で宣言していた
            // 値を `Float` へ変えた、など。どちらも `float` を名乗るので型の違いにならない)
            parts.append(
                "Threw away \(discarded.count) of the saved values: \(listed). "
                    + "The declarations have changed, so these stay at their defaults")
        }
        if !unreadable.isEmpty {
            let listed = unreadable
                .map { "\($0.name.isEmpty ? "(a value without a readable name)" : $0.name) (\(unreadableReason(for: $0.reason)))" }
                .joined(separator: " / ")
            parts.append(
                "Could not read \(unreadable.count) of the saved values: \(listed). "
                    + "These stay at their defaults")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func reason(for reason: ParamReport.Rejection.Reason) -> String {
        switch reason {
        case .unknownName: "no longer declared"
        case .typeMismatch: "a different type from the declaration"
        case .notInChoices: "outside the choices that are allowed"
        case .notFinite: "not a finite number once read as the declared type"
        }
    }

    /// 読めなかった 1 件の理由。`unknownName` は名前が先の規則で、中身が読めなくても名前が宣言に無い。
    private static func unreadableReason(for reason: ParamReport.Rejection.Reason) -> String {
        switch reason {
        case .unknownName: "no longer declared"
        case .typeMismatch: "not written as a value of the type it names"
        case .notInChoices: "outside the choices that are allowed"
        case .notFinite: "a number too large to read"
        }
    }

    // MARK: - 書く

    /// 1 フレーム進める。静かになっていれば書く。
    ///
    /// **値が変わったかは、ここで印を取って知る** (``DeclarationWatcher``)。main actor を
    /// 譲らずに回すループでも、`draw` の中で変えた値がここで届く (#1704)。
    func tick() {
        takeDeclarationChange()
        guard let remaining = countdown else { return }
        guard remaining > 1 else {
            countdown = nil
            write()
            return
        }
        countdown = remaining - 1
    }

    /// いますぐ書く。
    ///
    /// **外からの書き込みが起こした変化は即時に書く** ([ADR-0030] 決定 6) — 書いた側は
    /// 反映を見に来るので、静かになるのを待たせない。値が変わったという印は次の
    /// ``tick()`` まで読まれないので、それを待たずにここで書き切る。書き切ったので、
    /// 立っている印は ``write()`` が下ろす (同じ中身をもう 1 度書かない)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    func flushNow() {
        countdown = nil
        write()
    }

    /// 値が変わったという知らせを受けた。**静かになるまで待ってから書く。**
    func declarationsChanged() { countdown = Self.quietFrames }

    /// まとめている途中のものがあれば書く。終わるときに呼ぶ。
    ///
    /// **最後のフレームで変わった値も書く。** その変化はまだ ``tick()`` を通っていないので、
    /// ここでも印を取る。
    func flushIfPending() {
        takeDeclarationChange()
        guard countdown != nil else { return }
        flushNow()
    }

    /// いまの値を置く。**原子的に書く** ([ADR-0018] 決定 3) — 読み手が書きかけを
    /// 掴むと、合わせた値がまとめて既定へ戻る。
    ///
    /// **書く姿には、立っている印の変化がもう入っている** ので、印は下ろす
    /// (``DeclarationWatcher/coverDeclarationChange()``)。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    private func write() {
        coverDeclarationChange()
        let saved = Saved(
            values: registry.declarations.map { Saved.Entry(name: $0.name, value: $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        // 書けなければ型と理由を名乗る (#2263)。非有限の数が 1 つ載っているだけで全部が
        // 書けなくなるので、どの値かも言う
        let data: Data
        do {
            data = try encoder.encode(saved)
        } catch {
            let offender = Self.offender(of: error, in: saved).map { ": `\($0)` was refused" }
            sayWriteFailure(
                "Could not encode the values as they stand to save them (\(url.path))"
                    + (offender ?? "") + " — \(Diagnostics.reason(error))")
            return
        }
        do {
            try AtomicFile.write(data, to: url)
        } catch {
            sayWriteFailure(
                "Could not save the values as they stand (\(url.path)): \(Diagnostics.reason(error))")
            return
        }
        lastWriteFailure = nil
        writeCount += 1
    }

    /// 書けなかった理由を言う。**前と同じ理由なら言わない** (``lastWriteFailure``)。
    private func sayWriteFailure(_ message: String) {
        defer { lastWriteFailure = message }
        guard message != lastWriteFailure else { return }
        warn(message)
    }

    /// 符号化が拒んだ値の名前。拒まれた場所が値の並びの中でなければ `nil`。
    private static func offender(of error: any Error, in saved: Saved) -> String? {
        guard case EncodingError.invalidValue(_, let context) = error,
            let index = context.codingPath.lazy.compactMap(\.intValue).first,
            saved.values.indices.contains(index)
        else { return nil }
        return saved.values[index].name
    }
}

extension ParamStore {
    /// 戻した結果。
    struct Restoration: Equatable {
        /// 範囲へ収めて戻したもの。
        var clamped: [ParamReport.Clamp] = []
        /// 宣言と合わなくて捨てたもの。
        var discarded: [ParamReport.Rejection] = []

        var isEmpty: Bool { clamped.isEmpty && discarded.isEmpty }
    }

    /// 保存の中身。
    ///
    /// 値の名乗り方は面と同じ `{"type", "value"}` である ([ADR-0030] 決定 4 —
    /// 同じ意味の表現を 2 つ持たない)。**やりとりの形ではない**ので `Schemas/` には
    /// 置かない — 要求も応答も受け取らず、読むのはこのライブラリだけである。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    struct Saved: Codable {
        var schemaVersion = ParamStore.schemaVersion
        let values: [Entry]

        /// 1 件ぶん。**面が読み書きするものと同じ形** (``NamedParamValue``)。
        typealias Entry = NamedParamValue
    }

    /// 保存を**読む**ときの形。書く形 (``Saved``) と同じ JSON を、1 件ずつ緩く読む。
    ///
    /// 素の ``NamedParamValue`` で読むと、知らない `type`・`1e400`・整数でない `int` のどれか
    /// 1 件で `JSONDecoder` が配列ごと・保存ごと断り、**読めた値まで全部捨てて**、最初の応答の
    /// `discarded` にも何も載らなかった ([#2806](https://github.com/mokume-metal/mokume/issues/2806))。
    /// 要求の 1 件ずつの読み (``ParamRequest/Entry``・#2496) をそのまま使い、読めなかった 1 件だけを
    /// 同じ理由で名指す ([ADR-0030] 決定 6「捨てたことを応答と診断に出す」)。`schemaVersion` は
    /// 読まない (版で読み分けるものが無い)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    struct SavedReading: Decodable {
        let values: [ParamRequest.Entry]
    }
}
