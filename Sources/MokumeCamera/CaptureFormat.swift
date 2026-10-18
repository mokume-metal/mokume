// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreMedia

/// カメラが出せる形式の 1 つ (幅・高さ・フレームレートの範囲)。``CaptureDevice/formats`` に並ぶ。
///
/// 機材は、同じ大きさをフレームレートの違う形式で何通りも名乗る。1 つのフレームレートの範囲ごとに
/// 1 つの値にしてある (同じ組は 1 つにまとめる)。
///
/// ```swift
/// func setup() {
///     for device in captureDevices() {
///         for format in device.formats {
///             print(device.name, format.width, format.height, format.frameRates)
///         }
///     }
/// }
/// ```
public nonisolated struct CaptureFormat: Sendable, Equatable, Hashable {
    /// 幅 (画素)。
    public let width: Int
    /// 高さ (画素)。
    public let height: Int
    /// この大きさで出せるフレームレート (フレーム / 秒) の範囲。1 つのレートだけを出す形式は、
    /// 下端と上端が同じ範囲になる。
    public let frameRates: ClosedRange<Double>

    init(width: Int, height: Int, frameRates: ClosedRange<Double>) {
        self.width = width
        self.height = height
        self.frameRates = frameRates
    }

    /// 機材の形式の並びを、大きいものから (同じ大きさではフレームレートの高いものから) 並べた一覧にする。
    static func listing(of formats: [AVCaptureDevice.Format]) -> [CaptureFormat] {
        var seen = Set<CaptureFormat>()
        var listed: [CaptureFormat] = []
        for format in formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            for range in format.videoSupportedFrameRateRanges
            where range.minFrameRate <= range.maxFrameRate {
                let entry = CaptureFormat(
                    width: Int(dimensions.width), height: Int(dimensions.height),
                    frameRates: range.minFrameRate...range.maxFrameRate)
                if seen.insert(entry).inserted { listed.append(entry) }
            }
        }
        return listed.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.frameRates.upperBound > $1.frameRates.upperBound
        }
    }
}
