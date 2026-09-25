// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

@testable import MokumeCore

/// 2 枚の絵が、形の画素のうちどれだけ食い違うかの物差し
/// ([#1446](https://github.com/mokume-metal/mokume/issues/1446))。
///
/// **分母は形の画素である。** 面全体で割ると、背景が広いほど何でも一致して見える —
/// 箱が黒い影のように出ても、面の 3 割しか動かない。形の画素は「どちらかの絵で、
/// その絵の背景 (左上の隅の色) と違う画素」とする。食い違いの基準は ``LightTests`` の
/// 比べ方と同じく**赤の差が 8 を越える画素**である。
///
/// 等価な変換で描いた 2 枚は、縁の画素が土台の丸め方で 1 画素ずれうる。形の画素の
/// 数 % に収まるので、検査は割合に上限を置いて比べる。
enum PictureDifference {
    /// 比べる相手をどう裏返してから重ねるか。
    enum Flip {
        case none
        case vertical
        case horizontal
    }

    /// 食い違う画素の割合と、分母にした形の画素の数。
    struct Result: CustomStringConvertible {
        var differing: Int
        var shapePixels: Int
        var fraction: Double { shapePixels == 0 ? 0 : Double(differing) / Double(shapePixels) }
        var description: String { "\(differing) / \(shapePixels) (\(fraction))" }
    }

    /// `image` と、`reference` を `flip` で裏返した絵を比べる。
    static func between(
        _ image: DisplayImage, _ reference: DisplayImage, flip: Flip = .none
    ) -> Result {
        precondition(image.width == reference.width && image.height == reference.height)
        let background = image[0, 0]
        let referenceBackground = reference[0, 0]
        var differing = 0
        var shapePixels = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let other =
                    switch flip {
                    case .none: reference[x, y]
                    case .vertical: reference[x, reference.height - 1 - y]
                    case .horizontal: reference[reference.width - 1 - x, y]
                    }
                let here = image[x, y]
                guard differs(here, background) || differs(other, referenceBackground) else {
                    continue
                }
                shapePixels += 1
                if abs(Int(here.red) - Int(other.red)) > 8 { differing += 1 }
            }
        }
        return Result(differing: differing, shapePixels: shapePixels)
    }

    private static func differs(
        _ a: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8),
        _ b: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
    ) -> Bool {
        abs(Int(a.red) - Int(b.red)) > 8 || abs(Int(a.green) - Int(b.green)) > 8
            || abs(Int(a.blue) - Int(b.blue)) > 8
    }
}
