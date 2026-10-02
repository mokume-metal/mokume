// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

@testable import MokumeCore

extension RenderDevice {
    /// 絵や結果が期待と違ったときに、落ちた表明の文面へ添える説明。**この土台で打ち切りが
    /// 記録されていれば、その回数と理由を名乗る。** 無ければ空。
    ///
    /// GPU が仕事を打ち切ると、その絵は 1 画素も書かれないのに合図は投入の順に進むので、
    /// **待ちは成立したまま空の絵が読める** ([#1065])。これが無いと、症状は
    /// 「絵が黒い」「何成分違う」としてしか残らず、原因を console の知らせと機械の込み具合まで
    /// 辿り直すことになる — [#1063] と [#1812] の 1 回ずつがまさにそれだった。文面に載せれば、
    /// 記録の正本 (xunit) と run の要約にも残る。
    ///
    /// **表明を落とす条件にはしない。** 打ち切られたのが絵を作った投入とは限らず、
    /// 差し出しも読み戻しも同じ土台を通る。条件にすると**絵が無事な回まで赤くなる**
    /// (実測: 複数フレームを回す 2 本が、絵の食い違いなしにこれだけで落ちた)。
    ///
    /// **表明の文面 (`#expect` の 2 つ目の引数) の中で呼ぶ。** 文面は表明が落ちたときにだけ
    /// 組み立てられるので、下の待ちは通った表明の実行時間に出ない。
    ///
    /// 使っている所と、まだ使っていない所の扱いは [#1930]。
    ///
    /// [#1063]: https://github.com/mokume-metal/mokume/issues/1063
    /// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
    /// [#1812]: https://github.com/mokume-metal/mokume/issues/1812
    /// [#1930]: https://github.com/mokume-metal/mokume/issues/1930
    func faultNote() -> String {
        // **少し待ってから読む。** 結末は Metal 側の糸から届くので、絵を読み終えた時点
        // ではまだ来ていないことがある (実測: 絵が空で落ちた 4 回とも、その時点では 0 だった)。
        // ここを通るのは**表明が既に落ちた後**だけなので、待っても普段の実行時間には出ない
        if commandFaultCount == 0 { Thread.sleep(forTimeInterval: 0.1) }
        guard commandFaultCount > 0 else { return "" }
        return """

            (この間に GPU は仕事を \(commandFaultCount) 回打ち切っている: \
            \(lastCommandFault ?? "理由は届いていない")。
            打ち切られた絵は 1 画素も書かれていないので、食い違いはそのせいかもしれない)
            """
    }
}
