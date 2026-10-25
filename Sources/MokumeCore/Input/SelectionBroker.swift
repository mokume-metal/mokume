// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// ファイルを選ばせる頼み (``SketchPart/selectInput(_:)``) の待ち。
///
/// **1 度に待てるのは 1 つ** ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。待ちの最中にもう
/// 1 度頼まれたら、前の待ちは取り消しと同じ `nil` で終える。要求に番号を振って同時に複数を待つ形は、
/// 複数を同時に待つ作例が無いので採らなかった。
///
/// ## 頼みと結果の道
///
/// ダイアログを出すのは窓を持つ側である — 自前の窓では ``SketchApplication``、`mokume watch` の道具の窓では
/// ``SharedFrameStage`` ([ADR-0032] 決定 1)。ここは**頼みを通し番号つきで控える**だけで、窓を持つ側が
/// ``pending`` を読んでパネルを出す。結果は入力の出来事 (``InputEvent/fileSelected(path:)``) として
/// 合流点へ届き、フレームの頭で ``resolve(_:)`` が待ちを終える。**待ちが終わる時刻はフレームの頭であり、
/// `await` が戻る時刻がどのフレームの境界かは [#2760](https://github.com/mokume-metal/mokume/issues/2760)
/// が決める。**
///
/// 合流点 (``InputState``) が持つ。結果は合流点を通って届くので、待っているかを外から送る入口
/// (``InputInbox``) が読める形にしておく。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class SelectionBroker {
    /// 窓を持つ側へ渡す頼み。通し番号は 1 から数え、頼むたびに進む。
    struct Request: Equatable, Sendable {
        let serial: Int
        let prompt: String
    }

    /// いま待っている頼み。待っていなければ `nil`。
    private(set) var pending: Request?
    private var waiting: CheckedContinuation<String?, Never>?
    private var issued = 0

    /// 結果を待っているか。
    var isAwaiting: Bool { waiting != nil }

    /// 頼んで、結果が届くまで待つ。**取り消しは `nil`。**
    ///
    /// 待ちの最中なら、前の待ちを `nil` で終えてから新しく頼む。
    func request(_ prompt: String) async -> String? {
        resolve(nil)
        issued += 1
        let request = Request(serial: issued, prompt: prompt)
        return await withCheckedContinuation { continuation in
            waiting = continuation
            pending = request
        }
    }

    /// 待ちを結果で終える。待っていなければ何もしない。
    ///
    /// - Returns: 待ちを終えたか。
    @discardableResult
    func resolve(_ path: String?) -> Bool {
        guard let continuation = waiting else { return false }
        waiting = nil
        pending = nil
        continuation.resume(returning: path)
        return true
    }
}
