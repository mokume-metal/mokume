// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// ファイルを選ばせるダイアログを出す口。
///
/// **窓を持つ側 (``SketchApplication`` と ``SharedFrameStage``) が、これを通して出す。** 差し替えられる形に
/// してあるのは、検査が機材も人の操作も無しに、結果の取り消し・選択を作れるようにするため
/// ([ADR-0041](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md)
/// 基準 4・[#3062](https://github.com/mokume-metal/mokume/issues/3062))。
@MainActor
protocol FilePicker {
    /// ダイアログを出す。結果は `completion` へ 1 回 — 選んだファイルの絶対パスか、取り消しの `nil`。
    ///
    /// - Parameters:
    ///   - prompt: ダイアログに添える文言。
    ///   - window: 出す窓。見えていれば、その窓のシートとして出す。
    /// - Returns: 結果を捨ててダイアログを閉じる口。新しい頼みが来たときや、待ちが終わったときに呼ぶ。
    ///   呼んだ後は `completion` が呼ばれない。
    func pick(
        prompt: String, over window: NSWindow?, completion: @escaping @MainActor (String?) -> Void
    ) -> @MainActor () -> Void
}

/// 本物の `NSOpenPanel` で出す。選べるのはファイル 1 つだけ (フォルダや複数は選ばせない)。
@MainActor
struct OpenPanelPicker: FilePicker {
    func pick(
        prompt: String, over window: NSWindow?, completion: @escaping @MainActor (String?) -> Void
    ) -> @MainActor () -> Void {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        let state = State()
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard !state.discarded else { return }
            state.discarded = true
            completion(response == .OK ? panel.url?.path : nil)
        }
        // **道具のプロセスは、触っている窓の持ち主ではないことがある** (他のアプリから戻ってきた直後など)。
        // 前に出さないとパネルが他の窓の後ろに隠れる
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
        return {
            // 結果を捨てる印を先に立ててから閉じる (閉じると取り消しの結果が来るため)
            state.discarded = true
            panel.cancel(nil)
        }
    }

    @MainActor private final class State {
        var discarded = false
    }
}
