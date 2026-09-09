// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// × を押した人に問う言葉。
///
/// **問いを持つのは、窓を持つ側である。** 窓は 2 つの経路から出る — 道具のプロセスが持つ
/// 窓 (``SharedFrameStage``) と、走っているスケッチ自身が持つ窓 (``SketchApplication``) で、
/// **どちらも押し間違いで作品を終わらせうる**。出し方をここに 1 つ持ち、何と言うかは
/// 窓を持つ側が決める。
///
/// 言葉を型に持たせないのは、押した後どうなるかが経路で違うためである — 見張りは
/// 「見張りごと終わる」と言い、`run` は「`mokume run` も終わる」と言う。
struct CloseQuestion {
    /// 見出し。
    let message: String
    /// 添える説明。**押した後どうなるかを書く場所**である。
    let detail: String
    /// 閉じる側の押しどころ。
    let confirm: String
    /// 閉じない側の押しどころ。
    let cancel: String

    /// 問いの出し方。**窓へシートを下ろす。**
    ///
    /// **別の窓として出さない。** 道具は同じ見た目の窓を 2 つ出すので、独立した窓で問うと
    /// どの窓を閉じようとしたのかが消える。
    ///
    /// - Parameters:
    ///   - window: シートを下ろす窓。
    ///   - answer: 閉じてよいと答えたら `true`。
    @MainActor
    static func presentSheet(
        _ question: CloseQuestion, on window: NSWindow, answer: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = question.message
        alert.informativeText = question.detail
        // **続ける側を先に置く。** AppKit は最初のボタンを既定にする (Return で通る) ので、
        // 順序がそのまま「うっかり押したときにどちらへ倒れるか」を決める — 見張りから
        // 本番を回していることがあるので、倒れる先は**終えない側**でなければならない
        // ([ADR-0032] 決定 1)
        //
        // [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
        alert.addButton(withTitle: question.cancel)
        alert.addButton(withTitle: question.confirm)
        // **Esc は割り当てない。** `NSAlert` が Esc を自前で足すのは "Cancel" という綴りの
        // ボタンだけなので、それ以外の綴りでは効かない。手で足すと Return を持つ既定ボタンと
        // 同じ 1 つの割り当てを奪い合い、**安全側の Return が消える** — 押しどころは
        // どちらも見えているので、失うほうが高い
        alert.beginSheetModal(for: window) { answer($0 == .alertSecondButtonReturn) }
    }
}
