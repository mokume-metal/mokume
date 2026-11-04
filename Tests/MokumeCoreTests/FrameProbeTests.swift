// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 代表的な場面のフレームの内訳 — CPU ms・GPU ms・列の数・最大の足跡 — を取る手順
/// ([#2378](https://github.com/mokume-metal/mokume/issues/2378))。**性能の子の Issue の計測は、ここを使う。**
///
/// **普段は走らない。** `MOKUME_FRAME_PROBE=1` のときだけ走る (`make test-release` にも `make test` にも
/// 入っていない・新しい検査やゲートではなく、手で打つ計測の入口である)。出力は 1 行 1 値の
/// `PROBE\t<場面>\t<指標>\t<値>\t<単位>` で、`grep ^PROBE` で集める。
///
/// ## 手順
///
/// 1. release を組む。**枠の外で先に済ませる** (組む間、他の計測を待たせない):
///
///    ```bash
///    swift build --build-tests -c release -Xswiftc -enable-testing
///    ```
///
/// 2. 枠を全部取って、**この suite だけを単発で**走らせる (GPU を使う計測は `scripts/gpu-slot.py` を通す。
///    重ねて走らせると数字が汚れる):
///
///    ```bash
///    MOKUME_FRAME_PROBE=1 python3 scripts/gpu-slot.py --exclusive -- \
///      swift test -c release -Xswiftc -enable-testing --skip-build --filter FrameProbeTests
///    ```
///
/// 3. 変更の前後を比べるときは、前 (`origin/main`) と後で同じ手順を打ち、`PROBE` の行を並べる。
///    **debug の数字を根拠にしない** (AGENTS.md「性能を測る」)。
///
/// ## 取るもの
///
/// | 指標 | 意味 |
/// | --- | --- |
/// | `cpu.median` / `cpu.p90` | `advance()` が返るまで (CPU の壁時計)。draw と描き切りと投入を含み、GPU の完了は待たない |
/// | `gpu.median` / `gpu.p90` | そのフレームの投入の `min(start)`〜`max(end)` の幅 (``RenderDevice/completedGPUFrameTimes``)。**投入の幅であって、GPU の稼働時間でも使用率でもない** (投入の隙間を含む)。値は 1〜2 フレーム遅れて揃うので、直近のフレームは含まれないことがある (`gpu.frames` が数) |
/// | `batches` | 描く列の数 (`drawCallsInLastFrame`) |
/// | `draws` | 積んだ描く呼び出しの数 (`drawsEncodedInLastFrame`) |
/// | `footprintPeak` | このプロセスの最大の物理フットプリント (`task_vm_info` の `ledger_phys_footprint_peak`)。**プロセス全体の最大値** なので、場面を足すと後の場面は前の最大を引き継ぐ |
///
/// 場面は 3 つ: `columns` (塗りだけ・輪郭だけの矩形を交互に 20,000 個置く — 列が 20,000 本になる・#2364)、
/// `vertices` (三角形 20,000 個の頂点を 1 本の `beginShape(.triangles)` に積む — 平面の頂点を積む場面)、
/// `circles` (円 2,000 個 — 1 回の instanced draw に束ねられる軽い場面で、他の 2 つと見比べる)。
///
/// 加えて、**動く三角形の組み立て**の場面 `moving.<2d|3d>.<頂点数>` (#3416): 毎フレーム位置をずらした三角形を
/// 1 本の `beginShape(.triangles)` に 600・6 万・60 万頂点積む。3D は `vertex(x, y, z)` で面の向きを形から
/// 求める (法線を書かない) のを基準にし、`moving.3d-normal.60000` だけ `normal(_:_:_:)` を書いた対照にする。
/// **場面ごとに別のプロセスで打つ** (`footprintPeak` は前の場面の最大を引き継ぐ):
///
/// ```bash
/// MOKUME_FRAME_PROBE=1 python3 scripts/gpu-slot.py --exclusive -- \
///   swift test -c release -Xswiftc -enable-testing --skip-build --filter 'FrameProbeTests/moving3D60k'
/// ```
@Suite(
    "フレームの内訳の計測",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable && ProcessInfo.processInfo.environment["MOKUME_FRAME_PROBE"] == "1",
        "MOKUME_FRAME_PROBE=1 のときだけ走る手で打つ計測 (手順は冒頭の説明)")
)
struct FrameProbeTests {
    /// 暖機に回すフレーム数。
    static let warmup = 10
    /// 測るフレーム数。**フレームの区切りを覚える数 (``RenderDevice/rememberedFrames``) より小さく**
    /// して、測った全部の GPU 時間を読めるようにする。
    static let measured = 40

    /// 列が 20,000 本になる場面。
    final class Columns: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 1024, height: 768) }
        func draw() {
            background(.display(red: 0.05, green: 0.05, blue: 0.08))
            strokeWeight(1)
            for index in 0..<20_000 {
                let x = Float(index % 200) * 5
                let y = Float(index / 200) * 7
                if index.isMultiple(of: 2) {
                    noStroke()
                    fill(.display(red: 0.9, green: 0.4, blue: 0.2))
                } else {
                    noFill()
                    stroke(.display(red: 0.4, green: 0.8, blue: 0.9))
                }
                rect(x, y, 4, 4)
            }
        }
    }

    /// 三角形 20,000 個の頂点を 1 本に積む場面 (60,000 頂点)。
    final class Vertices: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 1024, height: 768) }
        func draw() {
            background(.display(red: 0.05, green: 0.05, blue: 0.08))
            noStroke()
            fill(.display(red: 0.7, green: 0.5, blue: 0.9))
            beginShape(.triangles)
            for index in 0..<20_000 {
                let x = Float(index % 200) * 5
                let y = Float(index / 200) * 7
                vertex(x, y)
                vertex(x + 4, y)
                vertex(x, y + 4)
            }
            endShape()
        }
    }

    /// 毎フレーム位置をずらした三角形を 1 本の `beginShape(.triangles)` に積む場面 (#3416)。
    ///
    /// 三角形は格子に並べ、`frameCount` で全体を少しずつずらす (毎フレーム頂点の位置が変わる)。3D は
    /// 奥行きを 3 段に振るので、置き直し (`placedVertices`) と面の向きの足し込みを通る。
    final class MovingTriangles: Sketch {
        var triangles = 0
        var hasDepth = false
        var writesNormal = false
        init() {}
        convenience init(triangles: Int, hasDepth: Bool, writesNormal: Bool = false) {
            self.init()
            self.triangles = triangles
            self.hasDepth = hasDepth
            self.writesNormal = writesNormal
        }
        var settings: SketchSettings { SketchSettings(width: 1024, height: 768) }
        func draw() {
            background(.display(red: 0.05, green: 0.05, blue: 0.08))
            noStroke()
            fill(.display(red: 0.7, green: 0.5, blue: 0.9))
            let shift = Float(frameCount % 8)
            beginShape(.triangles)
            if writesNormal { normal(0, 0, 1) }
            for index in 0..<triangles {
                let x = Float(index % 500) * 2 + shift
                let y = Float((index / 500) % 380) * 2 + shift * 0.5
                if hasDepth {
                    let z = Float(index % 3) * -2
                    vertex(x, y, z)
                    vertex(x + 2, y, z)
                    vertex(x, y + 2, z)
                } else {
                    vertex(x, y)
                    vertex(x + 2, y)
                    vertex(x, y + 2)
                }
            }
            endShape()
        }
    }

    /// 円 2,000 個。
    final class Circles: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 960, height: 540) }
        func draw() {
            background(.display(red: 0.05, green: 0.05, blue: 0.08))
            noStroke()
            fill(.display(red: 0.9, green: 0.7, blue: 0.2))
            for index in 0..<2_000 {
                circle(Float(index % 50) * 19 + 10, Float(index / 50) * 13 + 10, 6)
            }
        }
    }

    /// プロセスの最大の物理フットプリント (バイト)。読めなければ nil。
    private static func footprintPeak() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : nil
    }

    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[Int((Double(sorted.count - 1) * q).rounded())]
    }

    private static func emit(_ scene: String, _ metric: String, _ value: Double, _ unit: String) {
        print("PROBE\t\(scene)\t\(metric)\t\(String(format: "%.4f", value))\t\(unit)")
    }

    /// 場面を回して内訳を出す。
    private func probe(_ scene: String, sketch: some Sketch) throws {
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        let gpu = runtime.target.gpu
        defer { gpu.settleQuietly(orWarn: "計測の後片付けで GPU を待てなかった") }

        var cpu: [Double] = []
        for index in 0..<(Self.warmup + Self.measured) {
            let started = ContinuousClock.now
            try runtime.advance()
            let elapsed = ContinuousClock.now - started
            if index >= Self.warmup {
                let parts = elapsed.components
                cpu.append((Double(parts.seconds) + Double(parts.attoseconds) * 1e-18) * 1000)
            }
        }
        // 最後のフレームの結末まで揃えてから読む (検査の側で待つ。GPU の側の待ちを足さない)
        let deadline = ContinuousClock.now + .seconds(10)
        var times = gpu.completedGPUFrameTimes
        while times.count < Self.warmup + Self.measured - 2 && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            times = gpu.completedGPUFrameTimes
        }
        let measuredFrom = Self.warmup + 1
        let gpuMs = times.filter { $0.frame >= measuredFrom }.map(\.milliseconds)

        Self.emit(scene, "cpu.median", Self.quantile(cpu, 0.5), "ms")
        Self.emit(scene, "cpu.p90", Self.quantile(cpu, 0.9), "ms")
        Self.emit(scene, "gpu.median", Self.quantile(gpuMs, 0.5), "ms")
        Self.emit(scene, "gpu.p90", Self.quantile(gpuMs, 0.9), "ms")
        Self.emit(scene, "gpu.frames", Double(gpuMs.count), "count")
        Self.emit(scene, "batches", Double(runtime.canvas.drawCallsInLastFrame), "count")
        Self.emit(scene, "draws", Double(runtime.canvas.drawsEncodedInLastFrame), "count")
        if let peak = Self.footprintPeak() {
            Self.emit(scene, "footprintPeak", Double(peak) / 1_048_576, "MiB")
        }
        // 取れたことは見る (取れていなければ、この計測は何も見ていない)
        #expect(!gpuMs.isEmpty, "GPU 時間が 1 つも揃わなかった (\(scene))")
    }

    @Test("列が 20,000 本になる場面")
    func columns() throws { try probe("columns", sketch: Columns()) }

    @Test("三角形 20,000 個の頂点を 1 本に積む場面")
    func vertices() throws { try probe("vertices", sketch: Vertices()) }

    @Test("円 2,000 個 (軽い場面・見比べる基準)")
    func circles() throws { try probe("circles", sketch: Circles()) }

    // 動く三角形の組み立て (#3416)。600 頂点は小入力の対照

    @Test("動く平面の三角形・600 頂点")
    func moving2D600() throws { try probe("moving.2d.600", sketch: MovingTriangles(triangles: 200, hasDepth: false)) }

    @Test("動く平面の三角形・6 万頂点")
    func moving2D60k() throws {
        try probe("moving.2d.60000", sketch: MovingTriangles(triangles: 20_000, hasDepth: false))
    }

    @Test("動く平面の三角形・60 万頂点")
    func moving2D600k() throws {
        try probe("moving.2d.600000", sketch: MovingTriangles(triangles: 200_000, hasDepth: false))
    }

    @Test("動く立体の三角形・600 頂点 (面の向きを形から求める)")
    func moving3D600() throws { try probe("moving.3d.600", sketch: MovingTriangles(triangles: 200, hasDepth: true)) }

    @Test("動く立体の三角形・6 万頂点 (面の向きを形から求める)")
    func moving3D60k() throws {
        try probe("moving.3d.60000", sketch: MovingTriangles(triangles: 20_000, hasDepth: true))
    }

    @Test("動く立体の三角形・60 万頂点 (面の向きを形から求める)")
    func moving3D600k() throws {
        try probe("moving.3d.600000", sketch: MovingTriangles(triangles: 200_000, hasDepth: true))
    }

    @Test("動く立体の三角形・6 万頂点 (面の向きを書いた対照)")
    func moving3DNormal60k() throws {
        try probe(
            "moving.3d-normal.60000", sketch: MovingTriangles(triangles: 20_000, hasDepth: true, writesNormal: true))
    }
}
