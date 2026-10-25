// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 列を積むときの状態の記録 (``EncodedStateMemory``) の検査 ([#2364])。
///
/// 前の列と同じ設定を飛ばし、基本図形の列は読まない口を束ねない。どちらも絵は変わらない約束で、
/// 飛ばしすぎると**前の列の番地・面・切り抜きが黙って残る**。数だけ見ても気づけないので、
/// 記録の判定そのものと、種類の違う列を交互に積んだ絵が、1 つずつ単独で描いた絵と画素で
/// 一致することの両方で見る。
///
/// [#2364]: https://github.com/mokume-metal/mokume/issues/2364
struct EncodedStateMemoryTests {
    @Test("空の記録は、どの設定も「変わった」と答える。同じ値の 2 度目は変わっていない")
    func firstAskAlwaysChangesAndRepeatDoesNot() {
        var memory = EncodedStateMemory()
        let asked1 = memory.changes(address: 0x1000, index: 3)
        #expect(asked1)
        let asked2 = memory.changes(address: 0x1000, index: 3)
        #expect(!asked2)
        let asked3 = memory.changes(address: 0x1100, index: 3)
        #expect(asked3, "番地が変わるのに変わっていないと答えた")
        let asked4 = memory.changes(address: 0x1100, index: 4)
        #expect(asked4, "口が違えば別の記録である")

        // 同一性で比べるので、比べる間は持ち主を生かしておく (解放されると同じ番号が再利用される)
        let owners = [Marker(), Marker(), Marker()]
        let texture = ObjectIdentifier(owners[0])
        let asked5 = memory.changes(texture: texture, index: 0)
        #expect(asked5)
        let asked6 = memory.changes(texture: texture, index: 0)
        #expect(!asked6)
        let asked7 = memory.changes(texture: texture, index: 2)
        #expect(asked7, "口が違えば別の記録である")
        let asked8 = memory.changes(texture: ObjectIdentifier(owners[1]), index: 0)
        #expect(asked8)

        let asked9 = memory.changes(pipeline: ObjectIdentifier(owners[2]))
        #expect(asked9)
        let asked10 = memory.changes(frontFacing: .clockwise)
        #expect(asked10)
        let asked11 = memory.changes(frontFacing: .clockwise)
        #expect(!asked11)
        let asked12 = memory.changes(frontFacing: .counterClockwise)
        #expect(asked12)
        let asked13 = memory.changes(cullMode: .none)
        #expect(asked13)
        let asked14 = memory.changes(cullMode: .none)
        #expect(!asked14)
        let asked15 = memory.changes(cullMode: .back)
        #expect(asked15)
    }

    @Test("パイプラインと深度の状態は同一性で比べる。深度なしも 1 つの値である")
    func pipelineAndDepthCompareByIdentity() {
        var memory = EncodedStateMemory()
        let owners = [Marker(), Marker()]
        let first = ObjectIdentifier(owners[0])
        let second = ObjectIdentifier(owners[1])
        let asked16 = memory.changes(pipeline: first)
        #expect(asked16)
        let asked17 = memory.changes(pipeline: first)
        #expect(!asked17)
        let asked18 = memory.changes(pipeline: second)
        #expect(asked18)
        let asked19 = memory.changes(pipeline: first)
        #expect(asked19, "戻った設定を同じとみなした")

        let asked20 = memory.changes(depth: nil)
        #expect(asked20, "最初の「深度なし」は設定する")
        let asked21 = memory.changes(depth: nil)
        #expect(!asked21)
        let asked22 = memory.changes(depth: first)
        #expect(asked22)
        let asked23 = memory.changes(depth: nil)
        #expect(asked23, "状態から状態なしへの変わり目を見逃した")
    }

    @Test("切り抜きなしも 1 つの値で、切り抜きの矩形が変わるときだけ設定し直す")
    func clipComparesIncludingNoClip() {
        var memory = EncodedStateMemory()
        let rect = Canvas.ClipRect(left: 0, top: 0, right: 8, bottom: 8)
        let other = Canvas.ClipRect(left: 0, top: 0, right: 8, bottom: 9)
        let asked24 = memory.changes(clip: nil)
        #expect(asked24, "最初の「切り抜きなし」は設定する")
        let asked25 = memory.changes(clip: nil)
        #expect(!asked25)
        let asked26 = memory.changes(clip: rect)
        #expect(asked26)
        let asked27 = memory.changes(clip: rect)
        #expect(!asked27)
        let asked28 = memory.changes(clip: other)
        #expect(asked28)
        let asked29 = memory.changes(clip: nil)
        #expect(asked29, "切り抜きから切り抜きなしへの変わり目を見逃した")
    }

    @Test("捨て方を忘れると、同じ捨て方でも設定し直す。ほかの記録は残る")
    func forgettingTheCullModeOnlyForgetsIt() {
        var memory = EncodedStateMemory()
        _ = memory.changes(cullMode: .back)
        _ = memory.changes(frontFacing: .clockwise)
        memory.forgetCullMode()
        let asked30 = memory.changes(cullMode: .back)
        #expect(asked30, "忘れたのに設定し直さない")
        let asked31 = memory.changes(frontFacing: .clockwise)
        #expect(!asked31)
    }

    private final class Marker {}
}

/// 種類の違う列を交互に積んでも、単独で描いた絵と同じ画素になること。GPU を要する。
@Suite(
    "種類の違う列を交互に積んでも絵が変わらない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct InterleavedBatchesDrawTheSameTests {
    private static let width = 320
    private static let height = 96
    private static let cell = 32

    private static let level = """
        float4 paint(Fragment in, Values values) { return float4(values.level, 0.3, 0.2, 1); }
        """

    /// 1 つの要素。`column` 番目の帯の中に収まる。
    private struct Piece {
        let name: String
        let column: Int
        let draw: (Canvas) throws -> Void
    }

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.width, height: Self.height)
    }

    /// 要素ごとの設定の持ち越しを断つ。**どの要素も、自分の設定を全部書く。**
    private func reset(_ canvas: Canvas) {
        canvas.resetShader()
        canvas.noTexture()
        canvas.noClip()
        canvas.noStroke()
        canvas.noFill()
    }

    private func pieces(on canvas: Canvas) throws -> [Piece] {
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
        let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
        let sheet = try canvas.createImage(2, 2)
        sheet.set(0, 0, .linear(red: 1, green: 1, blue: 0))
        sheet.set(1, 0, .linear(red: 0, green: 1, blue: 1))
        sheet.set(0, 1, .linear(red: 1, green: 0, blue: 1))
        sheet.set(1, 1, .linear(red: 1, green: 1, blue: 1))
        let other = try canvas.createImage(2, 2)
        other.fill(.linear(red: 0.2, green: 0.6, blue: 0.9))
        let shader = try canvas.makeShader(Self.level, values: ["level": 0.2])

        func x(_ column: Int) -> Float { Float(column * Self.cell + 4) }
        func centre(_ column: Int) -> Float { Float(column * Self.cell + Self.cell / 2) }
        let middle = Float(Self.height) / 2
        return [
            // 基本図形 (塗りだけ)
            Piece(name: "form fill", column: 0) { c in
                self.reset(c)
                c.fill(red)
                c.rect(x(0), 4, 24, 24)
            },
            // 平面 + 面 (読む面と字の焼き場の口を束ねる)
            Piece(name: "flat texture", column: 1) { c in
                self.reset(c)
                c.texture(sheet)
                c.fill(255)
                c.rect(x(1), 4, 24, 24)
            },
            // 基本図形 (塗りと輪郭) + 切り抜き
            Piece(name: "form clipped", column: 2) { c in
                self.reset(c)
                c.fill(green)
                c.stroke(blue)
                c.strokeWeight(2)
                c.clip(x(2), 4, 12, 24)
                c.rect(x(2), 4, 24, 24)
            },
            // 平面 + 利用者の断片 (値の口)
            Piece(name: "flat shader 0.2", column: 3) { c in
                self.reset(c)
                shader.set("level", 0.2)
                c.shader(shader)
                c.fill(255)
                c.rect(x(3), 4, 24, 24)
            },
            // 基本図形 (輪郭だけ)
            Piece(name: "form stroke", column: 4) { c in
                self.reset(c)
                c.stroke(red)
                c.strokeWeight(3)
                c.rect(x(4) + 2, 6, 20, 20)
            },
            // 同じ断片で値だけが違う列 (値の番地が変わる)
            Piece(name: "flat shader 0.9", column: 5) { c in
                self.reset(c)
                shader.set("level", 0.9)
                c.shader(shader)
                c.fill(255)
                c.rect(x(5), 4, 24, 24)
            },
            // 半透明の立体 (裏 → 表の順で置き場所ごとに描く。捨て方を書き換える経路)
            Piece(name: "solid translucent", column: 6) { c in
                self.reset(c)
                c.fill(.display(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.5))
                c.translate(centre(6), middle + 20, 0)
                c.box(12)
            },
            // 片面の立体を裏から見る (捨てない列。前の列が捨て方を書き換えていても捨てられない)
            Piece(name: "solid plane from behind", column: 7) { c in
                self.reset(c)
                c.fill(red)
                c.translate(centre(7), middle + 20, 0)
                c.rotateY(Float.pi)
                c.plane(20, 20)
            },
            // 別の面を貼る平面 (面が変わる)
            Piece(name: "flat other texture", column: 8) { c in
                self.reset(c)
                c.texture(other)
                c.fill(255)
                c.rect(x(8), 4, 24, 24)
            },
            // 不透明な立体 (光・材質・周囲の口。表だけを描く)
            Piece(name: "solid lit", column: 9) { c in
                self.reset(c)
                c.fill(green)
                c.translate(centre(9), middle + 20, 0)
                c.box(12)
            },
        ]
    }

    /// 要素を 1 つ描く。**変換は持ち越さない。**
    private func place(_ piece: Piece, on canvas: Canvas) throws {
        canvas.push()
        defer { canvas.pop() }
        try piece.draw(canvas)
    }

    private func picture(_ canvas: Canvas, _ body: (Canvas) throws -> Void) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(0)
            // 光は置くたびに足されるので、要素の中では置かず、フレームに 1 度だけ置く
            canvas.lights()
            do { try body(canvas) } catch { Issue.record("描けなかった: \(error)") }
        }
        return try canvas.target.encodeForDisplay()
    }

    /// 帯 `column` の画素が、`a` と `b` で 1 つも違わないか。違う画素の数を返す。
    private func differingPixels(_ a: DisplayImage, _ b: DisplayImage, column: Int) -> Int {
        var count = 0
        for y in 0..<Self.height {
            for x in (column * Self.cell)..<((column + 1) * Self.cell) where a[x, y] != b[x, y] {
                count += 1
            }
        }
        return count
    }

    @Test("基本図形・平面・立体を交互に積んだ絵が、要素を 1 つずつ単独で描いた絵と画素まで同じ")
    func interleavedKindsMatchSoloDrawings() throws {
        let canvas = try makeCanvas()
        let all = try pieces(on: canvas)

        // 単独で描く: 要素 1 つだけを黒地へ
        var solo: [DisplayImage] = []
        for piece in all {
            solo.append(try picture(canvas) { try place(piece, on: $0) })
        }
        let together = try picture(canvas) { canvas in
            for piece in all { try place(piece, on: canvas) }
        }
        for (piece, alone) in zip(all, solo) {
            #expect(
                differingPixels(together, alone, column: piece.column) == 0,
                "\(piece.name): 交互に積むと単独のときと絵が違う")
        }
        // 検査が空振りしていない: どの要素も帯の中に何かを描いている
        for (piece, alone) in zip(all, solo) {
            let lit = (0..<Self.height).contains { y in
                ((piece.column * Self.cell)..<((piece.column + 1) * Self.cell)).contains { x in
                    alone[x, y] != (0, 0, 0, 255)
                }
            }
            #expect(lit, "\(piece.name): 単独で描いても何も出ていない")
        }
    }

    @Test("同じ並びを逆順に積んでも、帯ごとの絵は変わらない")
    func reversedOrderDrawsTheSameBands() throws {
        let canvas = try makeCanvas()
        let all = try pieces(on: canvas)
        let forward = try picture(canvas) { canvas in
            for piece in all { try place(piece, on: canvas) }
        }
        let backward = try picture(canvas) { canvas in
            for piece in all.reversed() { try place(piece, on: canvas) }
        }
        for piece in all {
            #expect(
                differingPixels(forward, backward, column: piece.column) == 0,
                "\(piece.name): 積む順を変えると絵が変わる")
        }
    }
}
