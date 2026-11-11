// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 選ばせるダイアログの頼み (``SketchPart/selectInput(_:)``・``SketchPart/selectOutput(_:)``・
/// ``SketchPart/selectFolder(_:)``) の待ち。
///
/// **1 度に待てるのは 1 つで、3 つの API で共有する** ([#3062](https://github.com/mokume-metal/mokume/issues/3062)・
/// [#3707](https://github.com/mokume-metal/mokume/issues/3707))。待ちの最中にもう 1 度頼まれたら、どの API からでも、
/// 前の待ちは取り消しと同じ `nil` で終える。要求に番号を振って同時に複数を待つ形は、複数を同時に待つ作例が
/// 無いので採らなかった。何を選ばせるかは頼みの種類 (``Kind``) が持ち、ウィンドウを持つ側が種類に合うパネルを出す。
///
/// ## 頼みと結果の道
///
/// ダイアログを出すのはウィンドウを持つ側である — 自前のウィンドウでは ``SketchApplication``、`mokume watch` の道具のウィンドウでは
/// ``SharedFrameStage`` ([ADR-0032] 決定 1)。ここは**頼みを通し番号つきで控える**だけで、ウィンドウを持つ側が
/// ``pending`` を読んでパネルを出す。結果は入力の出来事 (``InputEvent/fileSelected(path:serial:)``) として
/// 合流点へ届き、フレームの頭で ``resolve(_:serial:)`` が待ちを終える。**待ちが終わる時刻はフレームの頭であり、
/// `await` が戻る時刻がどのフレームの境界かは [#2760](https://github.com/mokume-metal/mokume/issues/2760)
/// が決める。**
///
/// ## 結果は、どの頼みへの答えかを名乗れる
///
/// ウィンドウを持つ側が子へ送る結果には、頼みの通し番号 (``Request/serial``) を載せる。**番号つきの結果は、いまの待ちと
/// 番号が同じときだけ待ちを終える** — 待ちの最中に頼み直したとき、前の頼みへの古い答えが管や溜まりに残って
/// いても、新しい待ちは終わらない。番号があるので、ウィンドウを持つ側は頼みが残っている間、落ちた結果を送り直せる
/// (送り直しが重なっても、待ちを終えるのは 1 度)。外から番号なしで送る結果は、いまの待ちへ届く。
///
/// 合流点 (``InputState``) が持つ。結果は合流点を通って届くので、待っているかを外から送る入口
/// (``InputInbox``) が読める形にしておく。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class SelectionBroker {
    /// 何を選ばせるか。ウィンドウを持つ側は種類に合うパネルを出す (``FilePicker``)。
    enum Kind: String, CaseIterable, Sendable {
        /// 在るファイルを 1 つ (``SketchPart/selectInput(_:)``)。
        case file
        /// 保存先 (``SketchPart/selectOutput(_:)``)。まだ無いファイルの名前も選べる。
        case output
        /// フォルダを 1 つ (``SketchPart/selectFolder(_:)``)。
        case folder
    }

    /// ウィンドウを持つ側へ渡す頼み。通し番号は 1 から数え、頼むたびに進む (種類を問わず 1 つの列)。
    struct Request: Equatable, Sendable {
        let serial: Int
        let prompt: String
        let kind: Kind

        init(serial: Int, prompt: String, kind: Kind = .file) {
            self.serial = serial
            self.prompt = prompt
            self.kind = kind
        }
    }

    /// いま待っている頼み。待っていなければ `nil`。
    private(set) var pending: Request?
    private var waiting: CheckedContinuation<String?, Never>?
    private var issued = 0
    /// 実行が終わったか (``end()``)。終わった後の頼みは待たずに `nil` で返す。
    private(set) var isEnded = false

    /// 結果を待っているか。
    var isAwaiting: Bool { waiting != nil }

    /// 頼んで、結果が届くまで待つ。**取り消しは `nil`。**
    ///
    /// 待ちの最中なら、**前の頼みの種類を問わず**前の待ちを `nil` で終えてから新しく頼む。**実行が終わった後なら、
    /// 待たずに `nil` を返す** (結果を届ける合流点がもう配られない — 待てば返らない・[#3062](https://github.com/mokume-metal/mokume/issues/3062))。
    func request(_ prompt: String, kind: Kind = .file) async -> String? {
        guard !isEnded else { return nil }
        resolve(nil)
        issued += 1
        let request = Request(serial: issued, prompt: prompt, kind: kind)
        return await withCheckedContinuation { continuation in
            waiting = continuation
            pending = request
        }
    }

    /// 待ちを結果で終える。待っていなければ何もしない。
    ///
    /// - Parameter serial: **どの頼みへの答えか。** 載っていれば、いまの待ちと同じ番号のときだけ終える —
    ///   前の待ちの古い答えや、終わった待ちの送り直しが、いまの待ちを終えない。`nil` (外から番号なしで送る結果)
    ///   はいまの待ちを終える。
    /// - Returns: 待ちを終えたか。
    @discardableResult
    func resolve(_ path: String?, serial: Int? = nil) -> Bool {
        guard let continuation = waiting else { return false }
        if let serial, serial != pending?.serial { return false }
        waiting = nil
        pending = nil
        continuation.resume(returning: path)
        return true
    }

    /// 実行が終わった。**待ちを `nil` で終え、これからの頼みは待たせない。**
    ///
    /// 終わった実行の `Task` は残りうる (中で起こした `Task` は、実行より長く生きる)。結果を届ける
    /// 合流点はもう配られないので、待たせると返らない。
    func end() {
        isEnded = true
        resolve(nil)
    }
}
