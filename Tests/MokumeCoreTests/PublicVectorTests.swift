// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import simd

@testable import MokumeCore
@testable import mokume

/// 公開面のベクトルを `Vector2` / `Vector3` に揃える (#2617・ADR 外の決定は #2580 の A6)。
///
/// 値の入れ物としての `Vector3` (作る・往復する・符号化する) と、移した公開面 (視点・置き場所・
/// 変換・モデルの大きさ・`@Param`) が、SIMD のときと同じ値を返すことを見る。
@Suite("公開面のベクトル")
struct PublicVectorTests {
    // MARK: - Vector3 そのもの (完了条件 3・5)

    /// **隔離の外から作れ、比べ、符号化できる** (完了条件 5)。`nonisolated` な関数の中で完結させる —
    /// `Vector3` が隔離を持つと、ここがコンパイルできない。
    nonisolated private static func roundTrip(_ vector: Vector3) throws -> (Vector3, String) {
        let data = try JSONEncoder().encode(vector)
        let text = String(decoding: data, as: UTF8.self)
        return (try JSONDecoder().decode(Vector3.self, from: data), text)
    }

    @Test("Vector3 は nonisolated で、Sendable・Hashable・Codable を持つ")
    nonisolated func vector3IsAPlainValue() throws {
        let vector = Vector3(1, 2, 3)
        let (back, text) = try Self.roundTrip(vector)
        #expect(back == vector)
        // 符号化の形は成分の名前つき (Vector2 の `{"x": …, "y": …}` と同じ作り)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Double])
        #expect(object == ["x": 1, "y": 2, "z": 3])
        #expect(Set([vector, Vector3(1, 2, 3), Vector3(3, 2, 1)]).count == 2)
        let sendable: any Sendable = vector
        #expect(sendable is Vector3)
    }

    @Test("Vector3(simd) と .simd の往復で、値は 1 ビットも変わらない")
    func simdRoundTripKeepsEveryBit() {
        let values: [SIMD3<Float>] = [
            SIMD3(1, 2, 3), SIMD3(-0.0, 0.1, .leastNonzeroMagnitude),
            SIMD3(.greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e-7),
        ]
        for value in values {
            let there = Vector3(value)
            #expect(there.simd.x.bitPattern == value.x.bitPattern)
            #expect(there.simd.y.bitPattern == value.y.bitPattern)
            #expect(there.simd.z.bitPattern == value.z.bitPattern)
            #expect(there.x == value.x && there.y == value.y && there.z == value.z)
        }
        let pair = SIMD2<Float>(-0.0, 7.5)
        #expect(Vector2(pair).simd.x.bitPattern == pair.x.bitPattern)
        #expect(Vector2(pair).simd.y.bitPattern == pair.y.bitPattern)
    }

    @Test("Vector3 は Int の変数も受け、配列リテラルから作れ、四則演算ができる")
    func initialisersAndArithmetic() {
        let column = 3
        #expect(Vector3(column * 10, 2.5, Float(1)) == Vector3(30, 2.5, 1))
        let literal: Vector3 = [200, 150, 500]
        #expect(literal == Vector3(200, 150, 500))
        var moved = literal + Vector3(1, 2, 3)
        #expect(moved == Vector3(201, 152, 503))
        moved -= Vector3(1, 2, 3)
        moved *= 2
        #expect(moved == Vector3(400, 300, 1000))
        moved /= 4
        #expect(moved == Vector3(100, 75, 250))
        #expect(-moved == Vector3(-100, -75, -250))
        #expect(moved * 2 == 2 * moved)
        #expect(moved / 5 == Vector3(20, 15, 50))
        #expect((moved - literal).simd == SIMD3<Float>(-100, -75, -250))
    }

    // MARK: - 移した公開面 (完了条件 2)

    /// 視点は `Vector3` で作り、`Vector3` で読み書きできる。値は SIMD のときと同じ。
    @Test("Camera は Vector3 で作って読み書きでき、視点の枠は SIMD のときと同じ")
    func cameraTakesVectors() {
        var camera = Camera(
            eye: Vector3(0, 0, 500), center: Vector3(0, 0, 0), up: Vector3(0, 1, 0),
            projection: .perspective(fieldOfView: .pi / 3, aspect: 1, near: 10, far: 2000))
        #expect(camera.eye == Vector3(0, 0, 500))
        #expect(camera.forward == normalize(SIMD3<Float>(0, 0, -500)))
        camera.eye += Vector3(100, 0, 0)
        camera.center.x = 100
        #expect(camera.eye.simd == SIMD3<Float>(100, 0, 500))
        #expect(camera.center == Vector3(100, 0, 0))
        #expect(camera.forward == normalize(SIMD3<Float>(0, 0, -500)))
        #expect(camera.isUsable)
        camera.up = Vector3(0, 0, 0)
        #expect(!camera.isUsable)
    }

    @Test("Placement.rotation・Orbit・Transform.apply・Model.size は Vector で読める")
    func otherPublicValuesAreVectors() throws {
        let placement = Placement(x: 1, rotation: Vector3(0.1, 0.2, 0.3))
        #expect(placement.rotation == Vector3(0.1, 0.2, 0.3))
        #expect(Placement().rotation == Vector3(0, 0, 0))

        let orbit = Orbit(center: Vector3(1, 2, 3), distance: 10)
        #expect(orbit.center == Vector3(1, 2, 3))
        #expect(orbit.up == Vector3(0, 1, 0))
        #expect((orbit.eye - orbit.center).simd == SIMD3<Float>(0, 0, 10))

        var step = Transform.identity
        step.translate(x: 3, y: 4, z: 5)
        #expect(step.apply(x: 1, y: 1) == Vector2(4, 5))
        #expect(step.apply(x: 1, y: 1, z: 1) == Vector3(4, 5, 6))
        // 内部の SIMD の計算と同じビット (`placed`) — 公開の型で包んでも値は動かない
        #expect(step.apply(x: 0.1, y: 0.7).simd == step.placed(x: 0.1, y: 0.7))
        #expect(step.apply(x: 0.1, y: 0.7, z: -0.3).simd == step.placed(x: 0.1, y: 0.7, z: -0.3))

        let outline = TextContour(points: [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)], isHole: false)
        #expect(outline.points == [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)])
    }

    @Test("ParamValue の組と、組の @Param は Vector2 / Vector3 で往復する")
    func paramValuesAreVectors() {
        #expect(Vector2(1, 2).paramValue == .vector2(Vector2(1, 2)))
        #expect(Vector3(1, 2, 3).paramValue == .vector3(Vector3(1, 2, 3)))
        #expect(Vector2(paramValue: .vector2(Vector2(3, 4))) == Vector2(3, 4))
        #expect(Vector3(paramValue: .vector3(Vector3(3, 4, 5))) == Vector3(3, 4, 5))
        // 型が違えば nil
        #expect(Vector2(paramValue: .vector3(Vector3(3, 4, 5))) == nil)
        #expect(Vector3(paramValue: .vector2(Vector2(3, 4))) == nil)
    }

    // MARK: - 保存値 (完了条件 4)

    @MainActor
    final class Shaped: Sketch {
        @Param(-10...10) var pair: Vector2 = Vector2(0, 0)
        @Param(-10...10) var triple: Vector3 = Vector3(0, 0, 0)
    }

    private func makeFile() throws -> URL {
        let directory = try TestScratch.directory("mokume-vector")
        return directory.appendingPathComponent("params.json")
    }

    /// 移す前に保存した `params.json` (SIMD のときと同じ形・成分の並び) を読め、保存し直しても
    /// 成分の並びが変わらない。**保存の形は `ParamValue` の線の形 (`vec2`・`vec3` と成分の並び) で、
    /// 公開の型には依らない**。
    @Test("移す前の形で保存した組を読め、書き直しても同じ形のまま")
    @MainActor
    func savedVectorsFromBeforeTheMoveStillRead() async throws {
        let url = try makeFile()
        let before = """
            {"schemaVersion":1,"values":[\
            {"name":"pair","type":"vec2","value":[1.5,-2.5]},\
            {"name":"triple","type":"vec3","value":[1,2.25,-3]}]}
            """
        try before.write(to: url, atomically: true, encoding: .utf8)

        let sketch = Shaped()
        let store = ParamStore(registry: ParamRegistry(of: sketch), at: url)
        let restoration = store.restore()
        #expect(restoration.discarded.isEmpty)
        #expect(sketch.pair == Vector2(1.5, -2.5))
        #expect(sketch.triple == Vector3(1, 2.25, -3))

        // 書き直す。片方だけ動かしても、もう片方の成分の並びは変わらない
        sketch.pair = Vector2(4, 5)
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { store.tick() }

        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let values = try #require(object["values"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: values.map { ($0["name"] as? String ?? "", $0) })
        #expect(byName["pair"]?["type"] as? String == "vec2")
        #expect(byName["pair"]?["value"] as? [Double] == [4, 5])
        #expect(byName["triple"]?["type"] as? String == "vec3")
        #expect(byName["triple"]?["value"] as? [Double] == [1, 2.25, -3])

        // 次の起動で、書き直した値がそのまま戻る
        let next = Shaped()
        _ = ParamStore(registry: ParamRegistry(of: next), at: url).restore()
        #expect(next.pair == Vector2(4, 5))
        #expect(next.triple == Vector3(1, 2.25, -3))
    }
}
