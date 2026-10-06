// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation

/// 繋がっているカメラ 1 台。``Sketch/captureDevices()`` が返し、
/// ``Sketch/createCapture(_:_:device:)`` で使う 1 台を選ぶ。
///
/// **位置や役割 (前・後ろ) では選ばない** ([ADR-0028] 決定 3)。ほとんどのカメラは位置を
/// 名乗らないので、そういう口は既定の 1 台へ落ちるだけになる。一覧から得た識別子で選ぶ。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public nonisolated struct CaptureDevice: Sendable, Equatable, Hashable {
    /// 識別子。抜いて挿し直しても同じ値になる。
    public let id: String
    /// 人が読む名前 (`"FaceTime HD Camera"` など)。
    public let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ device: AVCaptureDevice) {
        self.init(id: device.uniqueID, name: device.localizedName)
    }

    /// 繋がっているカメラ。内蔵・外付け・iPhone (連係カメラ) を、OS が返す順に並べる。
    static func connected() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.map(CaptureDevice.init)
    }
}
