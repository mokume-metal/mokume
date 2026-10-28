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
/// いてよい。**コードの既定値を書いた時点から変えた値は、保存を捨ててコードが勝つ** — 保存は書いた
/// 時点の既定値を併記する ([ADR-0030] 決定 6 の改訂 (2026-10-28)・[#2402](https://github.com/mokume-metal/mokume/issues/2402))。
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
            // 在るのにファイルとして読めない (置き場がディレクトリ・権限が無い) 保存も、戻せずに捨てた
            // ことに変わりはないので、外枠が読めない保存と同じく最初の応答に載せる (下)
            return Self.unreadableSave(sayingWhy: error, at: url, warn)
        }
        let entries: [ParamRequest.Entry]
        let savedDefaults: [String: ParamValue]
        do {
            let reading = try JSONDecoder().decode(SavedReading.self, from: data)
            entries = reading.values
            savedDefaults = reading.defaultsByName
        } catch {
            return Self.unreadableSave(sayingWhy: error, at: url, warn)
        }

        var result = Restoration()
        // 捨てたものは 2 つに分けて控える。言い方が違う (``notice(for:unreadable:)``)
        var mismatched: [ParamReport.Rejection] = []
        var unreadable: [ParamReport.Rejection] = []
        var defaultChanged: [DefaultChange] = []
        // 当てる順は名前順で、同じ名前は書いた順 (要求と同じ鍵・#858)。保存の並びや並べ替えの
        // 安定性に結果が依ると、同じ保存から違う姿が出る
        for entry in ParamRequest.inApplicationOrder(entries) {
            // **読めなかった 1 件は、その 1 件だけ捨てて名指しし、残りは戻す** (#2806)。宣言に無い
            // 名前は、中身が読めたかに依らず宣言が変わった側で言う (名前が先)
            if let refusal = entry.refusal(declaredIn: registry) {
                result.discarded.append(refusal)
                if refusal.reason == .unknownName {
                    mismatched.append(refusal)
                } else {
                    unreadable.append(refusal)
                }
                continue
            }
            guard case .value(let value) = entry.reading else { continue }
            // **コードの既定値が、保存に書いた時点から変わった値は、保存を戻さない** ([ADR-0030] 決定 6 の
            // 改訂 (2026-10-28)・#2402)。型の食い違いと候補の外は、いままでの理由が先に言う。
            // 保存が既定値を持たない (古い形式・既定値を持たない宣言) ものは、名前と型だけで戻る
            switch Self.defaultChange(
                for: entry.name, saved: value, savedDefaults: savedDefaults, in: registry)
            {
            case nil:
                break
            case .nothingLost:
                // 前の既定値と同じだった値 (触っていない) と、新しい既定値と同じ値 (書き戻した) は、
                // 失うものが無いので黙る。どちらも新しい既定値のまま
                continue
            case .lost(let change):
                result.discarded.append(.init(name: change.name, reason: .defaultChanged))
                defaultChanged.append(change)
                continue
            }
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
        announce(mismatched: mismatched, unreadable: unreadable, defaultChanged: defaultChanged)
        return result
    }

    /// 保存そのものが読めなかった。値は 1 つも戻さず、標準エラーへ 1 行言う。
    ///
    /// **捨てたことは最初の応答にも載せる** ([#2806](https://github.com/mokume-metal/mokume/issues/2806)・
    /// ADR-0030 決定 6)。ファイルとして読めない (置き場がディレクトリ・権限が無い) ときも、外枠が
    /// 読めない (JSON でない・`values` が配列でない) ときも、名指しする相手が無いので、要求の外枠が
    /// 読めないとき (#2550) と同じく名前の読めない 1 件にする。
    private static func unreadableSave(
        sayingWhy error: any Error, at url: URL, _ warn: (String) -> Void
    ) -> Restoration {
        warn(
            "Could not read the saved values (\(url.path)): \(Diagnostics.reason(error)). "
                + "Starting from the defaults")
        return Restoration(discarded: [.init(name: "", reason: .typeMismatch)])
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
    private func announce(
        mismatched: [ParamReport.Rejection], unreadable: [ParamReport.Rejection],
        defaultChanged: [DefaultChange]
    ) {
        guard
            let notice = Self.notice(
                for: mismatched, unreadable: unreadable, defaultChanged: defaultChanged)
        else { return }
        warn(notice)
    }

    /// コードの既定値が、保存に書いた時点から変わったために捨てた値 1 件。
    struct DefaultChange: Equatable {
        let name: String
        /// 捨てた保存の値。
        let saved: ParamValue
        /// 保存に書いた時点の既定値。
        let previousDefault: ParamValue
        /// いまのコードの既定値。
        let newDefault: ParamValue
    }

    /// 保存の値 1 件を、コードの既定値の変化に照らす。**当たらなければ `nil`** (いままでの規則で戻す)。
    ///
    /// 当たるのは、保存がその宣言の既定値を持ち、今のコードの既定値と違い、型が同じで、文字の候補の
    /// 外でないときだけである (型の食い違いと候補の外は、いままでの理由が先に言う)。当たったうえで、
    /// 保存の値が前の既定値と同じ (触っていない) か、いまの既定値と同じ (書き戻した) なら失うものが
    /// 無く、そうでなければ合わせた値を捨てる。
    enum DefaultChangeVerdict: Equatable {
        case nothingLost
        case lost(DefaultChange)
    }

    static func defaultChange(
        for name: String, saved: ParamValue, savedDefaults: [String: ParamValue],
        in registry: ParamRegistry
    ) -> DefaultChangeVerdict? {
        guard let previous = savedDefaults[name], let current = registry.defaultValue(of: name),
            previous != current, saved.paramType == current.paramType,
            previous.paramType == current.paramType
        else { return nil }
        if case .string(let text) = saved, let choices = registry.choices(of: name),
            !choices.contains(text)
        {
            return nil
        }
        guard saved != previous, saved != current else { return .nothingLost }
        return .lost(
            DefaultChange(name: name, saved: saved, previousDefault: previous, newDefault: current))
    }

    /// 捨てたものを人へ伝える 1 行。捨てていなければ `nil`。
    ///
    /// - Parameters:
    ///   - discarded: 宣言と合わなかったもの。**宣言が変わったせい**と言う。宣言に無い名前
    ///     (`unknownName`) は、中身が読めたかに依らずここに入る (名前が先)
    ///   - unreadable: 宣言のある名前で、中身が読めなかったもの (知らない型・形の違う値・収まらない
    ///     数) と名前の無い 1 件。理由は `typeMismatch` か `notFinite` だけが来る。宣言とは関わりが
    ///     無いので、**宣言が変わったとは言わない** (#2806)
    static func notice(
        for discarded: [ParamReport.Rejection], unreadable: [ParamReport.Rejection] = [],
        defaultChanged: [DefaultChange] = []
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
        if !defaultChanged.isEmpty {
            let listed = defaultChanged
                .map {
                    "\($0.name) (saved \(describe($0.saved)), the default was \(describe($0.previousDefault)), "
                        + "now \(describe($0.newDefault)))"
                }
                .joined(separator: " / ")
            parts.append(
                "Threw away \(defaultChanged.count) of the saved values because the default in the code changed "
                    + "since they were saved: \(listed). The code wins, so these start at the new defaults")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func reason(for reason: ParamReport.Rejection.Reason) -> String {
        switch reason {
        case .unknownName: "no longer declared"
        case .typeMismatch: "a different type from the declaration"
        case .notInChoices: "outside the choices that are allowed"
        case .notFinite: "not a finite number once read as the declared type"
        case .defaultChanged: "the default in the code changed since it was saved"
        }
    }

    /// 値を 1 行の中で名乗る形。型は名乗らない (名前の隣に並ぶ値は宣言の型で読める)。
    private static func describe(_ value: ParamValue) -> String {
        switch value {
        case .float(let number): "\(number)"
        case .int(let number): "\(number)"
        case .bool(let flag): "\(flag)"
        case .string(let text): "\"\(text)\""
        case .color(let color): "color(\(color.red), \(color.green), \(color.blue), \(color.alpha))"
        case .vector2(let vector): "(\(vector.x), \(vector.y))"
        case .vector3(let vector): "(\(vector.x), \(vector.y), \(vector.z))"
        }
    }

    /// 読めなかった 1 件の理由。読めなかった 1 件の断り (``ParamRequest/Entry/refusal(declaredIn:)``) が
    /// 宣言のある名前に付けるのは、`Double` に読めない数の `notFinite` と、それ以外の `typeMismatch`
    /// だけである (宣言に無い名前の `unknownName` は ``reason(for:)`` の側で言う)。
    private static func unreadableReason(for reason: ParamReport.Rejection.Reason) -> String {
        reason == .notFinite ? "a number too large to read" : "not written as a value of the type it names"
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
            values: registry.declarations.map { Saved.Entry(name: $0.name, value: $0.value) },
            defaults: registry.defaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        // 書けなければ型と理由を名乗る (#2263)。非有限の数が 1 つ載っているだけで全部が
        // 書けなくなるので、どの値かも言う。非有限の宣言は ``ParamRegistry/declarations`` が外す
        // (#2858) ので、ここへは通常届かない。届いたときに黙らないための守りとして残す
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
    static func offender(of error: any Error, in saved: Saved) -> String? {
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
        /// 戻せずに捨てたもの。**宣言と合わなかったものと、読めなかったものの両方が入る** —
        /// 読めなかった 1 件 (知らない型・形の違う値・収まらない数・名前の無い 1 件) と、保存そのものが
        /// 読めなかったときの名前の空の 1 件 (``unreadableSave(sayingWhy:at:_:)``) も含む (#2806)。
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
    ///
    /// **`defaults` は、書いた時点のコードの既定値** ([ADR-0030] 決定 6 の改訂 (2026-10-28)・
    /// [#2402](https://github.com/mokume-metal/mokume/issues/2402))。`values` の外の別の列に置くので、
    /// この列を知らない古い版の読み (``SavedReading``) は `values` だけを読み、いままでどおり名前と型で
    /// 戻す。`defaults` の無い保存 (古い版が書いたもの) は、既定値が変わったかを見ずに同じ規則で戻し、
    /// 次に書くときにこの列を足す。形は動かしていないので ``ParamStore/schemaVersion`` は 1 のまま。
    struct Saved: Codable {
        var schemaVersion = ParamStore.schemaVersion
        let values: [Entry]
        let defaults: [Entry]

        init(values: [Entry], defaults: [Entry] = []) {
            self.values = values
            self.defaults = defaults
        }

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
    ///
    /// **`defaults` は読めた 1 件だけを使う。** 列が欠けた・配列でない・1 件が読めないときは、その
    /// 宣言の既定値は「書かれていない」と見なして名前と型だけで戻す (既定値の列が壊れても、合わせた値を
    /// 道連れに捨てない)。
    struct SavedReading: Decodable {
        let values: [ParamRequest.Entry]
        let defaults: [ParamRequest.Entry]

        /// 名前から引く、保存に書いた時点の既定値。**同じ名前が並んでいれば最初の 1 件。**
        var defaultsByName: [String: ParamValue] {
            var byName: [String: ParamValue] = [:]
            for entry in defaults {
                guard case .value(let value) = entry.reading, byName[entry.name] == nil else { continue }
                byName[entry.name] = value
            }
            return byName
        }

        private enum CodingKeys: String, CodingKey {
            case values, defaults
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            values = try container.decode([ParamRequest.Entry].self, forKey: .values)
            defaults = (try? container.decode([ParamRequest.Entry].self, forKey: .defaults)) ?? []
        }
    }
}
