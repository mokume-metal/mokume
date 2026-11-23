// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import mokume

/// 公開の値の型 (`Sendable`) は、外のモジュールが **main の外で** 作り・読み・比べられる (#4098)。
///
/// このファイルは外のパッケージと同じく `import mokume` だけで書く (`@testable` にしない)。型が既定の
/// main actor の隔離のままだと、メンバと `==` が main actor に隔離され、この suite (main actor に載らない)
/// が組めなくなる。確かめの半分は組めることで、ここは読んだ値が作った値のとおりであることを見る。
@Suite("公開の値の型を main の外で使う")
nonisolated struct OffMainValueTests {
    @Test("視点・置き方・背景・変換・時計・設定を main の外で作り、読み、比べられる")
    func valuesAreUsableOffMain() {
        let camera = Camera(
            eye: Vector3(0, 0, 5), center: Vector3(0, 0, 0), up: Vector3(0, 1, 0),
            projection: .perspective(fieldOfView: 1, aspect: 1, near: 0.1, far: 100))
        #expect(camera == camera && camera.eye.z == 5)

        let placement = Placement(x: 1, y: 2, z: 3)
        #expect(placement == Placement(x: 1, y: 2, z: 3) && placement != Placement())

        let surroundings = Surroundings(top: .transparent, horizon: .transparent, bottom: .transparent)
        #expect(surroundings == surroundings && surroundings != .sky)

        #expect(Transform.identity == .identity)
        #expect(ShaderValue.number(1) != .bool(true))
        #expect(Upscale.spatial != .temporal && !Upscale.spatial.usesFrameHistory)
        #expect(Clock.frameIndex(frameRate: 30) != .wallClock)
        #expect(Emitter.point(0, 0) == .point(0, 0))
        #expect(Force.drag(1) != .wander(strength: 1))
        #expect(Heading.sphere == .sphere)
        #expect(InputEvent.focusChanged(focused: true) != .focusChanged(focused: false))

        let settings = SketchSettings(width: 16, height: 9)
        #expect(settings == SketchSettings(width: 16, height: 9) && settings.frameRate > 0)

        let orbit = Orbit.fitting(width: 16, height: 9)
        #expect(orbit == orbit && orbit.distance > 0)
    }

    /// 型の本体でなく**別の `extension` で足したメンバ** (リテラルからの初期化・シェーダへ渡す形) も、
    /// main の外で使える。型に付けた `nonisolated` は別の `extension` には効かないので、ここが組めることで
    /// 拡張の側の隔離を見る。
    @Test("拡張で足したメンバ (リテラル・シェーダへ渡す形) も main の外で使える")
    func extensionMembersAreUsableOffMain() {
        let literal: ShaderValue = 1.5
        let integer: ShaderValue = 2
        #expect(literal == .number(1.5) && integer == .number(2))
        #expect(Transform.identity.shaderValue == .transform(.identity))
        #expect(ShaderValue.bool(true).shaderValue == .bool(true))
        #expect(Camera.Projection.perspective(fieldOfView: 1, aspect: 1, near: 0.1, far: 10) != .orthographic(
            left: -1, right: 1, bottom: -1, top: 1, near: 0.1, far: 10))
    }

    /// 失敗の型 (`Error`) は既定の隔離に載らない。`catch` した先で比べ・`case` を読み・説明を読むのが
    /// main の外で組めることを、代表の 3 つで見る。
    @Test("失敗の型も main の外で作り、比べ、case と説明を読める")
    func failuresAreUsableOffMain() {
        let asset = AssetFailure.notFound(path: "a.png", searched: ["/x"])
        #expect(asset == .notFound(path: "a.png", searched: ["/x"]) && !asset.description.isEmpty)
        let image = ImageFailure.undecodable(path: "b.png")
        guard case .undecodable(let path) = image else {
            Issue.record("case を読めない: \(image)")
            return
        }
        #expect(path == "b.png" && image != .notRunning(call: "loadImage"))
        let data = DataFailure.notRunning(call: "loadJSONObject")
        #expect(data == .notRunning(call: "loadJSONObject") && !data.description.isEmpty)
    }

    /// 読み込みから作る値 (書体・3D モデル) は、ここでは作らずに型だけを見る。**呼ばない — 組めることを
    /// 見る。** メンバと `==` が main の外で使えなければ、この関数が組めない。
    nonisolated static func readLoadedValuesOffMain(font: Font, model: Model) -> Bool {
        font == font && !font.description.isEmpty && model == model && model.name == model.name
    }
}
