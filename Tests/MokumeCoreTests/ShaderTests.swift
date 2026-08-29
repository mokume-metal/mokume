// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 利用者が書いた塗りの検査。GPU を要する。
@Suite(
    "利用者が書く塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderTests {
    private func makeCanvas(width: Int = 32, height: Int = 32) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 渡した値をそのまま色にする断片。値の届き方を見るのに使う。
    private static let valueShader = """
        float4 paint(Fragment in, Values values) {
            return float4(values.level, 0.0, 0.0, 1.0);
        }
        """

    // MARK: - 経路に載ること

    @Test("断片は、図形をまとめて描く経路に載る")
    func aFragmentRidesTheBatchedPath() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            // 矩形と円を続けて置く。まとめて描く経路に載らないと、ここが対象外になる
            canvas.rect(0, 0, 16, 32)
            canvas.circle(24, 16, 12)
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(canvas.get(8, 16) == .opaque(red: 0, green: 1, blue: 0))
        #expect(canvas.get(24, 16) == .opaque(red: 0, green: 1, blue: 0))
    }

    @Test("断片は、字と画像を描く経路にも載る")
    func aFragmentAlsoRidesTheTextAndImagePaths() throws {
        let canvas = try makeCanvas(width: 64, height: 32)
        // **どちらの経路でも読む面は色である。** 読んだ濃さで青を出す 1 本で足りる
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return float4(0.0, 0.0, 1.0, 1.0) * in.texel.a;
            }
            """)
        let image = try canvas.createImage(8, 8)
        image.fill(.opaque(red: 1, green: 0, blue: 0))

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.shader(shader)
            canvas.textFont("Helvetica")
            canvas.textSize(24)
            canvas.fill(.opaque(red: 1, green: 1, blue: 1))
            canvas.text("I", 8, 26)
            canvas.image(image, 40, 8, 16, 16)
        }
        // 画像の面を読む経路でも断片が効いている (赤ではなく青になる)
        #expect(canvas.get(48, 16) == .opaque(red: 0, green: 0, blue: 1))
        // 字を読む経路でも同じ断片が効いている (白ではなく青が出ている)
        var sawBlueGlyph = false
        for y in 8..<26 {
            for x in 4..<28 {
                let pixel = canvas.get(x, y)
                if pixel.blue > 0.5, pixel.red < 0.1, pixel.green < 0.1 { sawBlueGlyph = true }
            }
        }
        #expect(sawBlueGlyph)
    }

    @Test("組み込みの塗りへ戻せる")
    func theBuiltInPaintCanBeRestored() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 32)
            canvas.resetShader()
            canvas.fill(.opaque(red: 1, green: 0, blue: 0))
            canvas.rect(16, 0, 16, 32)
        }
        #expect(canvas.get(8, 16) == .opaque(red: 0, green: 1, blue: 0))
        #expect(canvas.get(24, 16) == .opaque(red: 1, green: 0, blue: 0))
    }

    @Test("断片で塗っても、混ぜ方は組み込みと同じに効く")
    func blendingWorksTheSameUnderAUserFragment() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.25, 0.0, 0.0, 1.0); }")

        try canvas.draw {
            canvas.background(.opaque(red: 0.5, green: 0, blue: 0))
            canvas.noStroke()
            canvas.blendMode(.add)
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8).red == 0.75)
    }

    // MARK: - 渡した値

    /// 完了条件「利用者が渡した値は、列の先頭で取り込んだ値で列全体が描かれる」。
    ///
    /// **値を変えたら、そこで列が切れる。** 切れないと、既に置いた図形まで後の値で
    /// 描かれる — 前身ではこれが「2 つの図形が両方あとの値になる」形で出た。
    @Test("値を変える前に置いた図形は、変える前の値で描かれる")
    func shapesKeepTheValueTheyWereDrawnWith() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let shader = try canvas.makeShader(Self.valueShader, values: ["level": 0.25])

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
            shader.set("level", 1)
            canvas.rect(16, 0, 16, 16)
        }
        #expect(canvas.get(8, 8).red == 0.25)
        #expect(canvas.get(24, 8).red == 1)
    }

    @Test("宣言していない名前は受け付けない")
    func undeclaredNamesAreRefused() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let shader = try canvas.makeShader(Self.valueShader, values: ["level": 0.5])
        shader.set("unknown", 1)

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8).red == 0.5)
    }

    @Test("組み込みの入力が届く")
    func theBuiltInInputsArrive() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return float4(in.place.x, in.time, in.resolution.x / 64.0, 1.0);
            }
            """)
        canvas.time = 0.5

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 32, 16)
        }
        let left = canvas.get(0, 8)
        let right = canvas.get(31, 8)
        #expect(left.red < right.red, "面の中の位置が左右で変わっていない")
        #expect(left.green == 0.5, "秒数が届いていない")
        #expect(left.blue == 0.5, "面の大きさが届いていない")
    }

    // MARK: - 渡せる値の数

    /// 列 1 つぶんの区画に**ちょうど収まる**宣言 (float 換算 64 個 = 色 16 個)。
    ///
    /// `ShaderSource.pack` は成分の数 → 名前の降順で並べるので、`c00` は**区画の末尾 4 つ** —
    /// 次の区画と隣り合う位置に載る。潰れたかどうかはここを見れば分かる。
    private static func fullSlotValues(last: LinearRGBA) -> [String: ShaderValue] {
        var values: [String: ShaderValue] = ["c00": .color(last)]
        for index in 1..<16 {
            values["c\(index)"] = .color(.opaque(red: 0, green: 0, blue: 0))
        }
        return values
    }

    /// 末尾の値をそのまま色にする断片。区画の端が届いているかを見るのに使う。
    private static let lastValueShader =
        "float4 paint(Fragment in, Values values) { return values.c00; }"

    /// 完了条件「上限ちょうどの塗りを 2 つ並べても、互いの区画を潰さない」。
    @Test("上限ちょうどの値を宣言した塗りは、隣の列を潰さずに描ける")
    func aFullSlotOfValuesDoesNotSpillIntoTheNextColumn() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let green = try canvas.makeShader(
            Self.lastValueShader, name: "full-green",
            values: Self.fullSlotValues(last: .opaque(red: 0, green: 1, blue: 0)))
        let blue = try canvas.makeShader(
            Self.lastValueShader, name: "full-blue",
            values: Self.fullSlotValues(last: .opaque(red: 0, green: 0, blue: 1)))

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            // 塗りを変えると列が切れるので、区画が 2 つ並ぶ。はみ出していれば後の列が前の列を潰す
            canvas.shader(green)
            canvas.rect(0, 0, 16, 16)
            canvas.shader(blue)
            canvas.rect(16, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .opaque(red: 0, green: 1, blue: 0))
        #expect(canvas.get(24, 8) == .opaque(red: 0, green: 0, blue: 1))
    }

    /// 完了条件「1 つ超えると断られ、置き場への書き込みまで到達しない」(#348)。
    ///
    /// **超えた値で描く検査は置かない。** 描けば置き場の外へ書く経路をそのまま走らせる
    /// ことになり、検査そのものが壊れたメモリの上で動く。
    @Test("区画に収まらない数の値を宣言すると、読み込みの時点で断られる")
    func moreValuesThanASlotHoldsAreRefusedAtLoad() throws {
        let canvas = try makeCanvas()
        // 色 16 個 (64 個) に数を 1 つ足して 65 個。詰め物込みで 68 個になり、区画 (64) を超える
        var values = Self.fullSlotValues(last: .opaque(red: 0, green: 1, blue: 0))
        values["extra"] = 1

        // 詰め物込みで 68 個。何個で上限が何個かが、断る文から読めること
        #expect(
            throws: ShaderFailure.tooManyValues(path: "overflowing", count: 68, capacity: 64)
        ) {
            try canvas.makeShader(Self.lastValueShader, name: "overflowing", values: values)
        }

        // 在処から読む経路も同じ。断るのは断片の中身ではなく**宣言の数**なので、両方に効く
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try Self.lastValueShader.write(to: url, atomically: true, encoding: .utf8)
        #expect(
            throws: ShaderFailure.tooManyValues(path: url.path, count: 68, capacity: 64)
        ) {
            try canvas.loadShader(url.path, values: values)
        }
    }

    // MARK: - 組み立ての失敗

    /// 完了条件「断片のコンパイルが失敗したとき、絵が消えず、失敗の理由が観測から読める」。
    @Test("読み込みの時点で組み立てられなければ、理由のついたエラーになる")
    func aBrokenFragmentFailsToLoadWithAReason() throws {
        let canvas = try makeCanvas()
        #expect(throws: ShaderFailure.self) {
            try canvas.makeShader("float4 paint(Fragment in, Values values) { これは MSL ではない }")
        }
    }

    /// **差し替えに失敗しても、前の断片が残る。**
    ///
    /// 削ってから入れ直す形にすると、組み立てに失敗した瞬間に元の断片ごと消えて
    /// 絵が出なくなる。
    @Test("差し替えに失敗しても、絵が消えない")
    func afailedReloadKeepsThePreviousFragment() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }"
            .write(to: url, atomically: true, encoding: .utf8)

        let shader = try canvas.loadShader(url.path)
        try "これは MSL ではない".write(to: url, atomically: true, encoding: .utf8)
        shader.reload()

        #expect(shader.failure != nil)
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        // 壊れた断片を保存しても、前の断片で描かれ続ける
        #expect(canvas.get(8, 8) == .opaque(red: 0, green: 1, blue: 0))
        #expect(canvas.shaderFailures.count == 1)
    }

    // MARK: - 保存を拾う

    /// 完了条件「保存を 2 回連続で行い、2 回とも差し替わる」。
    ///
    /// **1 回だけ保存する検査には判別力が無い。** 置き換え保存のあと見張りを張り直さない
    /// 実装でも 1 回目は通り、死ぬのは 2 回目以降である。
    @Test("置き換えで保存すると、2 回続けて差し替わる", .timeLimit(.minutes(1)))
    func twoConsecutiveAtomicSavesBothArrive() async throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")

        func write(_ green: String) throws {
            // `atomically: true` は別名で書いてから置き換える保存 — 編集器がよく使う形
            try "float4 paint(Fragment in, Values values) { return float4(0.0, \(green), 0.0, 1.0); }"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try write("0.25")
        let shader = try canvas.loadShader(url.path)
        #expect(shader.generation == 0)

        // **絵で確かめる。** 差し替えの回数だけ見ても、届いた中身で描かれているかは
        // 分からない
        for green in [Float(0.5), 1] {
            let before = shader.generation
            try write("\(green)")
            try await waitUntil { shader.generation > before }
            #expect(shader.failure == nil)

            try canvas.draw {
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.shader(shader)
                canvas.rect(0, 0, 16, 16)
            }
            #expect(canvas.get(8, 8).green == green, "保存した内容で描かれていない")
        }
    }

    @Test("その場で上書きして保存しても差し替わる", .timeLimit(.minutes(1)))
    func anInPlaceSaveAlsoArrives() async throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try "float4 paint(Fragment in, Values values) { return float4(0.0, 0.25, 0.0, 1.0); }"
            .write(to: url, atomically: true, encoding: .utf8)
        let shader = try canvas.loadShader(url.path)

        // `atomically: false` は開いているファイルをその場で書き換える保存
        try "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }"
            .write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { shader.generation >= 1 }
        #expect(shader.generation >= 1)
    }

    /// **置き換え保存のあと、その場の上書きも拾える。**
    ///
    /// 置き換えられた時点で、ファイル側の見張りは**消えたファイル**を指したままになる。
    /// その場の上書きは親ディレクトリを変えないので、張り直さない実装ではここで
    /// 完全に届かなくなる。置き換えだけを 2 回続ける検査では、親ディレクトリ側が
    /// 毎回拾ってしまうので**この壊れは見つからない**。
    @Test("置き換えて保存したあと、その場で上書きしても届く", .timeLimit(.minutes(1)))
    func anInPlaceSaveAfterAnAtomicSaveStillArrives() async throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")

        func body(_ green: String) -> String {
            "float4 paint(Fragment in, Values values) { return float4(0.0, \(green), 0.0, 1.0); }"
        }
        try body("0.25").write(to: url, atomically: true, encoding: .utf8)
        let shader = try canvas.loadShader(url.path)

        // 1 回目: 置き換えで保存 (ここでファイル側の見張りの相手が入れ替わる)
        try body("0.5").write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { shader.generation >= 1 }
        // **張り直しが済むのを待つ。** 置き換えの直後は、見張りがまだ消えたファイルを
        // 指している。時間ではなく「いまその場所にあるファイルと同じか」で待つ
        try await waitUntil { shader.watcher?.watchesCurrentFile == true }

        // 2 回目: その場で上書き。親ディレクトリは変わらないので、
        // 張り直していないと誰も拾わない
        try body("1.0").write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { shader.generation >= 2 }
        #expect(shader.generation >= 2)
    }

    @Test("見張りは、ファイルと親ディレクトリの両方に張る")
    func theWatcherCoversBothTheFileAndItsDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try "x".write(to: url, atomically: true, encoding: .utf8)

        let watcher = FileWatcher(url: url) {}
        #expect(watcher.isWatchingFile)
        #expect(watcher.isWatchingDirectory)
    }

    // MARK: - 道具

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-shader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 条件が満たされるまで待つ。
    ///
    /// **待つ側が main actor を明け渡す。** 見張りは自前の待ち行列で受けてから
    /// main actor へ渡すので、待つ側が回り続けていると渡す先が空かない。
    private func waitUntil(
        _ condition: () -> Bool, within seconds: Double = 5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "\(seconds) 秒待っても届かなかった", sourceLocation: sourceLocation)
    }
}
