// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Observation

/// 宣言された値の変化を見張る側。
///
/// ## 張り直しを呼ぶ側に任せない
///
/// `withObservationTracking` の見張りは**1 回きり**である。知らせを受けたら張り直さ
/// なければ、2 度目の変化は届かない。
///
/// かつては面の側 (``ParamSurface``) が**書き出しの経路**で張り直していた — `publish()`
/// が最後に `watchValues()` を呼ぶ形で、**そこを通らない道ができた瞬間に見張りが死ぬ**。
/// 死んでも落ちも警告も出ず、症状は「つまみを動かしても面が更新されない」だけになる
/// ([#994](https://github.com/mokume-metal/mokume/issues/994) の 12)。保存の側
/// (``ParamStore``) は知らせの中で自分で張り直していたので、**同じ機構に規律が 2 通り
/// 並んでいた**。
///
/// 張り直しをここに閉じ込めたので、書き出しの経路が増えても見張りは死なない。
///
/// ## なぜ ``ParamRegistry`` の口ではないのか
///
/// 索引の側に生やすほうが部品は増えない ([ADR-0008] 決定 5 の段 1) が、`onChange` は
/// `@Sendable` なので**索引そのものを閉じ込められない** (中身は main actor に載った箱で
/// ある)。いまの形が成り立っているのは、張り直しが持ち主を通って索引へ届くからで、
/// その「持ち主を通る」ことこそがここで畳むものである。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// ## `Sendable` を名乗る理由
///
/// `onChange` は `@Sendable` なので、持ち主を弱く捕まえるには `Self` が `Sendable` で
/// なければならない。具体の型は main actor に載っているので暗黙に満たしているが、
/// 総称の `Self` にはそれが伝わらないので、ここで要求として書く。
protocol DeclarationWatcher: AnyObject, Sendable {
    /// 見張る先。
    var registry: ParamRegistry { get }

    /// 値が変わったという知らせを受けたときにすること。
    ///
    /// **張り直しはここに書かない** — ``watchDeclarations()`` が引き受ける。
    func declarationsChanged()
}

extension DeclarationWatcher {
    /// 見張りを張る。**知らせを受けたら自分で張り直す。**
    ///
    /// 知らせは隔離の外から届くので、扱いは main actor へ渡してから行う — 描いている
    /// 最中にファイルを書かないためである ([ADR-0013] 決定 1)。
    ///
    /// **持ち主は弱く持つ。** 手放されたら張り直しをやめる。
    ///
    /// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
    func watchDeclarations() {
        withObservationTracking {
            _ = registry.declarations
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                declarationsChanged()
                watchDeclarations()
            }
        }
    }
}
