// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 合成の音の値の種類。主スレッドから音の側へ渡す値は、どれもこの名前を付けて渡す。
nonisolated enum SynthParam: UInt8, Sendable {
    // 音源
    case frequency
    case amplitude
    case offset
    case panning
    // 包絡 (秒)
    case attack
    case sustain
    case level
    case release
    // 濾波器
    case cutoff
    case resonance
    case bandwidth
    // リバーブ
    case room
    case damping
    case wetness
    // ディレイ
    case time
    case feedback
}

/// ラックの節 (音源かエフェクト)。**音の側のスレッドだけが状態を触る。**
///
/// 主スレッドが読んでよいのは、作るときに決まって変わらない ``id`` と ``meter`` だけである。
/// 値を変えるときは、``SynthRack`` の列へ操作を渡す。
nonisolated class RackNode {
    let id: Int
    let sampleRate: Double
    /// 出口の標本の写し。音の側が書き、フレームの側が最新の窓を読む。
    let meter: SampleRing

    init(id: Int, sampleRate: Double, meter: SampleRing) {
        self.id = id
        self.sampleRate = sampleRate
        self.meter = meter
    }

    /// 音源か (入力を取らないか)。
    var isSource: Bool { false }

    /// 何も出していない (出口が全部 0) と決まっているか。音源が止まっているとき。
    var isIdle: Bool { false }

    func apply(_ param: SynthParam, _ value: Float) {}

    /// 鳴らし始める (音源)。
    func start() {}

    /// 止める (音源)。
    func halt() {}

    /// 包絡を頭から始める (音源)。
    func trigger() {}

    /// 入力が無い状態から入力が入ったとき。前の状態を持ち越さない (エフェクト)。
    func reset() {}

    /// `frames` 標本を `output` へ作る。`input` は繋がれた入力の和 (エフェクトだけが読む)。
    func render(
        frames: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>
    ) {}

    /// 出口を左右へ足す。既定は中央 (左右とも 1/√2 — 等しい大きさで混ざる定位)。
    func mix(
        _ source: UnsafePointer<Float>, frames: Int, left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        let gain = Float(0.5).squareRoot()
        for index in 0..<frames {
            let value = source[index] * gain
            left[index] += value
            right[index] += value
        }
    }
}

/// 音源 (オシレータとノイズ)。
///
/// 値の変化は 1 標本ごとに滑らかに追う (約 5 ミリ秒)。急に変えるとぷつっと鳴るためで、
/// 追い方は標本ごとに進むので、描かせる区切り方に依らない。鳴らし始め・止めるときも同じ
/// 速さで立ち上がり・消える。
nonisolated final class SourceNode: RackNode {
    enum Kind {
        case wave(Waveform)
        case noise(NoiseColor)
    }

    private let kind: Kind
    private var noise: NoiseKernel
    private var phase = 0.0

    private var frequency: Float = 440
    private var amplitude: Float = 0.5
    private var amplitudeNow: Float = 0.5
    private var offset: Float = 0
    private var offsetNow: Float = 0
    private var panning: Float = 0
    private var panningNow: Float = 0
    private var gateTarget: Float = 0
    private var gate: Float = 0
    private let smoothing: Float

    // 包絡: 秒で受けて、始めるときに標本の数の形にする
    private var pendingAttack: Float = 0
    private var pendingSustain: Float = 0
    private var pendingLevel: Float = 1
    private var pendingRelease: Float = 0
    private var shape = EnvelopeShape()
    private var shaped = false
    private var shapeActive = false
    private var shapePosition = 0

    private var leftGain: Float = 0
    private var rightGain: Float = 0
    private var panApplied: Float = .nan

    init(id: Int, sampleRate: Double, meter: SampleRing, kind: Kind) {
        self.kind = kind
        // 種は節の番号から決める。同じ順に作れば同じ音になる
        noise = NoiseKernel(seed: UInt64(id) &* 0x1_0000_0001 &+ 0x6D6F_6B75_6D65)
        smoothing = Float(1 - exp(-1 / (0.005 * sampleRate)))
        super.init(id: id, sampleRate: sampleRate, meter: meter)
    }

    override var isSource: Bool { true }

    override var isIdle: Bool { gateTarget == 0 && gate == 0 }

    override func apply(_ param: SynthParam, _ value: Float) {
        switch param {
        case .frequency: frequency = value
        case .amplitude: amplitude = value
        case .offset: offset = value
        case .panning: panning = value
        case .attack: pendingAttack = value
        case .sustain: pendingSustain = value
        case .level: pendingLevel = value
        case .release: pendingRelease = value
        default: break
        }
    }

    override func start() {
        // 無音から始めるときは位相を頭へ戻す (同じ設定から同じ立ち上がりになる)
        if isIdle { phase = 0 }
        gateTarget = 1
    }

    override func halt() {
        gateTarget = 0
    }

    override func trigger() {
        shape = EnvelopeShape(
            attack: pendingAttack, sustain: pendingSustain, level: pendingLevel,
            release: pendingRelease, sampleRate: sampleRate)
        shaped = true
        shapeActive = true
        shapePosition = 0
    }

    /// `current` を `target` へ 1 標本ぶん近づける。**十分近づいたら (浮動小数で刻めなくなったら)
    /// `target` に揃える** — 揃えないと、1 付近では差が 1e-5 のあたりで止まって届かない。
    private func approach(_ current: Float, _ target: Float) -> Float {
        let next = current + (target - current) * smoothing
        return next == current || abs(target - next) < 1e-6 ? target : next
    }

    override func render(
        frames: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>
    ) {
        guard !isIdle else {
            output.update(repeating: 0, count: frames)
            return
        }
        let step = Double(frequency) / sampleRate
        for index in 0..<frames {
            gate = approach(gate, gateTarget)
            amplitudeNow = approach(amplitudeNow, amplitude)
            offsetNow = approach(offsetNow, offset)
            var value: Float
            switch kind {
            case .wave(let waveform):
                value = WaveShape.sample(waveform, phase: phase, step: step)
                phase += step
                if phase >= 1 { phase -= 1 }
            case .noise(let color):
                value = noise.next(color)
            }
            value = value * amplitudeNow + offsetNow
            var level = gate
            if shaped {
                if shapeActive, let gain = shape.gain(at: shapePosition) {
                    level *= gain
                    shapePosition += 1
                } else {
                    shapeActive = false
                    level = 0
                }
            }
            output[index] = value * level
        }
    }

    override func mix(
        _ source: UnsafePointer<Float>, frames: Int, left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        for index in 0..<frames {
            if panningNow != panning { panningNow = approach(panningNow, panning) }
            if panningNow != panApplied {
                // 等しい大きさで混ざる定位。-1 で左だけ、0 で左右とも 1/√2、1 で右だけ
                let angle = Double((panningNow + 1) * 0.25) * Double.pi
                leftGain = Float(cos(angle))
                rightGain = Float(sin(angle))
                panApplied = panningNow
            }
            let value = source[index]
            left[index] += value * leftGain
            right[index] += value * rightGain
        }
    }
}

/// 濾波器 (低域・高域・帯域)。
nonisolated final class FilterNode: RackNode {
    private let shape: FilterShape
    private var biquad = Biquad()
    private var cutoff: Float = 1000
    private var resonance: Float = 1
    private var bandwidth: Float = 500

    init(id: Int, sampleRate: Double, meter: SampleRing, shape: FilterShape) {
        self.shape = shape
        super.init(id: id, sampleRate: sampleRate, meter: meter)
        configure()
    }

    override func apply(_ param: SynthParam, _ value: Float) {
        switch param {
        case .cutoff: cutoff = value
        case .resonance: resonance = value
        case .bandwidth: bandwidth = value
        default: return
        }
        configure()
    }

    private func configure() {
        let frequency = min(max(Double(cutoff), 10), sampleRate * 0.49)
        let quality: Double
        switch shape {
        case .bandPass:
            // 帯域の幅 (Hz) から、中心に対する Q へ
            quality = min(max(frequency / max(Double(bandwidth), 1), 0.1), 100)
        case .lowPass, .highPass:
            quality = min(max(Double(resonance), 0.1), 100)
        }
        biquad.configure(shape, frequency: frequency, quality: quality, sampleRate: sampleRate)
    }

    override func reset() {
        biquad.reset()
    }

    override func render(
        frames: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>
    ) {
        for index in 0..<frames { output[index] = biquad.process(input[index]) }
    }
}

/// リバーブ。
nonisolated final class ReverbNode: RackNode {
    private let kernel: ReverbKernel
    private var room: Float = 0.5
    private var damping: Float = 0.5
    private var wetness: Float = 0.5

    override init(id: Int, sampleRate: Double, meter: SampleRing) {
        kernel = ReverbKernel(sampleRate: sampleRate)
        super.init(id: id, sampleRate: sampleRate, meter: meter)
    }

    override func apply(_ param: SynthParam, _ value: Float) {
        switch param {
        case .room: room = value
        case .damping: damping = value
        case .wetness: wetness = value
        default: return
        }
        kernel.configure(room: room, damp: damping, wet: wetness)
    }

    override func reset() {
        kernel.reset()
    }

    override func render(
        frames: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>
    ) {
        for index in 0..<frames { output[index] = kernel.process(input[index]) }
    }
}

/// ディレイ。
nonisolated final class DelayNode: RackNode {
    private let kernel: EchoKernel
    private var time: Float = 0.25
    private var feedback: Float = 0.5

    override init(id: Int, sampleRate: Double, meter: SampleRing) {
        kernel = EchoKernel(sampleRate: sampleRate)
        super.init(id: id, sampleRate: sampleRate, meter: meter)
    }

    override func apply(_ param: SynthParam, _ value: Float) {
        switch param {
        case .time: time = value
        case .feedback: feedback = value
        default: return
        }
        kernel.configure(time: time, feedback: feedback)
    }

    override func reset() {
        kernel.reset()
    }

    override func render(
        frames: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>
    ) {
        for index in 0..<frames { output[index] = kernel.process(input[index]) }
    }
}
