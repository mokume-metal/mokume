// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

// アンブレラだけを import する。個別モジュールを import しないことで、
// 「1 つの import で届く」(ADR-0016 決定 2) が実際に成立しているかの検査になる。
import mokume

@Suite("パッケージの骨格")
struct PackageStructureTests {
    @Test("アンブレラ 1 つで描画コアの API に届く")
    func umbrellaReExportsCore() {
        // 層をまたいだ依存はビルドが担保するので (ADR-0016 影響)、ここで見るのは
        // 「利用者の入口が 1 つで済んでいるか」だけ。
        let color = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        #expect(color.alpha == 1)
    }

    // 手本 (Processing / p5) が持つ三角関数はアンブレラ経由で届く (ADR-0020 決定 7・#193)。
    // 時刻から位置を出すのはスケッチの最初の 1 行目にやることなので、ここで
    // `import Foundation` が要らないことが原則 1 の担保になる。
    //
    // 値そのものは Darwin の実装が正で、ここで確かめたいのは**届いているか**だけ。
    // だから 7 本すべてを 1 度ずつ呼び、代表的な既知の値と突き合わせるに留める。
    @Test("アンブレラ 1 つで手本の三角関数に届く")
    func umbrellaReExportsTrigonometry() {
        #expect(sin(Float(0)) == 0)
        #expect(cos(Float(0)) == 1)
        #expect(tan(Float(0)) == 0)
        #expect(asin(Float(0)) == 0)
        #expect(acos(Float(1)) == 0)
        #expect(atan(Float(0)) == 0)
        // ここだけ許容差で見る。`atan2(1, 0)` は Float では `Float.pi / 2` の 1 ulp 隣に
        // 落ちるので、厳密な一致で書くと**届いているのに赤くなる**。
        #expect(abs(atan2(Float(1), Float(0)) - .pi / 2) < 1e-6)
    }

    // 起動できなかったときの文面が、アンブレラしか見えない場所から読めるか (#600)。
    //
    // **この suite でしか書けない検査である。** 文面の中身を見る `StartupFailureTests` は
    // `@testable import MokumeCore` なので internal まで見えてしまい、「外から届くか」を
    // 見られない。参照スケッチ (`Sketches/`) が見ているのはここと同じ視界で、届いて
    // いなかったせいで内部の名前のまま落ちていた。
    //
    // 中身の網羅はあちらが持つので、ここでは**届いていること**だけを 1 つの case で見る。
    @Test("アンブレラ 1 つで起動失敗の文面に届く")
    func umbrellaReachesTheStartupFailureMessage() {
        let text = "\(RenderFailure.shaderSourceMissing(name: "Shapes.metal"))"
        // 何が足りないか (1 行目) と、次にすること (続く行) の 2 段になっている
        #expect(text.split(separator: "\n").count >= 2)
        #expect(text.contains("Shapes.metal"))
        #expect(text.contains(".bundle"))
        // 内部の名前が出ない。`\(...)` が case の綴りへ戻ったらここが赤くなる
        #expect(!text.contains("shaderSourceMissing"))
        #expect(!text.contains("RenderFailure"))
    }
}
