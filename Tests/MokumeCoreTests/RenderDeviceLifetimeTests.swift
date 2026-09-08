// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 抱えた資源が土台を抱え返していないことの検査。GPU を要する。
///
/// ``RenderDevice`` が投入の完了まで資源を抱えるのは、投入した側がすぐ手放しても
/// GPU の実行中に消えないようにするためである。壊れるのは**抱えた資源が土台を
/// 抱え返している**ときで、環が成立すると土台は手放しても畳まれない。
///
/// 畳まれないことの帰結は 2 つある。`isolated deinit` が守っている「実行中のものが
/// 終わる前に土台を畳まない」([#727]) が一度も発火せず、居残った土台の GPU の仕事が
/// 次の実行と重なってどちらかが打ち切られる ([#1063] の実測)。
///
/// **経路ごとに 1 本ずつ置く。** 抱えた資源から土台へ戻る辺は 4 本あり、型ごとに
/// 弱くする手では漏れる ([#1076] の調査)。1 本だけ見ていると、別の経路が生えたときに
/// 黙って通る。
///
/// [#727]: https://github.com/mokume-metal/mokume/issues/727
/// [#1063]: https://github.com/mokume-metal/mokume/issues/1063
/// [#1076]: https://github.com/mokume-metal/mokume/issues/1076
@Suite(
    "土台の寿命",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RenderDeviceLifetimeTests {
    /// 数の並びの**先頭だけ**を読む塗り。
    ///
    /// 添字を振って読むと、渡していない列では範囲外読み出しになる ([#919])。
    /// この検査が見たいのは「並びを持つ塗りが載ったフレーム」なので、先頭で足りる。
    ///
    /// [#919]: https://github.com/mokume-metal/mokume/issues/919
    private static let readsNumbers = """
        float4 paint(Fragment in, Values values) {
            float v = in.numbers[0];
            return float4(v, v, v, 1);
        }
        """

    /// 何も読まない塗り。
    private static let plainPaint = """
        float4 paint(Fragment in, Values values) {
            return float4(1, 0, 0, 1);
        }
        """

    /// 受けた色をそのまま返す効果。
    private static let plainEffect = """
        float4 effect(Pixel in, Values values) {
            return in.color;
        }
        """

    /// 土台を作って `body` を 1 度だけ通し、手放した後に畳まれたかを返す。
    ///
    /// **`weak` で見るのがこの検査の要点である。** 環が成立していると `deinit` が
    /// 呼ばれないので、「畳むのに何秒かかったか」では区別が付かない — 畳んでいないから
    /// 速いのであって、実測では 0.1ms で返っていた ([#1076])。参照が nil になったか
    /// どうかだけが答えになる。
    private func deviceFolds(_ body: (Canvas) throws -> Void) async throws -> Bool {
        weak var weakGPU: RenderDevice?
        do {
            let gpu = try RenderDevice()
            weakGPU = gpu
            let canvas = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
            try body(canvas)
        }
        // **待つ側が期限を持つ** (`.timeLimit` は使わない・AGENTS.md)。畳まれるのは
        // 「投入が終わり、結末を受けた口が main actor で走った後」なので、手放した
        // その瞬間ではない。`await` で譲るのは、その口が main actor を要るからである
        let deadline = Date().addingTimeInterval(2)
        while weakGPU != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return weakGPU == nil
    }

    private func black() -> LinearRGBA { .display(red: 0, green: 0, blue: 0) }

    @Test("何も載せないフレームの後、土台は畳まれる")
    func plainFrameFoldsTheDevice() async throws {
        #expect(
            try await deviceFolds { canvas in
                try canvas.draw { canvas.background(black()) }
            },
            """
            何も載せていないフレームの後で土台が畳まれていない。

            この検査が赤いなら、環は下の 4 経路ではなく `held` そのもの (投入した
            コマンドか、その置き場) に在る。
            """)
    }

    @Test("利用者の塗りを載せたフレームの後も、土台は畳まれる")
    func shaderPathFoldsTheDevice() async throws {
        #expect(
            try await deviceFolds { canvas in
                let paint = try canvas.makeShader(Self.plainPaint)
                try canvas.draw {
                    canvas.background(black())
                    canvas.shader(paint)
                    canvas.rect(0, 0, 8, 8)
                }
            },
            """
            利用者の塗りを載せたフレームの後、土台が畳まれていない (経路 1)。

            抱えたフレームが塗りを持ち、塗りが土台を持ち返している
            ([#1076](https://github.com/mokume-metal/mokume/issues/1076))。
            """)
    }

    @Test("数の並びを読む塗りを載せたフレームの後も、土台は畳まれる")
    func numbersPathFoldsTheDevice() async throws {
        #expect(
            try await deviceFolds { canvas in
                let heat = try canvas.makeNumbers(count: 4)
                let paint = try canvas.makeShader(Self.readsNumbers)
                try canvas.draw {
                    canvas.background(black())
                    canvas.numbers(heat)
                    canvas.shader(paint)
                    canvas.rect(0, 0, 8, 8)
                }
            },
            """
            数の並びを読む塗りを載せたフレームの後、土台が畳まれていない (経路 2)。

            この経路は二次被害も連れてくる — `Numbers` の `deinit` が走らないので、
            置き場が常駐の集合から外れないまま残る
            ([#738](https://github.com/mokume-metal/mokume/issues/738) が閉じた穴)。
            """)
    }

    @Test("利用者の効果を載せたフレームの後も、土台は畳まれる")
    func effectPathFoldsTheDevice() async throws {
        #expect(
            try await deviceFolds { canvas in
                let pass = try canvas.makeEffect(Self.plainEffect)
                try canvas.draw {
                    canvas.background(black())
                    canvas.effects([.custom(pass)])
                }
            },
            """
            利用者の効果を載せたフレームの後、土台が畳まれていない (経路 3)。

            **この経路は 2 本ある** — 効果そのものと、その組み立て (pipeline → 表の
            置き場) の両方が土台を持つので、型ごとに弱くする手では切れない
            ([#1076](https://github.com/mokume-metal/mokume/issues/1076))。
            """)
    }

    @Test("絵を刻んだ後も、土台は畳まれる")
    func encodedImagePathFoldsTheDevice() async throws {
        #expect(
            try await deviceFolds { canvas in
                try canvas.draw { canvas.background(black()) }
                _ = try canvas.target.encodeToImage()
            },
            """
            絵を刻んだ後、土台が畳まれていない (経路 4)。

            出口を刺したスケッチが踏むのはこの経路である
            ([#1076](https://github.com/mokume-metal/mokume/issues/1076) の実測表)。
            """)
    }
}
