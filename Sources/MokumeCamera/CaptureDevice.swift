// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation

/// 繋がっているカメラ 1 台。``Sketch/captureDevices()`` が返し、
/// ``Sketch/createCapture(_:_:device:mirrored:)`` で使う 1 台を選ぶ。出せる形式 (``formats``) も引ける。
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
    /// この機材が出せる形式 (幅・高さ・フレームレート) の並び。大きいものを先に、同じ大きさでは
    /// フレームレートの高いものを先に並べる。``Sketch/createCapture(_:_:device:mirrored:)`` へ渡す大きさを
    /// 当てずっぽうにせず、ここから選べる。機材が形式を名乗らなければ空。
    ///
    /// **等しさとハッシュには入らない** — 同じ機材は、形式の並びが読めたかどうかによらず同じとみなす
    /// (``id`` と ``name`` だけで決まる)。
    public let formats: [CaptureFormat]

    init(id: String, name: String, formats: [CaptureFormat] = []) {
        self.id = id
        self.name = name
        self.formats = formats
    }

    init(_ device: AVCaptureDevice) {
        self.init(
            id: device.uniqueID, name: device.localizedName,
            formats: CaptureFormat.listing(of: device.formats))
    }

    public static func == (left: CaptureDevice, right: CaptureDevice) -> Bool {
        left.id == right.id && left.name == right.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }

    /// 繋がっているカメラ。内蔵・外付け・iPhone (連係カメラ) を、OS が返す順に並べる。
    static func connected() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.map(CaptureDevice.init)
    }
}
