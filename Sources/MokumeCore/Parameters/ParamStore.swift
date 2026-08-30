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
final class ParamStore {
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
    private let registry: ParamRegistry
    /// 静かになるまでの残り。`nil` なら書くものが無い。
    private var countdown: Int?
    /// 実際に書いた回数。**まとめられていることを検査から見るために持つ。**
    private(set) var writeCount = 0

    /// 保存を持たせる。宣言が 1 つも無ければ持たせない (書くものが無い)。
    static func makeIfNeeded(for registry: ParamRegistry, at url: URL = WorkDirectory.savedParams)
        -> ParamStore?
    {
        registry.isEmpty ? nil : ParamStore(registry: registry, at: url)
    }

    init(registry: ParamRegistry, at url: URL = WorkDirectory.savedParams) {
        self.registry = registry
        self.url = url
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
        defer { watchValues() }
        guard let data = try? Data(contentsOf: url) else { return Restoration() }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            // 読めない保存は捨てて既定値で立ち上げる。**黙って捨てない** — 「なぜか
            // 既定値に戻る」は理由が出ないと追えない
            Diagnostics.warn("保存された値を読めませんでした (\(url.path))。既定値で始めます")
            return Restoration()
        }

        var result = Restoration()
        // 当てる順は名前順。保存の並びに結果が依ると、同じ保存から違う姿が出る
        for entry in saved.values.sorted(by: { $0.name < $1.name }) {
            switch registry.write(entry.value, to: entry.name) {
            case nil:
                result.discarded.append(.init(name: entry.name, reason: .unknownName))
            case .typeMismatch:
                result.discarded.append(.init(name: entry.name, reason: .typeMismatch))
            case .notInChoices:
                result.discarded.append(.init(name: entry.name, reason: .notInChoices))
            case .applied:
                break
            case .clamped(let requested, let applied):
                result.clamped.append(
                    .init(name: entry.name, requested: requested, value: applied))
            }
        }
        announce(result)
        return result
    }

    /// 捨てたことを名指しで言う。
    ///
    /// **捨てたことを黙らない** ([ADR-0030] 決定 6)。宣言を変えたあとで値が既定に戻る
    /// のは正しい振る舞いだが、理由が出ないと「なぜか既定値に戻る」としか見えない。
    ///
    /// 文言の組み立ては純関数 (``notice(for:)``) に置く。標準エラーへ実際に出た行は
    /// 検査から読めないので、**読めるのは組み立てのほうだけ**である。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private func announce(_ restoration: Restoration) {
        guard let notice = Self.notice(for: restoration.discarded) else { return }
        Diagnostics.warn(notice)
    }

    /// 捨てたものを人へ伝える 1 行。捨てていなければ `nil`。
    static func notice(for discarded: [ParamReport.Rejection]) -> String? {
        guard !discarded.isEmpty else { return nil }
        let listed = discarded
            .map { "\($0.name) (\(reason(for: $0.reason)))" }
            .joined(separator: " / ")
        return "保存されていた値のうち \(discarded.count) 個を捨てました: \(listed)。"
            + "宣言が変わっているので、これらは既定値のままです"
    }

    private static func reason(for reason: ParamReport.Rejection.Reason) -> String {
        switch reason {
        case .unknownName: "もう宣言されていない"
        case .typeMismatch: "宣言と型が違う"
        case .notInChoices: "許した候補の外"
        }
    }

    // MARK: - 書く

    /// 1 フレーム進める。静かになっていれば書く。
    func tick() {
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
    /// 反映を見に来るので、静かになるのを待たせない。値が変わったという知らせは
    /// Observation から**あとで**届くので、待たずにここで書き切る。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    func flushNow() {
        countdown = nil
        write()
    }

    /// まとめている途中のものがあれば書く。終わるときに呼ぶ。
    func flushIfPending() {
        guard countdown != nil else { return }
        flushNow()
    }

    /// 値が変わったことを Observation から受け取る。
    ///
    /// **フレームごとに値を数え直さない** ([ADR-0013] 決定 1)。見張りは 1 回きりなので、
    /// 知らせを受けた後に張り直す。
    ///
    /// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
    private func watchValues() {
        withObservationTracking {
            _ = registry.declarations
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                countdown = Self.quietFrames
                watchValues()
            }
        }
    }

    /// いまの値を置く。**原子的に書く** ([ADR-0018] 決定 3) — 読み手が書きかけを
    /// 掴むと、合わせた値がまとめて既定へ戻る。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    private func write() {
        let saved = Saved(
            values: registry.declarations.map { Saved.Entry(name: $0.name, value: $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        guard (try? AtomicFile.write(data, to: url)) != nil else {
            Diagnostics.warn("合わせた値を保存できませんでした (\(url.path))")
            return
        }
        writeCount += 1
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

        struct Entry: Codable {
            let name: String
            let value: ParamValue

            private enum CodingKeys: String, CodingKey {
                case name
            }

            init(name: String, value: ParamValue) {
                self.name = name
                self.value = value
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                value = try ParamValue(from: decoder)
            }

            func encode(to encoder: any Encoder) throws {
                try value.encode(to: encoder)
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
            }
        }
    }
}
