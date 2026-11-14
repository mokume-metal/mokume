// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeCore

/// 選ばせるダイアログ (ファイル・保存先・フォルダ) を出す口。
///
/// **ウィンドウを持つ側 (``SketchApplication`` と ``SharedFrameStage``) が、これを通して出す。** 差し替えられる形に
/// してあるのは、検査が機材も人の操作も無しに、結果の取り消し・選択を作れるようにするため
/// ([ADR-0041](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md)
/// 基準 4・[#3062](https://github.com/mokume-metal/mokume/issues/3062))。
@MainActor
protocol FilePicker {
    /// ダイアログを出す。結果は `completion` へ 1 回 — 選んだものの絶対パスか、取り消しの `nil`。
    ///
    /// - Parameters:
    ///   - prompt: ダイアログに添える文言。
    ///   - kind: 何を選ばせるか (在るファイル・保存先・フォルダ。[#3707](https://github.com/mokume-metal/mokume/issues/3707))。
    ///   - window: 出すウィンドウ。見えていれば、そのウィンドウのシートとして出す。
    /// - Returns: 結果を捨ててダイアログを閉じる口。新しい頼みが来たときや、待ちが終わったときに呼ぶ。
    ///   呼んだ後は `completion` が呼ばれない。
    func pick(
        prompt: String, kind: SelectionBroker.Kind, over window: NSWindow?,
        completion: @escaping @MainActor (String?) -> Void
    ) -> @MainActor () -> Void
}

/// 本物のパネルで出す。在るファイルとフォルダは `NSOpenPanel` で 1 つだけ (複数は選ばせない)、保存先は
/// `NSSavePanel` で出す。
@MainActor
struct OpenPanelPicker: FilePicker {
    func pick(
        prompt: String, kind: SelectionBroker.Kind, over window: NSWindow?,
        completion: @escaping @MainActor (String?) -> Void
    ) -> @MainActor () -> Void {
        let panel = Self.panel(for: kind)
        panel.message = prompt
        let state = State()
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard !state.discarded else { return }
            state.discarded = true
            completion(response == .OK ? panel.url?.path : nil)
        }
        // **道具のプロセスは、触っているウィンドウの持ち主ではないことがある** (他のアプリから戻ってきた直後など)。
        // 前に出さないとパネルが他のウィンドウの後ろに隠れる
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

    /// 種類に合うパネル。`NSOpenPanel` は `NSSavePanel` の子なので、出し方と結果の読み方は 1 つで済む。
    private static func panel(for kind: SelectionBroker.Kind) -> NSSavePanel {
        switch kind {
        case .output:
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            return panel
        case .file, .folder:
            let panel = NSOpenPanel()
            panel.canChooseFiles = kind == .file
            panel.canChooseDirectories = kind == .folder
            panel.canCreateDirectories = kind == .folder
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            return panel
        }
    }

    @MainActor private final class State {
        var discarded = false
    }
}
