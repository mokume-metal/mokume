// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreMedia
import MokumeCore
import MokumeDiagnostics
import Synchronization

/// 実機のカメラ。AVFoundation に触れるのはこの型だけである。
///
/// ## 待ち行列は 2 本、どちらも受ける点でしかない
///
/// カメラの受け取り (`AVCaptureVideoDataOutput`) は待ち行列を引数に取るので、
/// [ADR-0010] 決定 4 の改訂 ([ADR-0042] 決定 7) の条件の内側で持つ。
///
/// - **操作の列** (``control``): 開始・停止・許可の答え・抜き差しの知らせを順に進める。
///   開始と停止を直列に並べないと、止めた後に始まる・始める前に止める、が起きる。
///   状態 (``lifecycle`` ほか) はこの上に閉じていて、錠は要らない
/// - **絵の列** (``frames``): 届いた 1 枚を変換する。操作の列と分けるのは、止める手
///   (`stopRunning()`) が操作の列の上で待つ間に、届いた 1 枚が同じ列に詰まらないため
/// - 境界を越えるのは ``DisplayImage`` (`Sendable`) と状態だけで、`CMSampleBuffer` は
///   越えさせない
/// - 受けたものは ``ExternalInput`` へ入れるところで手を離す。フレームへ渡すのは
///   ``Capture/supply()`` である
///
/// ## 状態の判断は ``CameraLifecycle`` が持つ
///
/// ここは返された手 (許可を求める・始める・止める) を打つだけにする。判断を実機から
/// 離しておけば、許可や抜き差しの組み合わせを機材なしで検査できる。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated final class CameraSource: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    // `@unchecked Sendable`: 可変の状態は操作の列の上でだけ、変換器と警告の旗は絵の列の
    // 上でだけ触る (上の説明)。

    private let requested: CaptureDevice?
    private let converter: FrameConverter
    private let control = DispatchQueue(label: "org.mokume.camera.control")
    private let frames = DispatchQueue(label: "org.mokume.camera.frames")

    /// 入れ物。操作の列が置き、絵の列が読む。1 度置くだけなので、錠は読み書きの境目のため
    private let input = Mutex<ExternalInput<DisplayImage>?>(nil)
    private var lifecycle = CameraLifecycle()
    private var session: AVCaptureSession?
    /// いま使っている機材の識別子。抜かれたのがこれかを見分ける。
    private var currentID: String?
    private var observers: [any NSObjectProtocol] = []
    private var warnedConversion = false

    init(device: CaptureDevice?, width: Int, height: Int) {
        requested = device
        converter = FrameConverter(width: width, height: height)
    }

    // MARK: - CaptureSource (main actor から)

    func start(into input: ExternalInput<DisplayImage>) {
        self.input.withLock { $0 = input }
        observeConnections()
        control.async { [self] in
            let device = resolveDevice()
            apply(
                lifecycle.open(
                    authorization: Self.authorization(), deviceAvailable: device != nil),
                device: device)
        }
    }

    func pump(into input: ExternalInput<DisplayImage>) {}

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        // **止め終わるまで待つ。** 閉じた後に 1 枚届くと、閉じた入り口の入れ物へ入る
        control.sync { [self] in apply(lifecycle.stop(), device: nil) }
    }

    // MARK: - 待ち行列の上

    private static func authorization() -> CameraLifecycle.Authorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        default: .denied
        }
    }

    /// 使う 1 台。選ばれていればその識別子の機材、選ばれていなければ既定の 1 台。
    private func resolveDevice() -> AVCaptureDevice? {
        if let requested {
            guard let device = AVCaptureDevice(uniqueID: requested.id), device.isConnected else {
                return nil
            }
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// 移り変わりが返した手を打ち、状態を入れ物へ写す。
    private func apply(_ action: CameraLifecycle.Action, device: AVCaptureDevice?) {
        switch action {
        case .none:
            break
        case .requestAccess:
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                control.async { [self] in
                    let device = resolveDevice()
                    apply(
                        lifecycle.accessAnswered(granted: granted, deviceAvailable: device != nil),
                        device: device)
                }
            }
        case .startSession:
            if let device { startSession(with: device) }
        case .stopSession:
            session?.stopRunning()
            session = nil
            currentID = nil
        }
        let state = lifecycle.state
        input.withLock { $0?.setState(state) }
    }

    private func startSession(with device: AVCaptureDevice) {
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard let deviceInput = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(deviceInput)
        else {
            session.commitConfiguration()
            Diagnostics.warn("Could not open the camera \(device.localizedName)")
            return
        }
        session.addInput(deviceInput)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = Self.videoSettings(width: converter.width, height: converter.height)
        // 追いつかない 1 枚は捨てる。溜めると機材のメモリが枯れて、新しい絵が来なくなる
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            Diagnostics.warn("Could not receive frames from the camera \(device.localizedName)")
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        self.session = session
        currentID = device.uniqueID
    }

    /// 受け取る 1 枚の形。
    ///
    /// - **画素の形式は 32BGRA を頼む。** 機材が既定で出す 420v のまま受けて vImage で
    ///   直に変換すると、色差が中立の灰色が緑になった (#1977 の実機の確認で踏んだ)。
    ///   YpCbCr から RGB への変換は AVFoundation に任せ、``FrameConverter`` は BGRA だけを受ける
    /// - 大きさは OS に縮めさせる (できなければ ``FrameConverter`` が切り取って縮める)
    static func videoSettings(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    }

    // MARK: - 抜き差し

    private func observeConnections() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
            ) { [weak self] note in
                let id = (note.object as? AVCaptureDevice)?.uniqueID
                self?.control.async { [weak self] in self?.disconnected(id) }
            })
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.control.async { [weak self] in self?.connected() }
            })
    }

    private func disconnected(_ id: String?) {
        guard let id, id == currentID else { return }
        apply(lifecycle.deviceDisconnected(), device: nil)
    }

    private func connected() {
        let device = resolveDevice()
        apply(lifecycle.deviceConnected(deviceAvailable: device != nil), device: device)
    }

    // MARK: - 届いた 1 枚

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let picture: DisplayImage
        do {
            picture = try converter.convert(pixels)
        } catch {
            // 毎フレーム走る経路なので投げない。1 度だけ言う (ADR-0020 決定 5)
            if !warnedConversion {
                warnedConversion = true
                Diagnostics.warn("Could not convert a camera frame: \(error)")
            }
            return
        }
        // 届いた時刻は機材の時計 (host time) のまま持つ (ADR-0042 決定 4)
        let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = stamp.isValid ? CMClockConvertHostTimeToSystemUnits(stamp) : mach_absolute_time()
        input.withLock { $0 }?.send(picture, hostTime: hostTime)
    }
}
