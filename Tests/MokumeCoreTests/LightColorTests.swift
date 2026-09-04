// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 光と質感を素の数値で指定する口 ([ADR-0033] 決定 1・7)。GPU を要する。
///
/// 見るのは 1 つ — **素の数値で書いた光と、同じ色を 0–1 で書いた光が、同じ絵になること**。
/// 目盛りの取り違えは例外を出さず、少し暗い絵になるだけで通ってしまうので、絵で確かめる。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
@Suite(
    "光と質感を素の数値で指定する",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LightColorTests {
    /// 2 つの絵が同じかどうかだけを先に畳む。
    ///
    /// `#expect` に絵そのものを渡すと、落ちたときに 16,384 バイトの列が丸ごと
    /// 展開されて読めなくなる。判定は真偽値にしてから渡す。
    private func isSame(_ one: DisplayImage, _ other: DisplayImage) -> Bool {
        one.bytes == other.bytes
    }

    /// 中央に球を 1 つ置く絵。光と質感の決め方だけを差し替えられる形にしてある。
    private func sphere(_ scene: @escaping (Canvas) -> Void) throws -> DisplayImage {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 64, height: 64)
        let canvas = try Canvas(target: target, gpu: gpu)
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            scene(canvas)
            canvas.fill(.opaque(red: 1, green: 1, blue: 1))
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.sphere(22)
            canvas.pop()
        }
        return try canvas.target.encodeForDisplay()
    }

    @Test("底上げの光は、素の数値でも 0–1 でも同じ絵になる")
    func ambientLightMatchesDisplayScale() throws {
        let numeric = try sphere { $0.ambientLight(90, 95, 110) }
        let display = try sphere {
            $0.ambientLight(.display(red: 90 / 255, green: 95 / 255, blue: 110 / 255))
        }
        #expect(isSame(numeric, display))
    }

    @Test("灰色 1 つの形は、3 つ並べたのと同じ絵になる")
    func grayFormSpreadsTheValue() throws {
        let gray = try sphere { $0.ambientLight(90) }
        let spread = try sphere { $0.ambientLight(90, 90, 90) }
        #expect(isSame(gray, spread))
    }

    @Test("向きを持つ光は、素の数値でも 0–1 でも同じ絵になる")
    func directionalLightMatchesDisplayScale() throws {
        let numeric = try sphere { $0.directionalLight(255, 244, 214, -0.5, 1, -0.3) }
        let display = try sphere {
            $0.directionalLight(
                .display(red: 1, green: 244 / 255, blue: 214 / 255), -0.5, 1, -0.3)
        }
        #expect(isSame(numeric, display))
    }

    @Test("位置を持つ光は、素の数値でも 0–1 でも同じ絵になる")
    func pointLightMatchesDisplayScale() throws {
        let numeric = try sphere { $0.pointLight(255, 214, 170, 200, 80, 120) }
        let display = try sphere {
            $0.pointLight(
                .display(red: 1, green: 214 / 255, blue: 170 / 255), 200, 80, 120)
        }
        #expect(isSame(numeric, display))
    }

    @Test("広がりを持つ光は、素の数値でも 0–1 でも同じ絵になる")
    func spotLightMatchesDisplayScale() throws {
        let numeric = try sphere {
            $0.spotLight(255, 230, 190, 32, 8, 60, 0, 1, -0.5, angle: 0.6)
        }
        let display = try sphere {
            $0.spotLight(
                .display(red: 1, green: 230 / 255, blue: 190 / 255),
                32, 8, 60, 0, 1, -0.5, angle: 0.6)
        }
        #expect(isSame(numeric, display))
    }

    @Test("質感の色も、素の数値でも 0–1 でも同じ絵になる")
    func materialColorsMatchDisplayScale() throws {
        let numeric = try sphere {
            $0.lights()
            $0.ambient(200, 120, 90)
            $0.emissive(40)
        }
        let display = try sphere {
            $0.lights()
            $0.ambient(.display(red: 200 / 255, green: 120 / 255, blue: 90 / 255))
            $0.emissive(.display(red: 40 / 255, green: 40 / 255, blue: 40 / 255))
        }
        #expect(isSame(numeric, display))
    }

    @Test("数でない値を渡しても落ちず、絵は光を置かなかったときのままになる")
    func notANumberPlacesNoLight() throws {
        let broken = try sphere { $0.directionalLight(.nan, 244, 214, -0.5, 1, -0.3) }
        let none = try sphere { _ in }
        #expect(isSame(broken, none))
    }
}
