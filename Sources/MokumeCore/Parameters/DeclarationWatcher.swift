// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Observation
import Synchronization

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
/// 張り直しをここ (``takeDeclarationChange()``) に閉じ込めたので、書き出しの経路が増えても
/// 見張りは死なない。
///
/// ## 知らせは運ばず、印を立てるだけにする
///
/// 知らせを受けたら**その場で印を立てるだけ**で、扱うのはフレームの境目で印を取る側
/// (``takeDeclarationChange()``) である。
///
/// かつては知らせを `Task { @MainActor … }` で main actor へ積み、それが走ったときに扱って
/// いた。main actor を譲らずに ``SketchRuntime/advance()`` を回すループ (窓を出さない書き出しや
/// 検査) では積んだ `Task` が 1 本も走らず、`draw` の中で変えた値が**保存にも区画にも
/// 届かなかった** ([#1704](https://github.com/mokume-metal/mokume/issues/1704))。誰が
/// `advance()` を叩くかは外側の話 (``SketchRuntime`` の説明) なので、叩き方で届き方が
/// 変わってはならない。
///
/// 印を取るのは、保存が 1 フレーム進むとき・閉じる前に書き切るとき、区画が要求を見に来る
/// とき — どれも**フレームの境目**で、描いている最中ではない。だから「描いている最中に
/// ファイルを書かない」([ADR-0013] 決定 1) は保たれる。譲るループでは、印が立つのが
/// 「フレームの間に `Task` が走ったとき」から「値を書いたその場」へ早まるだけで、読むのは
/// どちらも次のフレームの境目なので、**書く時機は変わらない**。
///
/// ## なぜ ``ParamRegistry`` の口ではないのか
///
/// 索引の側に生やすほうが部品は増えない ([ADR-0008] 決定 5 の段 1) が、`onChange` は
/// `@Sendable` なので**索引そのものを閉じ込められない** (中身は main actor に載った箱で
/// ある)。閉じ込めるのは `Sendable` な印 (``DeclarationNotice``) だけにし、張り直しは
/// 持ち主を通って索引へ届く。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
protocol DeclarationWatcher: AnyObject {
    /// 見張る先。
    var registry: ParamRegistry { get }

    /// 値が変わったという印。持ち主ごとに 1 つ持つ。
    var declarationNotice: DeclarationNotice { get }

    /// 値が変わったという知らせを受けたときにすること。
    ///
    /// **張り直しはここに書かない** — ``takeDeclarationChange()`` が引き受ける。
    func declarationsChanged()
}

extension DeclarationWatcher {
    /// 見張りを張る。知らせを受けたら印を立てる。
    ///
    /// **持ち主を捕まえない。** 捕まえるのは印だけなので、見張りが持ち主を生かし続ける
    /// ことはない。
    func watchDeclarations() {
        let notice = declarationNotice
        withObservationTracking {
            _ = registry.declarations
        } onChange: {
            notice.raise()
        }
    }

    /// 印が立っていれば下ろし、**張り直してから** ``declarationsChanged()`` を呼ぶ。
    /// フレームの境目で呼ぶ。
    func takeDeclarationChange() {
        guard declarationNotice.take() else { return }
        watchDeclarations()
        declarationsChanged()
    }
}

/// 値が変わったという印。
///
/// **知らせは変更した糸でその場に届く** (`onChange` は値を書く直前に同期で呼ばれる) ので、
/// ここは印を立てるだけにして、main actor へ何も積まない。`onChange` は `@Sendable` なので、
/// 印は糸をまたいで触れる形で持つ。
nonisolated final class DeclarationNotice: Sendable {
    private let raised = Atomic(false)

    /// 印を立てる。
    func raise() { raised.store(true, ordering: .releasing) }

    /// 印を取る。**立っていたかを返し、下ろす。**
    func take() -> Bool { raised.exchange(false, ordering: .acquiring) }
}
