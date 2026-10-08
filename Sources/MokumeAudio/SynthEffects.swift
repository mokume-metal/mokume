// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 合成の音を処理する素 (#1980)。``SynthKernels`` と同じく、機材にも時計にも触れず、1 標本ずつ
// 進む状態機械である。状態の置き場は作るときに 1 度だけ確保し、標本を処理する間は確保しない
// ([ADR-0042] 決定 7)。
//
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md

/// 濾波器の形。
nonisolated enum FilterShape: UInt8, Sendable {
    /// 切れ目より低い音を通す。
    case lowPass
    /// 切れ目より高い音を通す。
    case highPass
    /// 中心の周りの帯域を通す。
    case bandPass
}

/// 2 次の濾波器 (biquad)。係数は RBJ の Audio EQ Cookbook の式で、転置直接形 II で進める。
///
/// 係数と状態は倍精度で持つ。低い切れ目 (数十 Hz) で単精度だと状態が荒れるため。
nonisolated struct Biquad {
    private var b0 = 1.0
    private var b1 = 0.0
    private var b2 = 0.0
    private var a1 = 0.0
    private var a2 = 0.0
    private var z1 = 0.0
    private var z2 = 0.0

    /// 係数を決める。状態は残す (動かしている最中に切れ目を変えても途切れない)。
    ///
    /// - Parameters:
    ///   - frequency: 切れ目 (低域・高域) か中心 (帯域) の周波数 (Hz)。
    ///   - quality: 切れ目での山の高さ (Q)。0.7071 で山が出ない。
    mutating func configure(
        _ shape: FilterShape, frequency: Double, quality: Double, sampleRate: Double
    ) {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * quality)
        let a0 = 1 + alpha
        switch shape {
        case .lowPass:
            b0 = (1 - cosine) / 2
            b1 = 1 - cosine
            b2 = (1 - cosine) / 2
        case .highPass:
            b0 = (1 + cosine) / 2
            b1 = -(1 + cosine)
            b2 = (1 + cosine) / 2
        case .bandPass:
            // 中心で利得が 1 になる形
            b0 = alpha
            b1 = 0
            b2 = -alpha
        }
        a1 = -2 * cosine / a0
        a2 = (1 - alpha) / a0
        b0 /= a0
        b1 /= a0
        b2 /= a0
    }

    mutating func process(_ input: Float) -> Float {
        let x = Double(input)
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return Float(y)
    }

    /// 状態を 0 に戻す。
    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// 遅れを持つ環。置き場は作るときに 1 度だけ確保する。
nonisolated final class DelayLine {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var write = 0

    init(capacity: Int) {
        self.capacity = max(2, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// `samples` 標本前の値 (小数は前後の線形補間)。`samples` は 1 以上 `capacity - 1` 以下。
    func read(_ samples: Double) -> Float {
        let delay = min(max(samples, 1), Double(capacity - 1))
        var position = Double(write) - delay
        if position < 0 { position += Double(capacity) }
        let index = Int(position)
        let fraction = Float(position - Double(index))
        let next = index + 1 == capacity ? 0 : index + 1
        return storage[index] * (1 - fraction) + storage[next] * fraction
    }

    /// 値を置いて 1 標本進める。
    func push(_ value: Float) {
        storage[write] = value
        write = write + 1 == capacity ? 0 : write + 1
    }

    func reset() {
        storage.update(repeating: 0, count: capacity)
        write = 0
    }
}

/// 反響を繰り返すディレイ。**元の音に、`time` 秒遅れた同じ大きさの音を重ね、その音を
/// `feedback` の割合で小さくしながら繰り返す。**
///
/// 入力 `x` に対し、`e[n] = line[n - D]`、`line[n] = x[n] + feedback × e[n]`、出力は `x[n] + e[n]`。
/// インパルスを入れると、`D` 標本ごとに 1、`feedback`、`feedback²`、… の反響が並ぶ。
nonisolated final class EchoKernel {
    /// 作れる最大の遅れ (秒)。置き場を作るときに決める。
    static let maximumSeconds = 5.0
    /// 戻す割合の上限。1 に届くと減らずに溜まり続けるので、手前で止める。
    static let maximumFeedback: Float = 0.99

    private let sampleRate: Double
    private let line: DelayLine
    private(set) var delay: Double = 0
    private(set) var feedback: Float = 0.5

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        line = DelayLine(capacity: Int(Self.maximumSeconds * sampleRate) + 2)
        configure(time: 0.25, feedback: 0.5)
    }

    /// `time` 秒の遅れと戻す割合を決める。範囲の外は端へ丸める。
    func configure(time: Float, feedback: Float) {
        let seconds = min(max(Double(time), 0), Self.maximumSeconds)
        delay = max(1, seconds * sampleRate)
        self.feedback = min(max(feedback, 0), Self.maximumFeedback)
    }

    func process(_ input: Float) -> Float {
        let echo = line.read(delay)
        line.push(input + feedback * echo)
        return input + echo
    }

    func reset() {
        line.reset()
    }
}

/// リバーブ。Freeverb (Jezar at Dreampoint) の並べ方 — 並列の 8 本の櫛形濾波器の後に、直列の
/// 4 本の全域通過濾波器 — の 1 チャンネル版。
///
/// 長さは 44.1 kHz で決められたものを、標本化率に比例して直す。置き場は作るときに 1 度だけ
/// 確保する。
nonisolated final class ReverbKernel {
    private static let combLengths = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassLengths = [556, 441, 341, 225]
    /// 入力を絞る (櫛形を 8 本足すと大きくなりすぎるため)。
    private static let inputGain: Float = 0.015
    /// 残響の音を、入力と同じくらいの大きさへ戻す。
    private static let wetGain: Float = 3

    private let combs: [Comb]
    private let allpasses: [Allpass]
    private var wet: Float = 0.5

    init(sampleRate: Double) {
        let scale = sampleRate / 44_100
        combs = Self.combLengths.map { Comb(length: Int((Double($0) * scale).rounded())) }
        allpasses = Self.allpassLengths.map { Allpass(length: Int((Double($0) * scale).rounded())) }
        configure(room: 0.5, damp: 0.5, wet: 0.5)
    }

    /// 部屋の大きさ・高い音の吸われ方・残響の割合 (どれも 0〜1。範囲の外は端へ丸める)。
    func configure(room: Float, damp: Float, wet: Float) {
        let size = min(max(room, 0), 1)
        let damping = min(max(damp, 0), 1) * 0.4
        for comb in combs {
            comb.feedback = size * 0.28 + 0.7
            comb.damping = damping
        }
        self.wet = min(max(wet, 0), 1)
    }

    func process(_ input: Float) -> Float {
        let scaled = input * Self.inputGain
        var tank: Float = 0
        for comb in combs { tank += comb.process(scaled) }
        for allpass in allpasses { tank = allpass.process(tank) }
        return input * (1 - wet) + tank * Self.wetGain * wet
    }

    func reset() {
        for comb in combs { comb.reset() }
        for allpass in allpasses { allpass.reset() }
    }

    /// 高い音を吸いながら戻る櫛形濾波器。
    private nonisolated final class Comb {
        private let storage: UnsafeMutablePointer<Float>
        private let length: Int
        private var index = 0
        private var store: Float = 0
        var feedback: Float = 0.84
        var damping: Float = 0.2

        init(length: Int) {
            self.length = max(1, length)
            storage = .allocate(capacity: self.length)
            storage.initialize(repeating: 0, count: self.length)
        }

        deinit {
            storage.deallocate()
        }

        func process(_ input: Float) -> Float {
            let output = storage[index]
            store = output * (1 - damping) + store * damping
            storage[index] = input + store * feedback
            index = index + 1 == length ? 0 : index + 1
            return output
        }

        func reset() {
            storage.update(repeating: 0, count: length)
            index = 0
            store = 0
        }
    }

    /// 全域通過濾波器。残響の粒を滑らかにする。
    private nonisolated final class Allpass {
        private let storage: UnsafeMutablePointer<Float>
        private let length: Int
        private var index = 0

        init(length: Int) {
            self.length = max(1, length)
            storage = .allocate(capacity: self.length)
            storage.initialize(repeating: 0, count: self.length)
        }

        deinit {
            storage.deallocate()
        }

        func process(_ input: Float) -> Float {
            let buffered = storage[index]
            let output = buffered - input
            storage[index] = input + buffered * 0.5
            index = index + 1 == length ? 0 : index + 1
            return output
        }

        func reset() {
            storage.update(repeating: 0, count: length)
            index = 0
        }
    }
}
