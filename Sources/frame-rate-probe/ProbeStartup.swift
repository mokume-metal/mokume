// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// frame-rate-probe が測り始める前の準備 (描画の土台と窓を作る) に失敗したときの名乗り。
//
// **裸の `try` に任せない** (#2541)。main.swift の最上位で投げられた失敗は Swift ランタイム
// の既定処理へ落ち、`Fatal error: Error raised at top level: …` の形で内部の姿をそのまま
// 出して trap する (終了コードも 1 ではない)。道具の入口は、失敗したら何が足りないかと次に
// することを名乗って `exit(1)` で落ちる規範 (#527・#600。正典は Sketches/main.swift の
// `exitReporting`) を、ここにも通す。
//
// 名乗る文面だけをここへ出して検査から呼べるようにしてある (main.swift の最上位は走らせると
// 窓を開いてしまう。FrameRateProbeTests)。

import Foundation

/// 測り始める前の準備に失敗したときの、標準エラーへ書く文面。
enum ProbeStartup {
    /// 何をしようとして失敗したか。**中身 (何が足りないか・次にすること) は失敗の側が持つ**
    /// ので、ここでは文面を組まず、見出しだけを足す。
    static let headline = "フレームレートの計測を始められませんでした。"

    /// 見出しと失敗の中身。末尾に改行を付けてそのまま書ける形で返す。
    static func message(for error: any Error) -> String {
        "\(headline)\n\(error)\n"
    }
}
