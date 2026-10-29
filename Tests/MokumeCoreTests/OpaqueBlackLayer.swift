// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 1 枚目の前の窓の層が、不透明な黒で塗られているかの判定 ([#2876](https://github.com/mokume-metal/mokume/issues/2876))。
///
/// 層を塗るのは `SketchSurface.makeBackingLayer` の 1 か所で、窓を作る側 (直に走らせる窓・道具の窓) は
/// 何もしない。**判定は窓を作る側ごとの検査が共有する** — 作る所の検査だけでは、窓を作る側が別の面へ
/// 差し替えても (配線が外れても) 気付けない。
enum OpaqueBlackLayer {
    /// 層が不透明な黒で塗られていなければ、その理由。塗られていれば `nil`。
    static func problem(with layer: CALayer?) -> String? {
        guard let layer else { return "層が無い" }
        guard let color = layer.backgroundColor else { return "層に背景色が無い" }
        guard color.alpha == 1 else { return "背景色が不透明でない (alpha \(color.alpha))" }
        guard let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else {
            return "背景色を RGB に読めない (\(color))"
        }
        guard rgb.redComponent == 0, rgb.greenComponent == 0, rgb.blueComponent == 0 else {
            return "背景色が黒でない (\(rgb.redComponent), \(rgb.greenComponent), \(rgb.blueComponent))"
        }
        return nil
    }
}
