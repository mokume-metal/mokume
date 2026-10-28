// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `Vector3` の `length`・`normalized()`・`limited(to:)` と、`Vector2` / `Vector3` の幾何演算
/// (`distance(to:)`・`dot(_:)`・`cross(_:)`・`angle`・`rotated(by:)`・`interpolated(to:amount:)`・
/// `Vector2(angle:length:)`) ([#3359])。GPU は要らない。
///
/// 見るのは、**値が正しいこと**・**`Vector2` の同じ名前の口と約束が揃うこと** (0 ベクトルの正規化・
/// 溢れる大きさ・負の上限)・**関数の層の `dist`・`mag`・`lerp` と同じ答えになること**である。
///
/// [#3359]: https://github.com/mokume-metal/mokume/issues/3359
@Suite("Vector2 / Vector3 の幾何演算")
struct VectorGeometryTests {
    private func isNear(_ one: Float, _ other: Float, within tolerance: Float = 1e-5) -> Bool {
        abs(one - other) <= tolerance * max(1, abs(other))
    }

    private func isNear(_ one: Vector3, _ other: Vector3, within tolerance: Float = 1e-5) -> Bool {
        isNear(one.x, other.x, within: tolerance) && isNear(one.y, other.y, within: tolerance)
            && isNear(one.z, other.z, within: tolerance)
    }

    private func isNear(_ one: Vector2, _ other: Vector2, within tolerance: Float = 1e-5) -> Bool {
        isNear(one.x, other.x, within: tolerance) && isNear(one.y, other.y, within: tolerance)
    }

    // MARK: - Vector3 の長さ・正規化・上限

    @Test("Vector3.length は 3 成分の長さで、0 になるのは 0 ベクトルだけ")
    func vector3Length() {
        #expect(Vector3(0, 3, 4).length == 5)
        #expect(Vector3(2, 3, 6).length == 7)
        #expect(Vector3(-1, -2, -2).length == 3)
        #expect(Vector3(0, 0, 0).length == 0)
        // 2 乗が溢れる・潰れる大きさでも有限 (Vector2 と同じ規則・#2935)
        #expect(isNear(Vector3(3e19, 4e19, 12e19).length, 13e19))
        #expect(isNear(Vector3(2e-30, 3e-30, 6e-30).length, 7e-30))
        #expect(Vector3(1.4e-45, 0, 0).length > 0)
        // 関数の層の mag と同じ値
        #expect(Vector3(2, 3, 6).length == mag(2, 3, 6))
        #expect(Vector3(1e30, 1e30, 1e30).length == mag(1e30, 1e30, 1e30))
    }

    @Test("Vector3.normalized() は長さ 1 の向きを返し、0 ベクトルは変えずに返す")
    func vector3Normalized() {
        let unit = Vector3(0, 3, 4).normalized()
        #expect(isNear(unit, Vector3(0, 0.6, 0.8)))
        #expect(isNear(unit.length, 1))
        // 0 ベクトルは向きが無いので、0 で割らずそのまま (NaN を絵へ流さない)
        #expect(Vector3(0, 0, 0).normalized() == Vector3(0, 0, 0))
        // 小さいだけの値は 0 ベクトルではない。2 乗が潰れても長さ 1
        let tiny = Vector3(1e-30, 1e-30, 1e-30).normalized()
        #expect(isNear(tiny.length, 1))
        // 大きいだけの値も、2 乗が溢れても長さ 1
        let huge = Vector3(3e38, 0, 2e38).normalized()
        #expect(huge.x.isFinite && huge.z.isFinite)
        #expect(isNear(huge.length, 1))
        // 元の値は変わらない
        let original = Vector3(0, 3, 4)
        _ = original.normalized()
        #expect(original == Vector3(0, 3, 4))
    }

    @Test("Vector3.limited(to:) は長さを上限で止め、向きは保ち、0 以下の上限は 0 ベクトル")
    func vector3Limited() {
        let over = Vector3(0, 6, 8).limited(to: 5)
        #expect(isNear(over, Vector3(0, 3, 4)))
        // 上限以下は変えずに返す
        #expect(Vector3(0, 3, 4).limited(to: 5) == Vector3(0, 3, 4))
        #expect(Vector3(0, 3, 4).limited(to: 10) == Vector3(0, 3, 4))
        // 負・0・数でない上限は止める (向きを反転させない)
        #expect(Vector3(0, 6, 8).limited(to: -5) == Vector3(0, 0, 0))
        #expect(Vector3(0, 6, 8).limited(to: 0) == Vector3(0, 0, 0))
        #expect(Vector3(0, 6, 8).limited(to: Float.nan) == Vector3(0, 0, 0))
        // 溢れる大きさでも長さが上限になる
        let big = Vector3(3e38, 0, 3e38).limited(to: 2)
        #expect(isNear(big.length, 2))
        // Int の上限も受ける
        #expect(isNear(Vector3(2, 3, 6).limited(to: 7 as Int), Vector3(2, 3, 6)))
    }

    // MARK: - 距離・内積・外積

    @Test("distance(to:) は関数の dist と同じ値 (Vector2・Vector3)")
    func distance() {
        let a2 = Vector2(1, 2)
        let b2 = Vector2(4, 6)
        #expect(a2.distance(to: b2) == 5)
        #expect(b2.distance(to: a2) == 5)
        #expect(a2.distance(to: b2) == dist(1, 2, 4, 6))
        #expect(a2.distance(to: a2) == 0)
        let a3 = Vector3(1, 2, 3)
        let b3 = Vector3(3, 5, 9)
        #expect(a3.distance(to: b3) == 7)
        #expect(a3.distance(to: b3) == dist(1, 2, 3, 3, 5, 9))
        #expect(b3.distance(to: a3) == 7)
        // 溢れる大きさでも同じ値 (関数の層と規則が揃う)
        let far = Vector3(0, 0, 0).distance(to: Vector3(3e19, 4e19, 12e19))
        #expect(far == dist(0, 0, 0, 3e19, 4e19, 12e19))
        #expect(far.isFinite)
    }

    @Test("dot(_:) は内積: 同じ向きで正・直角で 0・反対向きで負")
    func dotProduct() {
        #expect(Vector2(1, 2).dot(Vector2(3, 4)) == 11)
        #expect(Vector2(1, 0).dot(Vector2(0, 5)) == 0)
        #expect(Vector2(2, 0).dot(Vector2(-3, 0)) == -6)
        #expect(Vector3(1, 2, 3).dot(Vector3(4, 5, 6)) == 32)
        #expect(Vector3(1, 0, 0).dot(Vector3(0, 0, 7)) == 0)
        #expect(Vector3(0, 0, 2).dot(Vector3(0, 0, -3)) == -6)
        // 自分との内積は長さの 2 乗
        #expect(Vector3(2, 3, 6).dot(Vector3(2, 3, 6)) == 49)
    }

    @Test("cross(_:) は右手系の直交ベクトル")
    func crossProduct() {
        let x = Vector3(1, 0, 0)
        let y = Vector3(0, 1, 0)
        let z = Vector3(0, 0, 1)
        #expect(x.cross(y) == z)
        #expect(y.cross(z) == x)
        #expect(z.cross(x) == y)
        // 順を入れ替えると向きが反対
        #expect(y.cross(x) == Vector3(0, 0, -1))
        // 一般の値: どちらにも直角で、長さは平行四辺形の面積
        let a = Vector3(1, 2, 3)
        let b = Vector3(4, 5, 6)
        let c = a.cross(b)
        #expect(c == Vector3(-3, 6, -3))
        #expect(a.dot(c) == 0)
        #expect(b.dot(c) == 0)
        // 平行なら 0 ベクトル
        #expect(a.cross(a * 2) == Vector3(0, 0, 0))
    }

    // MARK: - 角度・回転

    @Test("Vector2.angle はラジアンで、右が 0・下が +π/2 (縦軸が下向き)")
    func angleInRadians() {
        #expect(Vector2(1, 0).angle == 0)
        #expect(isNear(Vector2(0, 1).angle, Float.pi / 2))
        #expect(isNear(Vector2(-1, 0).angle, Float.pi))
        #expect(isNear(Vector2(0, -1).angle, -Float.pi / 2))
        #expect(isNear(Vector2(1, 1).angle, Float.pi / 4))
        // 長さによらない
        #expect(Vector2(30, 40).angle == Vector2(3, 4).angle)
        // 向きの無い 0 ベクトルは 0 (数でない値を返さない)
        #expect(Vector2(0, 0).angle == 0)
    }

    @Test("rotated(by:) は長さを保ったまま回し、正の角度は rotate() と同じ向き")
    func rotation() {
        #expect(isNear(Vector2(1, 0).rotated(by: Float.pi / 2), Vector2(0, 1)))
        #expect(isNear(Vector2(1, 0).rotated(by: Float.pi), Vector2(-1, 0)))
        #expect(isNear(Vector2(0, 1).rotated(by: -Float.pi / 2), Vector2(1, 0)))
        // 0 度は変えない・長さを保つ
        #expect(Vector2(3, 4).rotated(by: 0) == Vector2(3, 4))
        #expect(isNear(Vector2(3, 4).rotated(by: 1.1).length, 5))
        // 回した分だけ angle が進む
        let before = Vector2(3, 4)
        #expect(isNear(before.rotated(by: 0.5).angle, before.angle + 0.5))
        // Int の角度も受ける
        #expect(isNear(Vector2(1, 0).rotated(by: 0 as Int), Vector2(1, 0)))
        // 元の値は変わらない
        #expect(before == Vector2(3, 4))
    }

    @Test("Vector2(angle:length:) は angle の逆で、長さの既定は 1")
    func fromAngle() {
        #expect(isNear(Vector2(angle: 0), Vector2(1, 0)))
        #expect(isNear(Vector2(angle: Float.pi / 2), Vector2(0, 1)))
        #expect(isNear(Vector2(angle: Float.pi / 2, length: 3), Vector2(0, 3)))
        // 負の長さは反対向き
        #expect(isNear(Vector2(angle: 0, length: -2), Vector2(-2, 0)))
        // angle・length で読み戻せる
        for angle: Float in [-3, -1.2, 0, 0.4, 2.5] {
            let vector = Vector2(angle: angle, length: 7)
            #expect(isNear(vector.angle, angle), "angle \(angle)")
            #expect(isNear(vector.length, 7), "length at \(angle)")
        }
        // Int・Double も受ける
        #expect(isNear(Vector2(angle: 0 as Int, length: 4 as Int), Vector2(4, 0)))
        #expect(isNear(Vector2(angle: 0.0 as Double, length: 4.0 as Double), Vector2(4, 0)))
    }

    // MARK: - 補間

    @Test("interpolated は amount 0 で自分、1 で target がちょうど返り、締めない")
    func interpolation() {
        let a2 = Vector2(10, 20)
        let b2 = Vector2(30, -20)
        #expect(a2.interpolated(to: b2, amount: 0) == a2)
        #expect(a2.interpolated(to: b2, amount: 1) == b2)
        #expect(a2.interpolated(to: b2, amount: 0.25) == Vector2(15, 10))
        // 0…1 の外は伸ばす
        #expect(a2.interpolated(to: b2, amount: 2) == Vector2(50, -60))
        #expect(a2.interpolated(to: b2, amount: -1) == Vector2(-10, 60))
        let a3 = Vector3(0, 10, -4)
        let b3 = Vector3(8, 20, 4)
        #expect(a3.interpolated(to: b3, amount: 0) == a3)
        #expect(a3.interpolated(to: b3, amount: 1) == b3)
        #expect(a3.interpolated(to: b3, amount: 0.5) == Vector3(4, 15, 0))
        // 成分ごとに関数の lerp と同じ値
        let mid = a3.interpolated(to: b3, amount: 0.3)
        #expect(mid == Vector3(lerp(0, 8, 0.3), lerp(10, 20, 0.3), lerp(-4, 4, 0.3)))
        // Int の割合も受ける
        #expect(a2.interpolated(to: b2, amount: 1 as Int) == b2)
    }
}
