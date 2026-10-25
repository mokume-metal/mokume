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
    static let rounds = 6

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

    /// 測り方。
    enum Method: String, CaseIterable {
        /// 1 フレームごとに GPU の終わりを待つ (M3 Max の計測と同じ)。フレームの間に GPU が遊ぶので、
        /// 周波数の段が下がったところから測りうる
        case settled = "settle"
        /// 待たずに続けて積む (GPU を埋めたまま)。25 フレームごとに待って読む。幅の他に、25 フレームの
        /// 最初の始めから最後の終わりまでを枚数で割った値 (thr) を出す
        case pipelined = "pipelined"
    }

    struct Sample {
        var widths: [Double] = []
        var throughputs: [Double] = []
    }

    /// 暖機の後 `frames` 回描き、フレームごとの GPU の幅 (ms) などを返す。
    private func measure(
        _ canvas: Canvas, _ gpu: RenderDevice, _ marks: Marks, effects: [Effect], method: Method
    ) throws -> Sample {
        func mark() {
            gpu.markFrameStart()
            marks.count += 1
        }
        func one(settle: Bool) throws {
            mark()
            try canvas.draw {
                scene(canvas)
                if !effects.isEmpty { canvas.effects(effects) }
            }
            if settle { try gpu.settle() }
        }
        let pipelined = method == .pipelined
        // 暖機は GPU の周波数が上がるまで (pipelined は埋めたまま 60 フレーム)
        if pipelined {
            for _ in 0..<60 { try one(settle: false) }
            try gpu.settle()
        } else {
            for _ in 0..<Self.warmup { try one(settle: true) }
        }
        var sample = Sample()
        var done = 0
        // 控えは直近 64 フレームなので、小分けにして読む
        let step = pipelined ? 25 : 50
        while done < Self.frames {
            let chunk = min(step, Self.frames - done)
            let first = marks.count + 1
            for _ in 0..<chunk { try one(settle: !pipelined) }
            if pipelined { try gpu.settle() }
            let last = marks.count
            mark()  // 最後のフレームを閉じる (結末は少し遅れて揃う)
            let deadline = ContinuousClock.now + .seconds(10)
            var times = gpu.completedGPUFrameTimes
            while times.last.map({ $0.frame < last }) ?? true, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.005)
                times = gpu.completedGPUFrameTimes
            }
            let inChunk = times.filter { $0.frame >= first && $0.frame <= last }
            sample.widths += inChunk.map(\.milliseconds)
            if pipelined, inChunk.count == chunk, let head = inChunk.first, let tail = inChunk.last {
                sample.throughputs.append((tail.span.end - head.span.start) * 1000 / Double(chunk))
            }
            done += chunk
        }
        return sample
    }

    @Test("4K・3/4/6 段・まとめる / まとめない / 全種入りを交互に")
    func probe() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
        defer { gpu.settleQuietly(orWarn: "計測の後片付けで GPU を待てなかった") }
        let pipeline = try canvas.effectPipeline()
        let marks = Marks()
        note("PROBE\tmachine\tframes=\(Self.frames)\twarmup=\(Self.warmup)\trounds=\(Self.rounds)")
        note("round\tchain\tmode\tpasses\tmedian_ms\tp90_ms\tmin_ms\tn\tmethod\tthr_median_ms\tthr_p90_ms\tthr_n")
        // 組み込みの種別のパイプラインを先に全部組む (冷えた初回を測りに入れない)
        for mode in Mode.allCases {
            for chain in Self.chains {
                pipeline.fusesPixelStages = mode == .fused
                pipeline.specializesBuiltinEffects = mode != .general
                _ = try measure(canvas, gpu, marks, effects: chain.effects, method: .settled)
            }
        }
        for round in 1...Self.rounds {
            for method in Method.allCases {
                for chain in Self.chains {
                    // 周ごとに順を回す (先に測るほうが得も損もしないように)
                    var modes = Mode.allCases
                    for _ in 0..<((round - 1) % modes.count) { modes.append(modes.removeFirst()) }
                    if round % 2 == 0 { modes.reverse() }
                    for mode in modes {
                        pipeline.fusesPixelStages = mode == .fused
                        pipeline.specializesBuiltinEffects = mode != .general
                        let passesBefore = canvas.effectPassesEncoded
                        let sample = try measure(canvas, gpu, marks, effects: chain.effects, method: method)
                        // 1 フレームあたりに積んだ効果の段の数 (写しの段は数えない)
                        let total = Self.frames + (method == .pipelined ? 60 : Self.warmup)
                        let passes = (canvas.effectPassesEncoded - passesBefore) / total
                        let thr = sample.throughputs
                        note(
                            "\(round)\t\(chain.name)\t\(mode.rawValue)\t\(passes)\t"
                                + String(
                                    format: "%.4f\t%.4f\t%.4f\t%d", Self.quantile(sample.widths, 0.5),
                                    Self.quantile(sample.widths, 0.9), sample.widths.min() ?? .nan, sample.widths.count)
                                + "\t\(method.rawValue)\t"
                                + String(format: "%.4f\t%.4f\t%d", Self.quantile(thr, 0.5), Self.quantile(thr, 0.9), thr.count))
                        #expect(sample.widths.count >= Self.frames / 2, "GPU 時間が揃わなかった (\(chain.name)・\(mode.rawValue))")
                    }
                }
            }
        }
    }
}
