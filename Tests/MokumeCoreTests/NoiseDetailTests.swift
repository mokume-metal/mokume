// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 揺らぎの細かさの受け口 ``Canvas/noiseDetail(_:_:)`` が、受け取れない値を弾く
/// ([#1385] 条件 10 の後半)。
///
/// 説明の約束は「範囲の外の値や数でない値を渡すと、設定は変わらず注意が出る」。
/// **弾いたことは絵に出ない** — 設定が変わらなければ模様も変わらないので、控え
/// (``Canvas/warnings``) と設定 (``Canvas/noiseSettings``) を直に読む。控えは面ごとに
/// 1 度しか鳴らないので、値ごとに面を作る。
///
/// 条件 10 の前半 (引数を省いた形) は #1388 が ``NoiseTests`` を直して見る。
///
/// [#1385]: https://github.com/mokume-metal/mokume/issues/1385
@Suite(
    "揺らぎの細かさの受け口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct NoiseDetailTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
    }

    /// 受け取れない組。枚数は 1…16 (``ValueNoise/octaveRange``)、弱まりは 0…1 の有限の値。
    nonisolated static var rejected: [(octaves: Int, falloff: Float)] {
        [
            (0, 0.5), (17, 0.5), (-3, 0.5),
            (4, -0.25), (4, 1.5), (4, .nan), (4, .infinity),
        ]
    }

    @Test("受け取れない細かさを渡すと、設定は変わらず注意が出る", arguments: rejected)
    func rejectedDetailLeavesTheSettingsAlone(_ detail: (octaves: Int, falloff: Float)) throws {
        let canvas = try makeCanvas()
        // **既定と違う値にしておく。** 既定のままだと、「変わらなかった」と「既定へ
        // 戻った」を見分けられない
        canvas.noiseDetail(6, 0.25)
        let before = canvas.noiseSettings
        let sample = canvas.noise(1.5, 2.5, 3.5)
        #expect(!canvas.warnings.hasWarned(.badNoise), "受け取れる値で注意が出た")

        canvas.noiseDetail(detail.octaves, detail.falloff)

        #expect(canvas.noiseSettings == before)
        #expect(canvas.noise(1.5, 2.5, 3.5) == sample)
        #expect(canvas.warnings.hasWarned(.badNoise))
        #expect(canvas.warnings.message(for: .badNoise)?.hasPrefix("noiseDetail()") == true)
    }

    /// 上の検査が「何でも弾く」口でも緑になってしまわないための対。範囲の両端を含める。
    nonisolated static var accepted: [(octaves: Int, falloff: Float)] {
        [(1, 0), (16, 1), (6, 0.25)]
    }

    @Test("範囲の内側の細かさは受け取り、注意を出さない", arguments: accepted)
    func acceptedDetailChangesTheSettings(_ detail: (octaves: Int, falloff: Float)) throws {
        let canvas = try makeCanvas()
        canvas.noiseDetail(detail.octaves, detail.falloff)
        #expect(canvas.noiseSettings.octaves == detail.octaves)
        #expect(canvas.noiseSettings.falloff == detail.falloff)
        #expect(!canvas.warnings.hasWarned(.badNoise))
    }
}
