// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 断片へ渡す値の詰めた写し (``ShaderBox/packedValues``) が、宣言の並びどおりで、値が変わったときだけ
/// 書き換わることの検査 (#2790)。
///
/// 写しは値を変えるたびに書き換える控えなので、**書き換え忘れ**と**積んだ仕事への巻き込み**が
/// 壊れ方である。前者は「変えた値が次の描画に届かない」、後者は「旧値を積んだ後に値を変えると、
/// 前の仕事が新しい値で描かれる」。
struct ShaderPackedSnapshotTests {
    /// 型も名前の順も混ぜた宣言。詰める並び (4 成分 → 2 成分 → 1 成分、同じなら名前の降順) と、
    /// 宣言の書き順が一致しないようにしてある。
    private static let mixed: [String: ShaderValue] = [
        "amount": .number(0.25),
        "zeta": .number(-3),
        "offset": .pair(0.5, -2),
        "tint": .color(LinearRGBA(premultipliedRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)),
        "glow": .color(LinearRGBA(premultipliedRed: 1, green: 0, blue: 0.5, alpha: 1)),
    ]

    private static func bits(_ values: [Float]) -> [UInt32] { values.map(\.bitPattern) }

    private func makeBox(_ values: [String: ShaderValue]) -> ShaderBox {
        ShaderBox(
            name: "snapshot", url: nil, body: "", values: values, label: "shader",
            valuesHint: "makeShader's values")
    }

    // MARK: - 詰め方は pack と同じ

    @Test("作った直後の写しは、ShaderSource.pack と bit まで同じ")
    func startsAsTheReferencePacking() {
        let box = makeBox(Self.mixed)
        #expect(Self.bits(box.packedValues) == Self.bits(ShaderSource.pack(Self.mixed)))
        // 4 成分が先 (glow・tint の降順)、2 成分、1 成分 (zeta・amount の降順)、16 バイトへ切り上げ
        #expect(box.packedValues.count == 12)
    }

    @Test("宣言が空なら、4 つの 0 を持つ")
    func emptyDeclarationHoldsOneEmptyGroup() {
        #expect(makeBox([:]).packedValues == [0, 0, 0, 0])
    }

    @Test("値を変えた後の写しは、変えた値で詰め直したものと bit まで同じ")
    func followsEveryAssignment() {
        let box = makeBox(Self.mixed)
        var expected = Self.mixed
        let changes: [(String, ShaderValue)] = [
            ("amount", .number(.nan)),
            ("offset", .pair(-0.0, 7)),
            ("tint", .color(LinearRGBA(premultipliedRed: 9, green: -1, blue: 0, alpha: 0.5))),
            ("zeta", .number(1e30)),
            ("glow", .color(LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0))),
            ("amount", .number(-0.0)),
        ]
        for (name, value) in changes {
            #expect(box.assign(name, value))
            expected[name] = value
            #expect(
                Self.bits(box.packedValues) == Self.bits(ShaderSource.pack(expected)),
                "\(name) を変えた後の写しが詰め直しと違う")
        }
    }

    // MARK: - 変わらないとき

    @Test("断る入力と同じ値の書き直しでは、写しも通知も動かない")
    func untouchedWhenNothingChanges() {
        let box = makeBox(Self.mixed)
        let before = box.packedValues
        var notified = 0
        // 同じ値 (ビット列まで)
        #expect(box.assign("amount", .number(0.25), willChange: { notified += 1 }))
        // 宣言していない名前・型の違う値は断る
        #expect(!box.assign("unknown", .number(1), willChange: { notified += 1 }))
        #expect(!box.assign("offset", .number(1), willChange: { notified += 1 }))
        #expect(notified == 0)
        #expect(Self.bits(box.packedValues) == Self.bits(before))
    }

    @Test("+0 と -0 は別の値として、写しにも届く")
    func signedZeroReachesTheSnapshot() {
        let box = makeBox(["level": .number(0)])
        #expect(box.assign("level", .number(-0.0)))
        #expect(Self.bits(box.packedValues).first == (-0.0 as Float).bitPattern)
    }

    // MARK: - 積んだ仕事を巻き込まない

    @Test("写しを抱えた後に値を変えても、抱えた写しは変わらない")
    func heldSnapshotsAreNotRewritten() {
        let box = makeBox(Self.mixed)
        let held = box.packedValues
        let heldBits = Self.bits(held)
        #expect(box.assign("glow", .color(LinearRGBA(premultipliedRed: 0, green: 1, blue: 0, alpha: 1))))
        #expect(box.assign("zeta", .number(42)))
        #expect(Self.bits(held) == heldBits, "抱えていた写しが、後の値で書き換わった")
        #expect(Self.bits(box.packedValues) != heldBits)
        // 抱えていないなら、写しは作り直さずその場で書き換わる (読み手が増やすのは参照だけ)
        let again = box.packedValues
        #expect(box.assign("zeta", .number(43)))
        #expect(Self.bits(again) != Self.bits(box.packedValues))
    }
}

/// 値の写しを持つ 3 者 (塗り・効果・計算) で、旧値を積んだ後に値を変えても前の仕事が変わらないことを、
/// 宣言から作り直した同じ値の絵・結果とのビット一致で見る (#2790)。GPU を要する。
@Suite(
    "値の写しを積んだ仕事は、後の値に変わらない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderPackedSnapshotPictureTests {
    private static let before: [String: ShaderValue] = [
        "tint": .color(LinearRGBA(premultipliedRed: 0.5, green: 0.25, blue: 0.75, alpha: 1)),
        "offset": .pair(0.125, 0.5),
        "zeta": .number(0.0625),
        "amount": .number(0.875),
    ]
    private static let after: [String: ShaderValue] = [
        "tint": .color(LinearRGBA(premultipliedRed: 0.75, green: 0.5, blue: 0.125, alpha: 1)),
        "offset": .pair(0.25, 0.0625),
        "zeta": .number(0.5),
        "amount": .number(0.375),
    ]

    /// 4 つの値が別々の成分として出る塗り。取り違えた欄は色に出る。
    private static let paint = """
        float4 paint(Fragment in, Values values) {
            return float4(values.tint.g + values.zeta, values.offset.y, values.amount + values.tint.r, 1.0);
        }
        """

    private static let effect = """
        float4 effect(Pixel in, Values values) {
            return float4(values.tint.g + values.zeta, values.offset.y, values.amount + values.tint.r, 1.0);
        }
        """

    private static let stamp = """
        kernel void stamp(device float *out [[buffer(0)]],
                          constant Values &values [[buffer(MOKUME_VALUES)]],
                          uint id [[thread_position_in_grid]])
        {
            out[0] = values.tint.g + values.zeta;
            out[1] = values.offset.y;
            out[2] = values.amount + values.tint.r;
        }
        """

    private static func change(_ set: (String, ShaderValue) -> Void, to values: [String: ShaderValue]) {
        for (name, value) in values { set(name, value) }
    }

    private func bits(_ canvas: Canvas) throws -> [UInt16] {
        try canvas.target.readPixels().components.map(\.bitPattern)
    }

    @Test("塗り: 旧値で置いた図形は、後で値を変えても旧値のまま描かれる")
    func shaderKeepsEarlierShapesOnTheirValues() throws {
        let gpu = try RenderDevice()

        // 1 つの塗りの値を途中で変える
        let subject = try CanvasFixture.make(gpu: gpu, width: 32, height: 16)
        let shader = try subject.makeShader(Self.paint, values: Self.before)
        try subject.draw {
            subject.background(.linear(red: 0, green: 0, blue: 0))
            subject.noStroke()
            subject.shader(shader)
            subject.rect(0, 0, 16, 16)
            Self.change({ shader.set($0, $1) }, to: Self.after)
            subject.rect(16, 0, 16, 16)
        }

        // 値ごとに作り直した塗りで置く (値を変えない・写しは作った時のまま)
        let reference = try CanvasFixture.make(gpu: gpu, width: 32, height: 16)
        let first = try reference.makeShader(Self.paint, name: "first", values: Self.before)
        let second = try reference.makeShader(Self.paint, name: "second", values: Self.after)
        try reference.draw {
            reference.background(.linear(red: 0, green: 0, blue: 0))
            reference.noStroke()
            reference.shader(first)
            reference.rect(0, 0, 16, 16)
            reference.shader(second)
            reference.rect(16, 0, 16, 16)
        }

        let drawn = try bits(subject)
        #expect(drawn == (try bits(reference)), "値を変えた塗りの絵が、値ごとに作った塗りの絵と違う")
        #expect(subject.get(4, 8) != subject.get(20, 8), "値が変わっていない — 比べる前提が崩れている")
    }

    @Test("効果: 値を変えたフレームは、その値で作った効果と bit まで同じ絵になる")
    func effectFollowsItsValues() throws {
        let gpu = try RenderDevice()
        func picture(_ values: [String: ShaderValue], changingTo later: [String: ShaderValue]? = nil)
            throws -> [UInt16]
        {
            let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
            let effect = try canvas.makeEffect(Self.effect, values: values)
            func frame() throws {
                try canvas.draw {
                    canvas.background(.linear(red: 0.2, green: 0.2, blue: 0.2))
                    canvas.effects([.custom(effect)])
                }
            }
            try frame()
            if let later {
                Self.change({ effect.set($0, $1) }, to: later)
                try frame()
            }
            return try bits(canvas)
        }
        #expect(try picture(Self.before, changingTo: Self.after) == (try picture(Self.after)))
        #expect(try picture(Self.after) != (try picture(Self.before)), "値が絵に出ていない")
    }

    @Test("計算: 旧値で頼んだ仕事は、後で値を変えても旧値で走る")
    func computationKeepsEarlierRequestsOnTheirValues() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let first = try canvas.makeNumbers(count: 3)
        let second = try canvas.makeNumbers(count: 3)
        let stamp = try canvas.makeComputation(Self.stamp, name: "stamp", values: Self.before)

        try canvas.draw {
            canvas.compute(stamp, over: 1, writes: [first])
            Self.change({ stamp.set($0, $1) }, to: Self.after)
            canvas.compute(stamp, over: 1, writes: [second])
        }

        #expect(canvas.read(first) == [0.25 + 0.0625, 0.5, 0.875 + 0.5])
        #expect(canvas.read(second) == [0.5 + 0.5, 0.0625, 0.375 + 0.75])
    }
}
