// 使い捨ての計測 (#2976)。マージしない。release で走らせ、結果を .build/fuse-probe/ と標準出力へ書く。
import Foundation
import Testing

@testable import MokumeCore

private let scratch = FileManager.default.currentDirectoryPath + "/.build/fuse-probe"

private func note(_ line: String) {
    let label = ProcessInfo.processInfo.environment["PROBE_LABEL"] ?? "run"
    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    print(line)
    let path = "\(scratch)/probe-\(label).tsv"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}

/// 画素ごとの効果をまとめる / まとめないを、同じバイナリ・同じ Canvas で切り替えて、4K の GPU の
/// 壁時計 (フレームの投入の `min(start)`〜`max(end)`・``RenderDevice/completedGPUFrameTimes``) を測る。
@Suite(
    "融合の計測 (#2976)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable && ProcessInfo.processInfo.environment["MOKUME_FUSE_PROBE"] == "1",
        "MOKUME_FUSE_PROBE=1 のときだけ走る使い捨ての計測")
)
struct EffectFuseProbe2976 {
    static let width = 3840
    static let height = 2160
    static let warmup = 5
    static let frames = 200
    static let rounds = 4

    enum Mode: String, CaseIterable {
        /// 直し 1 の上で、まとめない (段ごとに別のパス)
        case apart = "特化・まとめない"
        /// 直し 1 の上で、まとめる
        case fused = "特化・まとめる"
        /// 直し 1 の前の形 (全種入りの 1 本・まとめない)。参考
        case general = "全種入り・まとめない"
    }

    static let chains: [(name: String, effects: [Effect])] = [
        ("0 段", []),
        ("3 段", [.invert(amount: 0.7), .monochrome(amount: 0.6), .vignette(amount: 0.65)]),
        (
            "4 段",
            [.invert(amount: 0.7), .monochrome(amount: 0.6), .vignette(amount: 0.65), .adjust(brightness: 0.1)]
        ),
        (
            "6 段",
            [
                .invert(amount: 0.7), .monochrome(amount: 0.6), .vignette(amount: 0.65), .adjust(brightness: 0.1),
                .invert(amount: 0.3), .vignette(amount: 0.3),
            ]
        ),
    ]

    private func scene(_ canvas: Canvas) {
        canvas.background(.display(red: 0.05, green: 0.05, blue: 0.08))
        canvas.noStroke()
        canvas.fill(.display(red: 0.9, green: 0.7, blue: 0.2))
        for index in 0..<40 {
            canvas.circle(Float(index % 8) * 440 + 260, Float(index / 8) * 400 + 260, 300)
        }
    }

    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[Int((Double(sorted.count - 1) * q).rounded())]
    }

    /// フレームの区切りを積んだ回数 (``RenderDevice/markFrameStart()`` の呼び出し数・フレーム番号の元)。
    private final class Marks { var count = 0 }

    /// 暖機の後 `frames` 回描き、フレームごとの GPU の幅 (ms) を返す。
    private func measure(
        _ canvas: Canvas, _ gpu: RenderDevice, _ marks: Marks, effects: [Effect]
    ) throws -> [Double] {
        func mark() {
            gpu.markFrameStart()
            marks.count += 1
        }
        func one() throws {
            mark()
            try canvas.draw {
                scene(canvas)
                if !effects.isEmpty { canvas.effects(effects) }
            }
            try gpu.settle()
        }
        for _ in 0..<Self.warmup { try one() }
        var millis: [Double] = []
        var done = 0
        // 控えは直近 64 フレームなので、50 フレームずつ読む
        while done < Self.frames {
            let chunk = min(50, Self.frames - done)
            let first = marks.count + 1
            for _ in 0..<chunk { try one() }
            let last = marks.count
            mark()  // 最後のフレームを閉じる (結末は少し遅れて揃う)
            let deadline = ContinuousClock.now + .seconds(10)
            var times = gpu.completedGPUFrameTimes
            while times.last.map({ $0.frame < last }) ?? true, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.005)
                times = gpu.completedGPUFrameTimes
            }
            millis += times.filter { $0.frame >= first && $0.frame <= last }.map(\.milliseconds)
            done += chunk
        }
        return millis
    }

    @Test("4K・3/4/6 段・まとめる / まとめない / 全種入りを交互に")
    func probe() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
        defer { gpu.settleQuietly(orWarn: "計測の後片付けで GPU を待てなかった") }
        let pipeline = try canvas.effectPipeline()
        let marks = Marks()
        note("PROBE\tmachine\tframes=\(Self.frames)\twarmup=\(Self.warmup)\trounds=\(Self.rounds)")
        note("round\tchain\tmode\tpasses\tmedian_ms\tp90_ms\tmin_ms\tn")
        // 組み込みの種別のパイプラインを先に全部組む (冷えた初回を測りに入れない)
        for mode in Mode.allCases {
            for chain in Self.chains {
                pipeline.fusesPixelStages = mode == .fused
                pipeline.specializesBuiltinEffects = mode != .general
                _ = try measure(canvas, gpu, marks, effects: chain.effects)
            }
        }
        for round in 1...Self.rounds {
            for chain in Self.chains {
                // 周ごとに順を回す (先に測るほうが得も損もしないように)
                var modes = Mode.allCases
                for _ in 0..<((round - 1) % modes.count) { modes.append(modes.removeFirst()) }
                if round % 2 == 0 { modes.reverse() }
                for mode in modes {
                    pipeline.fusesPixelStages = mode == .fused
                    pipeline.specializesBuiltinEffects = mode != .general
                    let passesBefore = canvas.effectPassesEncoded
                    let millis = try measure(canvas, gpu, marks, effects: chain.effects)
                    // 1 フレームあたりに積んだ効果の段の数 (写しの段は数えない)
                    let passes = (canvas.effectPassesEncoded - passesBefore) / (Self.warmup + Self.frames)
                    note(
                        "\(round)\t\(chain.name)\t\(mode.rawValue)\t\(passes)\t"
                            + String(format: "%.4f\t%.4f\t%.4f\t%d", Self.quantile(millis, 0.5), Self.quantile(millis, 0.9),
                                     millis.min() ?? .nan, millis.count))
                    #expect(millis.count >= Self.frames / 2, "GPU 時間が揃わなかった (\(chain.name)・\(mode.rawValue))")
                }
            }
        }
    }
}
