// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 断片が種別として読む番号が、Swift と Metal で一致しているか。
///
/// 番号がずれても例外は出ない。**別の種別として効くだけ**なので、ずれは絵にしか
/// 現れず、しかも絵に出ない番号がある — 力の attract / wander / swirl、効果の
/// invert / monochrome / adjust / 縮め段、光の spot、折れ目の bevel / round は
/// 台帳のどのシーンも通らない ([#802])。
///
/// 両側に手で書いた表を突き合わせる形では、両方が同時にずれたときに黙って通る。
/// ここは GPU 自身に自分の見ている表を書かせ、CPU が並びとして読み比べる。
///
/// [#802]: https://github.com/mokume-metal/mokume/issues/802
@Suite(
    "種別の番号",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct KindLayoutTests {
    /// 区画の境に置く印。`Shaders/Kinds.metal` の `kKindSection` と同じ数。
    ///
    /// **ここが割れても黙って通らない** — 印が合わなければ並び全体が食い違う。
    static let section: UInt32 = 9000

    /// Swift 側が持っている番号を、`mokume_kindLayout` が書く順に並べたもの。
    static var expected: [UInt32] {
        var numbers: [UInt32] = []

        numbers.append(section + 0)
        numbers += [Light.Kind.ambient, .directional, .point, .spot].map(\.rawValue)

        numbers.append(section + 1)
        numbers += BlendMode.allCases.map(\.rawIndex)

        numbers.append(section + 2)
        numbers += [FormInstance.Kind.rect, .ellipse, .arc, .line].map(\.rawValue)

        numbers.append(section + 3)
        numbers += [StrokeCap.round, .square, .project].map(FormInstance.code(of:))

        numbers.append(section + 4)
        numbers += [StrokeJoin.miter, .bevel, .round].map(FormInstance.code(of:))

        numbers.append(section + 5)
        numbers += [FormInstance.fillsFlag, FormInstance.strokesFlag]

        numbers.append(section + 6)
        numbers += BuiltinEffectKind.allCases.map(\.rawValue)

        numbers.append(section + 7)
        numbers += ForceKind.allCases.map(\.rawValue)

        numbers.append(section + 99)
        return numbers
    }

    @Test("種別の番号が、CPU と GPU で一致する")
    func agreesOnTheKindsWithTheGPU() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let canvas = try Canvas(target: target, gpu: gpu)
        // 断片の中身は要らない — `mokume_kindLayout` は前置き (`Kinds.metal`) にあり、
        // どの計算のライブラリにも入っている
        let probe = try canvas.makeComputation("", name: "mokume_kindLayout")
        let slots = try canvas.makeNumbers(count: Self.expected.count)

        var written: [Float] = []
        try canvas.draw {
            canvas.compute(probe, over: 1, writes: [slots])
            written = canvas.read(slots)
        }

        // 書き出しは `uint` なので、置き場から読んだ数はそのビットで読み直す
        #expect(written.map(\.bitPattern) == Self.expected)
    }

    /// 番号を足したら両側へ足す、が守られているか。
    ///
    /// 上の検査は**並びが同じ長さである限り**値を見るが、片方だけに 1 つ足すと
    /// 末尾の印の位置がずれるので、そこでも落ちる。この検査は「いくつあるか」を
    /// 人が読める形で残しておくためのもの。
    @Test("種別の総数が、区画の印を含めて 53 のまま")
    func keepsTheNumberOfKinds() {
        #expect(Self.expected.count == 53)
    }
}
