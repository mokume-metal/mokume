// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

@testable import MokumeCore

/// 検査に使う面の組み立て。
///
/// **GPU は受け取る側で作る。** ここで `RenderDevice()` を呼ぶと、`GPUGateTests` が
/// 見張っている「GPU を作る場所には GPU の有無の条件が掛かっている」が破れる — 補助型に
/// `@Suite(.enabled(if:))` を付けて通すこともできるが、それは Suite でないものを
/// Suite に見せて機構を迂回することになる。`SurfaceFixture` と同じく引数で受ければ、
/// `let gpu = try RenderDevice()` は条件の掛かった呼び手の中に残る ([#816])。
///
/// 寸法の既定値は置かない。**検査ごとに意味のある大きさが違う**ので、既定は各 Suite の
/// `makeCanvas` が持つ。
///
/// [#816]: https://github.com/mokume-metal/mokume/issues/816
enum CanvasFixture {
    static func make(gpu: RenderDevice, width: Int, height: Int) throws -> Canvas {
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }
}
