// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 「同じ状態の設定し直しでは列を閉じない」(#2789) の同値判定。
//
// **比べるのは Float のビット列である。** `==` は +0 と -0 を同じとみなし、NaN を自分自身とも
// 等しくしない。どちらも断片が区別できる値 (`1 / x`・`isnan`・`signbit`) なので、`==` で同じと
// みなして列を閉じなければ、後の設定が前の値で描かれる (+0 と -0) か、同じ NaN を渡し直しても
// 毎回閉じる (NaN) 。ビット列が同じなら、列が閉じた時点に読む値は 1 ビットも変わらない。
//
// 判定は**閉じるかどうかを決めるだけ**で、値の保存は省かない。「違う」と答え違えると列が 1 本
// 増えるだけで絵は変わらないが、「同じ」と答え違えると閉じ忘れて後の設定で描く。迷う型は
// 「違う」と答える。

extension Float {
    /// ビット列まで同じか。
    @inline(__always)
    func isBitwiseEqual(to other: Float) -> Bool { bitPattern == other.bitPattern }
}

extension SIMD3 where Scalar == Float {
    @inline(__always)
    func isBitwiseEqual(to other: SIMD3<Float>) -> Bool {
        x.isBitwiseEqual(to: other.x) && y.isBitwiseEqual(to: other.y) && z.isBitwiseEqual(to: other.z)
    }
}

extension Vector3 {
    @inline(__always)
    func isBitwiseEqual(to other: Vector3) -> Bool { simd.isBitwiseEqual(to: other.simd) }
}

extension LinearRGBA {
    @inline(__always)
    func isBitwiseEqual(to other: LinearRGBA) -> Bool {
        red.isBitwiseEqual(to: other.red) && green.isBitwiseEqual(to: other.green)
            && blue.isBitwiseEqual(to: other.blue) && alpha.isBitwiseEqual(to: other.alpha)
    }
}

extension ShaderValue {
    /// 同じ型の同じビット列か。型が違えば違う。
    func isBitwiseEqual(to other: ShaderValue) -> Bool {
        switch (self, other) {
        case let (.number(a), .number(b)):
            return a.isBitwiseEqual(to: b)
        case let (.pair(ax, ay), .pair(bx, by)):
            return ax.isBitwiseEqual(to: bx) && ay.isBitwiseEqual(to: by)
        case let (.color(a), .color(b)):
            return a.isBitwiseEqual(to: b)
        default:
            return false
        }
    }
}

extension Camera.Projection {
    func isBitwiseEqual(to other: Camera.Projection) -> Bool {
        switch (self, other) {
        case let (.perspective(fa, aa, na, ra), .perspective(fb, ab, nb, rb)):
            return fa.isBitwiseEqual(to: fb) && aa.isBitwiseEqual(to: ab)
                && na.isBitwiseEqual(to: nb) && ra.isBitwiseEqual(to: rb)
        case let (.orthographic(la, ra, ba, ta, na, fa), .orthographic(lb, rb, bb, tb, nb, fb)):
            return la.isBitwiseEqual(to: lb) && ra.isBitwiseEqual(to: rb)
                && ba.isBitwiseEqual(to: bb) && ta.isBitwiseEqual(to: tb)
                && na.isBitwiseEqual(to: nb) && fa.isBitwiseEqual(to: fb)
        default:
            return false
        }
    }
}

extension Camera {
    func isBitwiseEqual(to other: Camera) -> Bool {
        eye.isBitwiseEqual(to: other.eye) && center.isBitwiseEqual(to: other.center)
            && up.isBitwiseEqual(to: other.up) && projection.isBitwiseEqual(to: other.projection)
    }
}

extension Material {
    func isBitwiseEqual(to other: Material) -> Bool {
        shininess.isBitwiseEqual(to: other.shininess) && metalness.isBitwiseEqual(to: other.metalness)
            && ambient.isBitwiseEqual(to: other.ambient) && emissive.isBitwiseEqual(to: other.emissive)
            && receivesShadow == other.receivesShadow
    }
}

extension Surroundings {
    func isBitwiseEqual(to other: Surroundings) -> Bool {
        top.isBitwiseEqual(to: other.top) && horizon.isBitwiseEqual(to: other.horizon)
            && bottom.isBitwiseEqual(to: other.bottom)
    }
}

extension Canvas.ClipRect {
    func isBitwiseEqual(to other: Canvas.ClipRect) -> Bool {
        left.isBitwiseEqual(to: other.left) && top.isBitwiseEqual(to: other.top)
            && right.isBitwiseEqual(to: other.right) && bottom.isBitwiseEqual(to: other.bottom)
    }
}
