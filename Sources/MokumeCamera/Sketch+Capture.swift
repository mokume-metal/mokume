// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

// カメラ。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0042] 決定 1)。`plugins` には何も書かない —
// 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    /// カメラを開く。受け取った絵は ``Capture/image`` に入る。
    ///
    /// ```swift
    /// final class Mirror: Sketch {
    ///     var camera: Capture?
    ///     func setup() { camera = try? createCapture() }
    ///     func draw() {
    ///         if let camera { image(camera.image, 0, 0) }
    ///     }
    /// }
    /// ```
    ///
    /// - **呼んだときだけ機材を開く。** `import mokume` しただけでカメラが点いたり、許可の
    ///   ダイアログが出たりはしない
    /// - 絵は頼んだ大きさで届く。カメラの縦横比が違えば、真ん中を切り取って合わせる (ゆがめない)
    /// - 色はカメラが名乗る色空間から作業空間へ移してある ([ADR-0011])
    /// - **カメラが無くても作れる。** ``Capture/state`` が ``SourceState/unavailable`` になり、
    ///   挿されたら始まる。抜かれたら ``SourceState/disconnected`` になり、挿し直せば戻る
    /// - 初めて使うときは OS が許可を求める。束ねずに動かしている間は、許可はスケッチを
    ///   起動した端末のアプリに付く
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameters:
    ///   - width: 受け取る絵の幅 (画素)。
    ///   - height: 受け取る絵の高さ (画素)。
    ///   - device: 使うカメラ (``captureDevices()`` から選ぶ)。省けば既定の 1 台。
    /// - Throws: 大きさが絵として置けないとき (``createImage(_:_:)`` と同じ)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public func createCapture(
        _ width: Int = 640, _ height: Int = 480, device: CaptureDevice? = nil
    ) throws(ImageFailure) -> Capture {
        let capture = Capture(
            image: try createImage(width, height), device: device,
            name: device.map { "camera: \($0.name)" } ?? "camera",
            source: CameraSource(device: device, width: width, height: height), owner: self)
        attach(capture)
        return capture
    }

    /// 記録した絵の列を、カメラの代わりに流す。**機材も許可も使わない。**
    ///
    /// フレームごとに次の 1 枚が ``Capture/image`` に入り、最後まで行けば最初に戻る。
    /// どの絵が入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても同じ絵が
    /// 同じフレームに出る — カメラを使うスケッチを、機材の無い場所で確かめるときや、展示の
    /// 前に空回しするときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var camera: Capture?
    ///     func setup() {
    ///         let red = DisplayImage(width: 4, height: 4, bytes: Array(repeating: [255, 0, 0, 255], count: 16).flatMap { $0 })
    ///         camera = try? createCapture(frames: [red])
    ///     }
    ///     func draw() {
    ///         if let camera { image(camera.image, 0, 0, width, height) }
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter frames: 流す絵。大きさは最初の 1 枚に揃える。
    /// - Throws: 列が空のとき (大きさが決まらない) か、大きさが絵として置けないとき。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createCapture(frames: [DisplayImage]) throws(ImageFailure) -> Capture {
        let capture = Capture(
            image: try createImage(frames.first?.width ?? 0, frames.first?.height ?? 0),
            device: nil, name: "camera (frames)", source: FramesSource(frames: frames),
            owner: self)
        attach(capture)
        return capture
    }

    /// 繋がっているカメラの一覧。``createCapture(_:_:device:)`` で 1 台を選ぶのに使う。
    ///
    /// ```swift
    /// func setup() {
    ///     for device in captureDevices() { print(device.name) }
    /// }
    /// ```
    public func captureDevices() -> [CaptureDevice] {
        CaptureDevice.connected()
    }
}
