// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 断片へ渡す値を Swift の値のまま受ける口 (``ShaderValueConvertible``) と、足した型 (`float3`・`bool`・`int`・
/// `float4x4`) の宣言・詰め方の検査 (#3568)。GPU は使わない。値が断片に届くかは ``ShaderValueReachTests``。
struct ShaderValueConvertibleTests {
    private static func bytes(_ values: [Float]) -> [UInt8] {
        values.withUnsafeBytes { Array($0) }
    }

    private static func int32(_ values: [Float], atByte offset: Int) -> Int32 {
        values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
    }

    private static func float(_ values: [Float], atByte offset: Int) -> Float {
        values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    // MARK: - 型の割り当て

    @Test("Swift の値の型から断片の型が決まり、組んだ原稿の Values がその型で宣言する")
    func theSwiftTypeDecidesTheDeclaredType() {
        let time: Float = 1.5
        let bands = 4
        let ratio = 0.5
        let values: [String: ShaderValue] = [
            "time": time.shaderValue, "bands": bands.shaderValue, "ratio": ratio.shaderValue,
            "level": .int(3), "flag": true.shaderValue,
            "offset": Vector2(1, 2).shaderValue, "dir": Vector3(1, 2, 3).shaderValue,
            "tint": LinearRGBA.transparent.shaderValue, "m": Transform.identity.shaderValue,
        ]
        // 大きいものが先 (64 → 16 → 8 → 4 → 1 バイト)、同じ大きさなら名前の降順
        #expect(
            ShaderSource.declaration(of: values) == """
                struct Values {
                    metal::float4x4 m;
                    float4 tint;
                    float3 dir;
                    float2 offset;
                    float time;
                    float ratio;
                    int level;
                    float bands;
                    bool flag;
                };

                """)
    }

    @Test("Int の変数もリテラルも float のまま: set(\"speed\", 6) の宣言は変わらない")
    func integersStayFloats() {
        let n = 4
        #expect(n.shaderValue == .number(4))
        #expect((6 as Int).shaderValue == .number(6))
        let literal: ShaderValue = 6
        #expect(literal == .number(6))
        #expect(ShaderSource.declaration(of: ["speed": literal, "bands": n.shaderValue]).contains("float speed;"))
        #expect(!ShaderSource.declaration(of: ["speed": literal]).contains("int"))
    }

    @Test("Vector2 は既存の .pair へ、色は .color へ、ShaderValue はそのまま")
    func existingCasesAreReused() {
        #expect(Vector2(1, 2).shaderValue == .pair(1, 2))
        let tint = LinearRGBA(premultipliedRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        #expect(tint.shaderValue == .color(tint))
        #expect(ShaderValue.int(2).shaderValue == .int(2))
        #expect(Double(0.25).shaderValue == .number(0.25))
    }

    // MARK: - 詰め方は Metal の構造体の配置

    /// 4 つの型を混ぜた組。`float4x4` が 0、16 バイト境界のもの (`tint`・`dir`) が 64・80、`float2` が 96、
    /// 4 バイトのもの (`count`・`amount`) が 104・108、`bool` が 112・113 に載る。
    private static let mixed: [String: ShaderValue] = [
        "m": .transform(Self.placement),
        "tint": .color(LinearRGBA(premultipliedRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)),
        "dir": .vector3(Vector3(0.25, 0.5, 0.75)),
        "offset": .pair(7, 8),
        "count": .int(-3),
        "amount": .number(0.125),
        "other": .bool(false),
        "flag": .bool(true),
    ]

    private static var placement: Transform {
        var placement = Transform.identity
        placement.translate(x: 2, y: 3, z: 4)
        placement.rotate(by: 0.5)
        placement.scale(x: 2, y: 4)
        return placement
    }

    @Test("位置は Metal の構造体と同じ: float3 は 16 バイト、float4x4 は 64 バイト、bool は 1 バイト")
    func offsetsFollowTheMetalLayout() {
        #expect(
            ShaderSource.packedOffsets(of: Self.mixed)
                == [
                    "m": 0, "tint": 64, "dir": 80, "offset": 96, "count": 104, "amount": 108, "other": 112,
                    "flag": 113,
                ])
        // 境界に載る: float3・float4・float4x4 は 16、float2 は 8、float・int は 4
        for (name, offset) in ShaderSource.packedOffsets(of: Self.mixed) {
            let alignment = min(Self.mixed[name]!.byteSize, 16)
            #expect(offset % alignment == 0, "\(name) が境界に載っていない")
        }
    }

    @Test("詰めた中身: 各値が自分の位置に、成分の並びのまま入り、詰め物は 0")
    func packedBytesHoldEachValueAtItsOffset() throws {
        let packed = ShaderSource.pack(Self.mixed)
        // 114 バイトが 16 バイト境界へ切り上がる (128 バイト = 32 個)
        #expect(packed.count == 32)
        let matrix = Self.placement.matrix
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        for (index, column) in columns.enumerated() {
            for (row, expected) in [column.x, column.y, column.z, column.w].enumerated() {
                let got = Self.float(packed, atByte: index * 16 + row * 4)
                #expect(got.bitPattern == expected.bitPattern, "列 \(index) の \(row) 行目")
            }
        }
        #expect(Self.float(packed, atByte: 64) == 0.1)
        #expect(Self.float(packed, atByte: 76) == 0.4)
        #expect(
            [0, 4, 8].map { Self.float(packed, atByte: 80 + $0) } == [0.25, 0.5, 0.75])
        #expect(Self.float(packed, atByte: 92) == 0, "float3 の 4 つめは詰め物")
        #expect(Self.float(packed, atByte: 96) == 7)
        #expect(Self.float(packed, atByte: 100) == 8)
        #expect(Self.int32(packed, atByte: 104) == -3)
        #expect(Self.float(packed, atByte: 108) == 0.125)
        let bytes = Self.bytes(packed)
        #expect(bytes[112] == 0 && bytes[113] == 1)
        #expect(bytes[114...].allSatisfy { $0 == 0 }, "bool の後ろは詰め物")
    }

    @Test("組んだ原稿の宣言は、詰めた並びと同じ")
    func declarationFollowsThePackingOrder() {
        let lines = ShaderSource.declaration(of: Self.mixed).split(separator: "\n").map(String.init)
        #expect(
            lines == [
                "struct Values {", "    metal::float4x4 m;", "    float4 tint;", "    float3 dir;", "    float2 offset;",
                "    int count;", "    float amount;", "    bool other;", "    bool flag;", "};",
            ])
    }

    @Test("int は 32 ビットに収める: 範囲の外は端に丸める")
    func integersAreClampedToThirtyTwoBits() {
        let big = ShaderSource.pack(["n": .int(Int.max)])
        #expect(Self.int32(big, atByte: 0) == Int32.max)
        let small = ShaderSource.pack(["n": .int(Int.min)])
        #expect(Self.int32(small, atByte: 0) == Int32.min)
    }

    @Test("値が空でも、1 つの空の組を持つ")
    func emptyStaysOneGroup() {
        #expect(ShaderSource.pack([:]) == [0, 0, 0, 0])
    }

    @Test("bool だけでも 16 バイトへ切り上がる")
    func aBoolAloneRoundsUp() {
        #expect(Self.bytes(ShaderSource.pack(["flag": .bool(true)])) == [1] + [UInt8](repeating: 0, count: 15))
    }

    // MARK: - 書き換え

    private func makeBox(_ values: [String: ShaderValue]) -> ShaderBox {
        ShaderBox(
            name: "reach", url: nil, body: "", values: values, label: "shader",
            valuesHint: "makeShader's values")
    }

    @Test("値を変えた後の写しは、変えた値で詰め直したものと bit まで同じ (足した型も)")
    func assignmentsFollowThePacking() {
        let box = makeBox(Self.mixed)
        var expected = Self.mixed
        var turned = Transform.identity
        turned.rotateY(by: 1.25)
        let changes: [(String, ShaderValue)] = [
            ("flag", .bool(false)), ("other", .bool(true)), ("count", .int(99)),
            ("dir", .vector3(Vector3(Float(-0.0), Float.nan, 3))), ("m", .transform(turned)),
            ("offset", .pair(-1, 1)), ("flag", .bool(true)),
        ]
        for (name, value) in changes {
            #expect(box.assign(name, value))
            expected[name] = value
            #expect(
                box.packedValues.map(\.bitPattern) == ShaderSource.pack(expected).map(\.bitPattern),
                "\(name) を変えた後の写しが詰め直しと違う")
        }
    }

    @Test("宣言と違う型は断る: int の宣言に float は入らず、float の宣言に int は入らない")
    func aDifferentTypeIsRefused() {
        let box = makeBox(["level": .int(1), "amount": .number(1), "dir": .vector3(Vector3(1, 2, 3))])
        let before = box.packedValues
        #expect(!box.assign("level", .number(2)))
        #expect(!box.assign("amount", .int(2)))
        #expect(!box.assign("dir", .color(.transparent)))
        #expect(!box.assign("dir", .pair(1, 2)))
        #expect(box.packedValues.map(\.bitPattern) == before.map(\.bitPattern))
        // 同じ型なら受ける
        #expect(box.assign("level", .int(2)))
    }

    @Test("同じ値の書き直しは、足した型でも通知しない")
    func sameValueDoesNotNotify() {
        let box = makeBox(Self.mixed)
        var notified = 0
        #expect(box.assign("flag", .bool(true), willChange: { notified += 1 }))
        #expect(box.assign("count", .int(-3), willChange: { notified += 1 }))
        #expect(box.assign("dir", .vector3(Vector3(0.25, 0.5, 0.75)), willChange: { notified += 1 }))
        #expect(box.assign("m", .transform(Self.placement), willChange: { notified += 1 }))
        #expect(notified == 0)
        #expect(box.assign("flag", .bool(false), willChange: { notified += 1 }))
        #expect(notified == 1)
    }

    @Test("ビット列の同値: -0 と +0、型の違いは別の値")
    func bitwiseEqualityCoversTheNewCases() {
        #expect(ShaderValue.vector3(Vector3(0, 1, 2)).isBitwiseEqual(to: .vector3(Vector3(0, 1, 2))))
        #expect(!ShaderValue.vector3(Vector3(0, 1, 2)).isBitwiseEqual(to: .vector3(Vector3(-0.0, 1, 2))))
        #expect(!ShaderValue.int(1).isBitwiseEqual(to: .number(1)))
        #expect(!ShaderValue.bool(true).isBitwiseEqual(to: .bool(false)))
        #expect(ShaderValue.transform(.identity).isBitwiseEqual(to: .transform(.identity)))
        #expect(!ShaderValue.transform(.identity).isBitwiseEqual(to: .transform(Self.placement)))
    }

    // MARK: - 上限の案内

    @Test("上限の案内は、足した型の数え方を名乗り、詰める先に float3 も挙げる")
    func theLimitNoticeCountsTheNewTypes() {
        let notice = ShaderFailure.tooManyValues(path: "probe", count: 300, capacity: 256).description
        #expect(notice.contains("vector3 (float3"), "\(notice)")
        #expect(notice.contains("transform (float4x4) as 16"), "\(notice)")
        #expect(notice.contains("color, vector3 or pair"), "\(notice)")
    }

    @Test("値の数は float4x4 の 16 で数える")
    func aTransformCountsAsSixteen() throws {
        #expect(ShaderSource.pack(["m": .transform(.identity)]).count == 16)
        #expect(ShaderSource.pack(["m": .transform(.identity), "a": 1]).count == 20)
        #expect(ShaderSource.pack(["d": .vector3(Vector3(1, 2, 3))]).count == 4)
    }

    // MARK: - 保持した形の塗りの比較

    private static func paint(_ value: ShaderValue) -> Shape.Paint {
        Shape.Paint(shader: nil, values: ShaderSource.pack(["n": value]), surfaces: [], numbers: nil)
    }

    @Test("保持した形の塗りは値をビット列で比べる: Int.min は 0 と別、-1 は自分と等しい")
    func paintsCompareValuesByBits() {
        // Int.min は 0x80000000 で、Float としては -0.0。`Float ==` では 0 と等しくなり、記録した塗りに移れない
        #expect(Self.paint(.int(Int.min)) != Self.paint(.int(0)))
        // -1 は 0xFFFFFFFF で NaN のビット列。`Float ==` では自分とも等しくならず、同じ塗りで毎回列を閉じる
        #expect(Self.paint(.int(-1)) == Self.paint(.int(-1)))
        #expect(Self.paint(.number(.nan)) == Self.paint(.number(.nan)))
        #expect(Self.paint(.number(-0.0)) != Self.paint(.number(0)))
        #expect(Self.paint(.bool(true)) != Self.paint(.bool(false)))
        #expect(Self.paint(.int(3)) == Self.paint(.int(3)))
    }
}
