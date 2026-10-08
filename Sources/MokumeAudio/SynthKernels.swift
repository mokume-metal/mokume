// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 合成の音の素 (#1980)。**どれも機材にも時計にも触れない純粋な型**で、1 標本ずつ進む状態機械
// である。描かせる区切り方 (音の側の 1 回に何標本か) で結果が変わらないので、manual rendering
// (offline) の検査が同じ設定から同じ標本列を取り出せる ([ADR-0042] 決定 6)。
//
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md

/// 発振の波形。
nonisolated enum Waveform: UInt8, Sendable {
    case sine
    case square
    case triangle
    case saw
}

/// 位相から波形の 1 標本を作る。
///
/// 位相は 0 以上 1 未満 (周期の割合) で、どの波形も位相 0 で 0 から始まる (矩形だけは 0 から
/// 正の側へ立ち上がる)。矩形とのこぎりは、素朴に作ると不連続な所で高い倍音が折り返して濁る
/// ので、PolyBLEP で不連続の前後 1 標本ずつを丸める。
nonisolated enum WaveShape {
    /// - Parameters:
    ///   - phase: 位相 (0 以上 1 未満)。
    ///   - step: 1 標本で進む位相 (周波数 ÷ 標本化率)。折り返しを抑える幅になる。
    static func sample(_ waveform: Waveform, phase: Double, step: Double) -> Float {
        switch waveform {
        case .sine:
            return Float(sin(2 * Double.pi * phase))
        case .triangle:
            if phase < 0.25 { return Float(4 * phase) }
            if phase < 0.75 { return Float(2 - 4 * phase) }
            return Float(4 * phase - 4)
        case .saw:
            // 位相 0 で 0、0.5 で下へ落ちる。のこぎり本体の不連続は、ずらした位相の 0 にある
            let shifted = (phase + 0.5).truncatingRemainder(dividingBy: 1)
            return Float(2 * shifted - 1 - blep(shifted, step))
        case .square:
            let high = phase < 0.5
            let fall = (phase + 0.5).truncatingRemainder(dividingBy: 1)
            return Float((high ? 1 : -1) + blep(phase, step) - blep(fall, step))
        }
    }

    /// 不連続の前後 1 標本ぶんを丸める補正 (PolyBLEP)。`t` は不連続からの位相。
    private static func blep(_ t: Double, _ step: Double) -> Double {
        guard step > 0 else { return 0 }
        if t < step {
            let x = t / step
            return x + x - x * x - 1
        }
        if t > 1 - step {
            let x = (t - 1) / step
            return x * x + x + x + 1
        }
        return 0
    }
}

/// ノイズの色。
nonisolated enum NoiseColor: UInt8, Sendable {
    /// 全帯域が同じ強さ。
    case white
    /// 1 オクターブごとに同じ強さ (低い帯域ほど強い)。
    case pink
}

/// ノイズを作る。**種が決まれば同じ列を返す** (固定の種から始まる擬似乱数) — 同じ順に作れば
/// 何度鳴らしても同じ音になり、検査と書き出しが決定論的になる。
nonisolated struct NoiseKernel {
    private var state: UInt64
    // ピンクにする濾波器の状態 (Paul Kellet の 7 段)
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0
    private var b3: Float = 0
    private var b4: Float = 0
    private var b5: Float = 0
    private var b6: Float = 0

    /// `seed` から始める。同じ種からは同じ列が出る。
    init(seed: UInt64) {
        // 種のばらつきを広げる (splitmix64)。0 だと xorshift が止まるので避ける
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        state = z == 0 ? 0x9E37_79B9_7F4A_7C15 : z
    }

    /// 次の標本。-1 以上 1 未満 (ピンクは約 ±1 に収まる)。
    mutating func next(_ color: NoiseColor) -> Float {
        let white = nextWhite()
        switch color {
        case .white:
            return white
        case .pink:
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            return pink * 0.11
        }
    }

    private mutating func nextWhite() -> Float {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let mixed = state &* 0x2545_F491_4F6C_DD1D
        let bits = Int32(bitPattern: UInt32(truncatingIfNeeded: mixed >> 32))
        return Float(bits) / 2_147_483_648
    }
}

/// 包絡の形 (ASR)。**立ち上がる → 保つ → 下がる** の台形で、高さは `level`。
///
/// 位置は鳴らし始めてから進んだ標本の数で、形はその位置だけで決まる。
nonisolated struct EnvelopeShape: Equatable {
    /// 0 から `level` へ上がる標本の数。
    var attack = 0
    /// `level` を保つ標本の数。
    var sustain = 0
    /// `level` から 0 へ下がる標本の数。
    var release = 0
    /// 保つ高さ (0〜1)。
    var level: Float = 1

    /// 全体の長さ (標本)。
    var length: Int { attack + sustain + release }

    /// 位置 `position` (標本) の高さ。形が終わった後は `nil`。
    func gain(at position: Int) -> Float? {
        guard position >= 0, position < length else { return nil }
        if position < attack { return level * Float(position) / Float(attack) }
        if position < attack + sustain { return level }
        let falling = position - attack - sustain
        return level * (1 - Float(falling) / Float(release))
    }

    /// 秒で与えられた形を、標本の数の形にする。負の値は 0 秒として扱う。
    init(attack: Float, sustain: Float, level: Float, release: Float, sampleRate: Double) {
        func samples(_ seconds: Float) -> Int {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return Int((Double(seconds) * sampleRate).rounded())
        }
        self.attack = samples(attack)
        self.sustain = samples(sustain)
        self.release = samples(release)
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
    }

    init() {}
}
