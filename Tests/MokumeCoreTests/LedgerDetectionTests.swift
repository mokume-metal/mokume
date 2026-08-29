// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 代表シーンの台帳が、**時間方向に検出力を持っている**ことを見る。
///
/// ## 台帳だけでは足りない 2 つ
///
/// `SceneLedgerTests` は「記録した時点から変わっていないか」を見る。それだけでは
/// 2 つの穴が残る。
///
/// - **同じ入力から同じ動きが出ているか**は見ていない。台帳は時点ごとの 1 枚しか
///   持たず、2 回目を描くのは不一致のときだけである。時点と時点の間で列が揺れていても、
///   載せた 2 点がたまたま一致すれば通ってしまう
/// - **その行がその要素を写しているか**は見ていない。写していない要素は、壊れても
///   台帳に現れない ([ADR-0019] 決定 3 が名指しする既知の盲点)
///
/// ここが受け持つのはその 2 つで、**台帳の行は 1 つも増やさない**。列は検査が持ち、
/// 台帳は退行を見せるための 2 点だけを持つ ([ADR-0023] 決定 6)。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
@Suite(
    "台帳の検出力",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LedgerDetectionTests {

    // MARK: - 同じ入力から同じ列

    /// 時点を持つシーンを 2 回走らせ、**1 フレームずつ突き合わせる**。
    ///
    /// 台帳が見ているのは 2 点だけなので、その間で列が揺れていても気付けない。
    /// ここは 0 から最後の時点まで全部を見るので、**どのフレームで分かれたか**が返る。
    @Test(
        "動きが、同じ入力から 2 回とも同じ列を返す",
        arguments: Scene.allCases.filter { !$0.moments.isEmpty })
    func theSameInputReturnsTheSameSequence(_ scene: Scene) throws {
        let first = try Self.sequence(of: scene)
        let second = try Self.sequence(of: scene)

        guard let parted = Array(zip(first, second)).firstIndex(where: { $0 != $1 }) else {
            #expect(first.count == second.count)
            return
        }
        Issue.record(
            """
            シーン \(scene.rawValue) が、同じ入力から違う列を出している。
            \(parted) フレーム目で分かれた (それより前は一致している)。
            1 回目 \(first[parted]) / 2 回目 \(second[parted])

            **台帳を書き換えてはならない。** 台帳は「変わっていないこと」しか見られないので、
            同じ動きが出ない状態では何も守れない。先に決定論を直す — フレームをまたいで
            持つものが `session(on:without:)` の外にある / 乱数の種を引き直している /
            時計が実時間を読んでいる、のいずれかである。
            """)
    }

    // MARK: - 殺したら台帳が動く

    /// 段を 1 つ外して描き、**台帳の行が動くこと**を見る。
    ///
    /// 動かなければ、その行はその段を写していない。写していない段は壊れても台帳に
    /// 現れないので、そのときは行のほうを直す (シーンにその段が効く絵を足す)。
    @Test("段を外すと、台帳の行が動く", arguments: Scene.Ingredient.stages)
    func killingAStageMovesTheLedger(_ stage: Scene.Ingredient) throws {
        let ledger = try Ledger.load()
        #expect(!stage.takes.isEmpty, "\(stage) を写しているはずの行が 1 つも無い")

        for take in stage.takes {
            guard let recorded = ledger[take.name] else {
                Issue.record("行 \(take.name) が台帳に無い")
                continue
            }
            let killed = try SceneLedgerTests.fingerprint(of: take, without: stage)
            #expect(
                killed != recorded,
                """
                \(stage) を外しても、行 \(take.name) の絵が動かない。
                その行はこの段を写していないので、この段が壊れても台帳には現れない。
                シーンのほうに、その段が効く絵を足す ([ADR-0019] 決定 3)。
                """)
        }
    }

    // MARK: - 部品

    /// 0 から最後の時点まで、1 フレームずつ指紋を取る。
    ///
    /// 指紋の取り方は台帳と同じ (出力段を通した 8 bit の画素) なので、**列の最後は
    /// 台帳の行と同じ数**になる。
    private static func sequence(of scene: Scene) throws -> [String] {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: scene.size.width, height: scene.size.height)
        let canvas = try Canvas(
            output: target, gpu: gpu, pixelDensity: scene.pixelDensity, upscale: scene.upscale)
        let session = try scene.session(on: canvas)

        var digests: [String] = []
        for _ in 0..<(scene.moments.max() ?? 1) {
            try canvas.draw { session() }
            let image = try target.encodeForDisplay()
            digests.append(SHA256.hash(data: Data(image.bytes)).map { String(format: "%02x", $0) }.joined())
        }
        return digests
    }
}
