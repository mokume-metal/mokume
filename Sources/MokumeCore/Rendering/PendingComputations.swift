// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// `@MainActor` を明示する理由は ``RenderDevice`` の冒頭と同じ (release のテストビルドで
// 暗黙の既定隔離が見失われる・#761)。

/// 計算が読む並びと書く並び。**頼んだ順の前後で、順序が要るかを決める規則を 1 か所に置く。**
///
/// 順序が要るのは、後から頼む側が次のどれかに当たるとき。どれも先に頼んだ側が先に走らないと、
/// 結果が決まらない ([#933]):
///
/// - 前が書いたものを読む
/// - 前が書いたものへ書く
/// - **前が読んだものへ書く**
///
/// 口の切れ目を導く規則 (`Canvas.groups(of:)`) と、面をまたいで頼んだ順を守る規則
/// (``PendingComputations``) が、この 1 つを共有する。識別子だけを見るので、GPU を持ち出さずに
/// 検査できる。
///
/// [#933]: https://github.com/mokume-metal/mokume/issues/933
struct ComputeAccess<ID: Hashable> {
    private(set) var reads: Set<ID>
    private(set) var writes: Set<ID>

    init(reads: [ID] = [], writes: [ID] = []) {
        self.reads = Set(reads)
        self.writes = Set(writes)
    }

    /// 先に頼んだ計算の全体 (これ) が、後から頼む `later` より先に走らなければならないか。
    func mustPrecede(_ later: ComputeAccess) -> Bool {
        !later.reads.isDisjoint(with: writes) || !later.writes.isDisjoint(with: writes)
            || !later.writes.isDisjoint(with: reads)
    }

    mutating func formUnion(_ other: ComputeAccess) {
        reads.formUnion(other.reads)
        writes.formUnion(other.writes)
    }
}

/// 未投入の計算を持ちうる面 (``Canvas``)。登録簿 (``PendingComputations``) が照会する。
@MainActor protocol PendingComputationHolder: AnyObject {
    /// 投入していない計算があるか。**並びを集めずに答える安い問い** — 相手が何も溜めていない
    /// 頼みは、読み書きの集合を作る前に抜ける。
    var hasPendingComputations: Bool { get }

    /// 投入していない計算が読む・書く並び。**先に頼んだ順を守る相手ではないもの (描かない間・
    /// 閉じ忘れて捨てられるフレーム) は空を返す。**
    var pendingAccess: ComputeAccess<ObjectIdentifier> { get }

    /// 投入していない計算を、待たずに投入する。
    func submitPendingComputations()
}

/// 未投入の計算を持つ面の登録簿。``RenderDevice`` が 1 つ持つ。
///
/// ## なぜ要るのか
///
/// 計算は面ごとに溜まり、その面の描き切りで流れる。だから本体で先に頼んだ計算より、描き場所で
/// 後から頼んだ計算のほうが先に走る (描き場所の `endDraw()` が先に描き切るため・[#1870])。
/// 頼んだ順に効かせるには、**後から頼む側が、先に頼まれた相手を知っている**必要がある。
/// 相手の溜めは面ごとなので、面をまたいで引ける名簿がここに要る。
///
/// ## 約束
///
/// > ある面の未投入の計算と、いま頼まれる計算が順序を要するなら、頼まれる前に、その面の
/// > 未投入分は投入されている。
///
/// 順序を要する頼みだけが相手を動かす。単一の面や、ぶつからない複数の面では、何も起きない。
/// 相手の溜めは丸ごと投入する — 溜めの中の順は保たれ、面どうしの溜めは互いにぶつからない
/// (ぶつかる頼みが来た時点で、先に頼んだ側が投入されているため)。
///
/// **持ち主は弱く持つ。** 持ち主は土台を強く持つので、強く持つと土台ごと畳まれなくなる
/// (``PendingUploads`` と同じ)。
///
/// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
@MainActor final class PendingComputations {
    private struct Entry {
        weak var holder: (any PendingComputationHolder)?
    }

    private var entries: [Entry] = []

    /// 載せる。既に載っていれば何もしない。
    ///
    /// **載っているかは名簿の中で見る。** 面に印を持たせない代わりに、頼むたびに名簿を舐める —
    /// 載る面は数枚なので、頼みの費用に比べて無視できる。手放された持ち主は `nil` になり、
    /// 使い回された番号と取り違えることもない。
    func enqueue(_ holder: any PendingComputationHolder) {
        guard !entries.contains(where: { $0.holder === holder }) else { return }
        entries.append(Entry(holder: holder))
    }

    /// 相手の溜めを引いた回数。**単一の面や、相手が何も溜めていない頼みでは増えない**ことを
    /// 検査が数で見る (絵にも投入の数にも出ない費用なので)。
    private(set) var accessLookups = 0

    /// `asker` 以外で、未投入の計算が `asked` より先に走らねばならないもの。載った順に並ぶ。
    ///
    /// **`asked` は引く必要があるときまで作らない** (`@autoclosure`)。単一の面では載っているのが
    /// `asker` だけで、複数の面でも相手が何も溜めていなければ、読み書きの集合を作らずに空を返す。
    func holders(
        mustPrecede asked: @autoclosure () -> ComputeAccess<ObjectIdentifier>,
        except asker: any PendingComputationHolder
    ) -> [any PendingComputationHolder] {
        entries.removeAll { $0.holder == nil }
        var candidates: [any PendingComputationHolder] = []
        for entry in entries {
            guard let holder = entry.holder, holder !== asker, holder.hasPendingComputations
            else { continue }
            candidates.append(holder)
        }
        guard !candidates.isEmpty else { return [] }
        accessLookups += 1
        let asked = asked()
        return candidates.filter { $0.pendingAccess.mustPrecede(asked) }
    }
}
