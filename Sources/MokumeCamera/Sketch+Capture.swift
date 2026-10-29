// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

// カメラ。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0042] 決定 1)。`plugins` には何も書かない —
// 作る口が、走っているスケッチへ自分で入り口を足す (``SketchPart/attach(_:)-(Inlet)``)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    /// カメラを開く。受け取った絵は ``Capture/image`` に入る。
    ///
    /// ```swift
    /// final class Mirror: Sketch {
    ///     var camera: Capture?
    ///     func setup() throws { camera = try createCapture(mirrored: true) }
    ///     func draw() {
    ///         if let camera { image(camera.image, 0, 0) }
    ///     }
    /// }
    /// ```
    ///
    /// - **`mirrored: true` で鏡に映したように左右が入れ替わる。** 左に置いた物が絵の右に映る。
    ///   p5.js の `createCapture(VIDEO, {flipped: true})` に当たる。**`flipped` とは名乗らない** — Apple の
    ///   API (`NSImage(size:flipped:)`・`NSView.isFlipped`) では `flipped` が上下の反転を指し、写すと別の向きを
    ///   思わせるため。AVFoundation も `isVideoMirrored` と呼ぶ。Processing の公式の Video は `scale(-1, 1)` を
    ///   自分で書く。既定は `false` (左右はカメラのまま)
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
    ///   - height: 受け取る絵の高さ (画素)。既定の 640×480 は、縦横比の違うカメラ (Mac の内蔵カメラは 16:9)
    ///     では真ん中を切り取る。切り取らずに受けるには、``CaptureDevice/formats`` から縦横比の合う大きさを選ぶ。
    ///   - device: 使うカメラ (``captureDevices()`` から選ぶ)。省けば既定の 1 台。
    ///   - mirrored: 鏡に映したように左右を入れ替えるか。省けば `false`。
    /// - Throws: 大きさが絵として置けないとき (``SketchPart/createImage(_:_:)`` と同じ ``ImageFailure``)。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、
    ///   機材を開く前に ``ImageFailure/notRunning(call:)`` (プロセスは落ちない)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    // shot: 撮れない カメラの映像が要る。鏡像は記録した絵を流す口 (createCapture(frames:mirrored:)) の検査で見る
    public func createCapture(
        _ width: Int = 640, _ height: Int = 480, device: CaptureDevice? = nil, mirrored: Bool = false
    ) throws(ImageFailure) -> Capture {
        let call = #function
        return try attachedOnSurface(ImageFailure.self, calledAs: call) { () throws(ImageFailure) -> Capture in
            Capture(
                image: try createImage(width, height, calledAs: call), device: device,
                name: device.map { "camera: \($0.name)" } ?? "camera",
                source: CameraSource(device: device, width: width, height: height), mirrored: mirrored,
                owner: self)
        }
    }

    /// 記録した絵の列を、カメラの代わりに流す。**機材も許可も使わない。**
    ///
    /// `frames[i]` が、作ってから i 番目のフレームで ``Capture/image`` に入り、最後まで行けば最初に戻る。
    /// どの絵が入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても同じ絵が
    /// 同じフレームに出る — カメラを使うスケッチを、機材の無い場所で確かめるときや、展示の
    /// 前に空回しするときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// **外して足し直しても、i 番目のフレームには `frames[i]` が入る** (外していた間の分は届かない。時刻どおり・[#3152](https://github.com/mokume-metal/mokume/issues/3152))。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var camera: Capture?
    ///     func setup() throws {
    ///         let red = DisplayImage(width: 4, height: 4, bytes: Array(repeating: [255, 0, 0, 255], count: 16).flatMap { $0 })
    ///         camera = try createCapture(frames: [red])
    ///     }
    ///     func draw() {
    ///         if let camera { image(camera.image, 0, 0, width, height) }
    ///     }
    /// }
    /// ```
    ///
    /// `mirrored: true` なら、流す絵の左右を入れ替える。機材を使う ``createCapture(_:_:device:mirrored:)`` と
    /// 同じ所で当てるので、機材の無い場所で鏡像を確かめられる。
    ///
    /// - Parameters:
    ///   - frames: 流す絵。大きさは最初の 1 枚に揃える。
    ///   - mirrored: 鏡に映したように左右を入れ替えるか。省けば `false`。
    /// - Throws: 列が空のとき (大きさが決まらない) か、大きさが絵として置けないとき (``ImageFailure``)。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと
    ///   ``ImageFailure/notRunning(call:)`` (プロセスは落ちない)。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createCapture(frames: [DisplayImage], mirrored: Bool = false) throws(ImageFailure) -> Capture {
        let call = #function
        return try attachedOnSurface(ImageFailure.self, calledAs: call) { () throws(ImageFailure) -> Capture in
            Capture(
                image: try createImage(
                    frames.first?.width ?? 0, frames.first?.height ?? 0, calledAs: call),
                device: nil, name: "camera (frames)", source: FramesSource(frames: frames, owner: self),
                mirrored: mirrored, owner: self)
        }
    }

    /// 繋がっているカメラの一覧。``createCapture(_:_:device:mirrored:)`` で 1 台を選ぶのに使う。各機材が出せる形式
    /// (幅・高さ・フレームレート) は ``CaptureDevice/formats`` で引ける。
    ///
    /// ```swift
    /// func setup() {
    ///     for device in captureDevices() { print(device.name, device.formats.first as Any) }
    /// }
    /// ```
    public func captureDevices() -> [CaptureDevice] {
        CaptureDevice.connected()
    }
}
