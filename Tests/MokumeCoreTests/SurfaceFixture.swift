// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

@testable import MokumeCore

/// 検査に使う、画面を持たない面。
///
/// **ウィンドウは機械で検められないが、差し出す面だけならウィンドウなしで作れる。** 差し出す経路
/// (置き場の巻き戻し・面の常駐) はどれもこの面で回せるので、作り方をここに 1 つ置く。
enum SurfaceFixture {
    static func make(_ device: any MTLDevice, size: Int) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = RenderTarget.pixelFormat
        layer.drawableSize = CGSize(width: size, height: size)
        return layer
    }
}
