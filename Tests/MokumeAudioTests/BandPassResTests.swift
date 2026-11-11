// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// `BandPass.res(_:)` (#3706)。白色雑音を帯域通過に通し、出力の `spectrum` から -3 dB の幅を測る。
/// 持ち主のいないステージを固定の時計 (60 fps) で回すので、GPU も音の機材も要らない。
@Suite("合成した音: 帯域通過の Q", .serialized)
struct BandPassResTests {
    /// 帯域 1 本の幅 (Hz)。48000 ÷ 1024。
    private static let bandWidth: Float = 46.875

    /// 白色雑音を `configure` した帯域通過に通し、2 フレーム目から 120 フレームぶんの帯域ごとのパワーを平均する。
    private func powers(
        _ notices: NoticeLog = NoticeLog(), configure: (BandPass) -> Void
    ) -> [Float] {
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { notices.append($0) })
        stage.pace = .frames(perSecond: 60, origin: 0)
        let noise = WhiteNoise(stage: stage)
        let band = BandPass(stage: stage)
        noise.play(0.5)
        configure(band)
        band.process(noise)
        var sum = [Float](repeating: 0, count: 512)
        for frame in 0...121 {
            stage.frame = frame
            stage.supply()
            guard frame > 1 else { continue }
            let spectrum = band.spectrum
            for index in 0..<512 { sum[index] += spectrum[index] * spectrum[index] }
        }
        stage.close()
        return sum
    }

    /// パワーが山の半分 (-3 dB) まで下がる左右の位置の間の幅 (Hz)。帯域の間は直線で補う。
    private func halfPowerWidth(_ power: [Float]) -> Float {
        let peak = power.indices.dropFirst().max { power[$0] < power[$1] } ?? 1
        let half = power[peak] / 2
        var left = Float(peak)
        var index = peak
        while index > 1, power[index - 1] >= half { index -= 1 }
        if index > 1 { left = Float(index) - (power[index] - half) / (power[index] - power[index - 1]) }
        var right = Float(peak)
        index = peak
        while index < 510, power[index + 1] >= half { index += 1 }
        if index < 510 { right = Float(index) + (power[index] - half) / (power[index] - power[index + 1]) }
        return (right - left) * Self.bandWidth
    }

    @Test("res(5) の後に freq(2000) と呼ぶと幅は 400 Hz、bw(200) の後なら 200 Hz のまま")
    func qFollowsTheCenter() {
        let byQuality = halfPowerWidth(powers { band in
            band.res(5)
            band.freq(2000)
        })
        let byWidth = halfPowerWidth(powers { band in
            band.bw(200)
            band.freq(2000)
        })
        // 解析のウィンドウで山が帯域 1 本ほど太るので、比で見る。Q 固定の幅は中心に追従して 2 倍になる
        #expect(abs(byQuality - 400) < 80, "Q 5・中心 2000 Hz の幅: \(byQuality)")
        #expect(abs(byWidth - 200) < 60, "幅 200 Hz・中心 2000 Hz の幅: \(byWidth)")
        #expect(byQuality / byWidth > 1.6, "\(byQuality) と \(byWidth)")
        // 中心が 1000 Hz なら Q 5 の幅は 200 Hz で、幅 200 Hz と同じ音になる
        let lowerCenter = powers { band in
            band.res(5)
            band.freq(1000)
        }
        let sameWidth = powers { band in
            band.freq(1000)
            band.bw(200)
        }
        #expect(halfPowerWidth(lowerCenter) < byQuality * 0.7)
        #expect(zip(lowerCenter, sameWidth).allSatisfy { abs($0 - $1) <= max($0, $1) * 1e-3 })
    }

    @Test("bw と res は、後に呼んだほうが効く (set・process の幅も bw と同じ)")
    func theLaterCallWins() {
        let resLast = powers { band in
            band.freq(2000)
            band.bw(200)
            band.res(5)
        }
        let resOnly = powers { band in
            band.freq(2000)
            band.res(5)
        }
        let bwLast = powers { band in
            band.freq(2000)
            band.res(5)
            band.bw(200)
        }
        let setLast = powers { band in
            band.res(5)
            band.set(2000, 200)
        }
        let bwOnly = powers { band in
            band.freq(2000)
            band.bw(200)
        }
        #expect(resLast == resOnly)
        #expect(bwLast == bwOnly)
        #expect(setLast == bwOnly)
        #expect(resLast != bwOnly)
    }

    @Test("res は 0.1〜10 に丸め、数でない値は無視する。どちらも 1 度だけ知らせる")
    func resIsClampedToTheReferenceRange() {
        let notices = NoticeLog()
        let tooSharp = powers(notices) { band in
            band.freq(2000)
            band.res(20)
        }
        #expect(notices.lines.count == 1, "\(notices.lines)")
        #expect(notices.lines.first?.contains("0.1 to 10") == true, "\(notices.lines)")
        #expect(tooSharp == powers { band in
            band.freq(2000)
            band.res(10)
        })
        // 0.1 を下回る値も 0.1 に丸める (100 には揃えない)
        #expect(powers { band in
            band.freq(2000)
            band.res(0.01)
        } == powers { band in
            band.freq(2000)
            band.res(0.1)
        })
        let ignoring = NoticeLog()
        let ignored = powers(ignoring) { band in
            band.freq(2000)
            band.res(5)
            band.res(.nan)
            band.res(.infinity)
        }
        #expect(ignoring.lines.count == 1, "\(ignoring.lines)")
        #expect(ignored == powers { band in
            band.freq(2000)
            band.res(5)
        })
    }
}
