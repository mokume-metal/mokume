// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 同じシェーダの原文を 2 度組まないことを、組んだ回数で見る。GPU を要する。
///
/// 組み立ては絵を変えないので、2 度組んでも台帳にも画素にも出ない。**数でしか見えない**
/// ので、``ShaderLibraries/librariesBuilt`` を読む ([#728])。
///
/// [#728]: https://github.com/mokume-metal/mokume/issues/728
@Suite(
    "同じシェーダを 2 度組まない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderReuseTests {
    @Test("画面へ差し出す経路と書き出す経路は、Present を 1 度だけ組んで分け合う")
    func presentIsBuiltOnceForBothOutlets() throws {
        let gpu = try RenderDevice()
        _ = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        _ = try OutputPass(gpu: gpu)
        #expect(gpu.shaders.librariesBuilt == ["Present": 1])
    }

    @Test("別の GPU とは分け合わない — GPU ごとに 1 度ずつ組む")
    func presentIsNotSharedAcrossDevices() throws {
        // 組んだものは組んだ GPU のもので、ほかの GPU の上では使えない。分け合う範囲を
        // 型の外 (共有の控え) へ広げると、ここで片方が 0 になる
        let first = try RenderDevice()
        let second = try RenderDevice()
        _ = try FramePresenter(gpu: first, pixelFormat: RenderTarget.pixelFormat)
        _ = try OutputPass(gpu: second)
        #expect(first.shaders.librariesBuilt == ["Present": 1])
        #expect(second.shaders.librariesBuilt == ["Present": 1])
    }

    @Test("粒を 1 つ用意するとき、Particles の原文は 1 度だけ組む")
    func particlesAreBuiltOnceForAllThreeKernels() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let before = gpu.shaders.librariesBuilt

        _ = try canvas.makeParticles(count: 4)

        // 旗・数え上げ・進めるの 3 つの入口は同じ原文にある。入口ごとに組むと 3 度になる
        #expect(Self.added(since: before, now: gpu.shaders.librariesBuilt) == ["Particles": 1])
    }

    @Test("組めなかった原文も、組みに行った 1 回として数える")
    func failedCompilationsAreCounted() throws {
        // **数えるのは所要を払った回数である。** 組めなかった回も同じだけ時間を払うので、
        // 成功だけを数えると、書きかけで通らない断片を何度組み直しても 0 のままになる
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        #expect(throws: ShaderFailure.self) {
            try canvas.makeComputation("kernel void broken( {", name: "broken")
        }
        #expect(gpu.shaders.librariesBuilt["broken"] == 1)
    }

    /// `before` から増えたぶんだけを、名前ごとに返す。
    private static func added(since before: [String: Int], now: [String: Int]) -> [String: Int] {
        now.reduce(into: [:]) { result, entry in
            let grown = entry.value - (before[entry.key] ?? 0)
            if grown != 0 { result[entry.key] = grown }
        }
    }
}
