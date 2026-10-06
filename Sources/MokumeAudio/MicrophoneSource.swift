// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import CoreAudio
import Foundation
import MokumeCore
import MokumeDiagnostics
import Synchronization

/// 実機のマイク。AVFAudio と Core Audio で音を受けるのはこの型だけである
/// ([ADR-0042] 決定 6 の「薄い層に閉じる」)。
///
/// ## 受け取りは `AVAudioSinkNode`、realtime では環へ書くだけ
///
/// 入力の機材の音は `AVAudioEngine` の入力から `AVAudioSinkNode` へ流す。受け取りの手続きは
/// 音の realtime スレッドで走るので、**チャンネルを平均してモノラルにし、事前に確保した環
/// (``SampleRing``) へ書くだけにする** ([ADR-0042] 決定 7)。解析はフレームの側
/// (``AudioIn/supply()``) で行う。`installTap` は使わない (macOS 27 の SDK で非推奨)。
///
/// ## 待ち行列は 1 本、受ける点でしかない
///
/// - **操作の列** (``control``): 開始・停止・許可の答え・抜き差しと構成の変化の知らせを順に
///   進める。状態 (``lifecycle`` ほか) はこの上に閉じていて、錠は要らない
/// - Core Audio の機材の一覧の変化を受ける口は待ち行列を引数に取るので、[ADR-0010] 決定 4 の
///   改訂 ([ADR-0042] 決定 7) の条件の内側で持つ
/// - 境界を越えるのは標本の窓 (`[Float]`) と状態だけで、AVFAudio と Core Audio の型は越えさせない
///
/// ## 状態の判断は ``MicrophoneLifecycle`` が持つ
///
/// ここは返された手 (許可を求める・始める・止める) を打つだけにする。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated final class MicrophoneSource: AudioSource, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は操作の列の上でだけ触る。``lastTotal`` だけはフレームの
    // 側 (``pump(into:at:)``) でだけ触る。

    private let requested: AudioDevice?
    private let control = DispatchQueue(label: "org.mokume.audio.control")
    private let ring = SampleRing(capacity: AudioAnalysis.windowSize * 32)

    /// 入れ物。操作の列が置き、許可の答えの手続きが読む。
    private let input = Mutex<ExternalInput<[Float]>?>(nil)
    private let rate = Mutex<Float>(0)
    private var lifecycle = MicrophoneLifecycle()
    private var engine: AVAudioEngine?
    /// いま使っている機材の番号。抜かれたのがこれかを見分ける。
    private var current: AudioObjectID?
    /// 前に見た機材の番号。増えた・減ったを見分ける。
    private var known: Set<AudioObjectID> = []
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var configurationObserver: (any NSObjectProtocol)?
    /// 前に窓を入れたときの、環に書かれた総数。
    private var lastTotal = 0

    init(device: AudioDevice?) {
        requested = device
    }

    var sampleRate: Float { rate.withLock { $0 } }

    // MARK: - AudioSource (main actor から)

    func start(into input: ExternalInput<[Float]>, at time: Double) {
        self.input.withLock { $0 = input }
        control.async { [self] in
            known = Set(CoreAudioDevices.allObjects())
            observeChanges()
            let device = resolveDevice()
            apply(
                lifecycle.open(
                    authorization: Self.authorization(), deviceAvailable: device != nil),
                device: device)
        }
    }

    /// 新しい標本が届いていれば、最新の窓を入れる。届いた時刻は環の最後の標本の host time。
    func pump(into input: ExternalInput<[Float]>, at time: Double) {
        let total = ring.total
        guard total != lastTotal else { return }
        lastTotal = total
        input.send(ring.latest(AudioAnalysis.windowSize), hostTime: ring.lastHostTime)
    }

    func stop() {
        // **止め終わるまで待つ。** 閉じた後に標本が届いても、もう読まれない
        control.sync { [self] in
            removeObservers()
            apply(lifecycle.stop(), device: nil)
        }
    }

    // MARK: - 操作の列の上

    private static func authorization() -> MicrophoneLifecycle.Authorization {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .notDetermined
        case .granted: .authorized
        default: .denied
        }
    }

    /// 使う 1 つ。選ばれていればその識別子の機材、選ばれていなければ既定の入力。
    private func resolveDevice() -> AudioObjectID? {
        if let requested {
            return CoreAudioDevices.inputs().first { $0.device.id == requested.id }?.object
        }
        return CoreAudioDevices.defaultInput()
    }

    /// 移り変わりが返した手を打ち、状態を入れ物へ写す。
    private func apply(_ action: MicrophoneLifecycle.Action, device: AudioObjectID?) {
        switch action {
        case .none:
            break
        case .requestAccess:
            AVAudioApplication.requestRecordPermission { [self] granted in
                control.async { [self] in
                    let device = resolveDevice()
                    apply(
                        lifecycle.accessAnswered(granted: granted, deviceAvailable: device != nil),
                        device: device)
                }
            }
        case .startEngine:
            if let device { startEngine(with: device) }
        case .stopEngine:
            stopEngine()
        }
        let state = lifecycle.state
        input.withLock { $0?.setState(state) }
    }

    private func startEngine(with device: AudioObjectID) {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        do {
            try node.auAudioUnit.setDeviceID(device)
        } catch {
            Diagnostics.warn("Could not open the audio input device: \(error)")
            return
        }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
            format.commonFormat == .pcmFormatFloat32
        else {
            Diagnostics.warn("The audio input device offers no usable format (\(format))")
            return
        }
        let ring = self.ring
        let sink = AVAudioSinkNode { timestamp, frames, buffers in
            Self.mix(buffers, frames: Int(frames), timestamp: timestamp, into: ring)
            return noErr
        }
        engine.attach(sink)
        engine.connect(node, to: sink, format: format)
        do {
            try engine.start()
        } catch {
            Diagnostics.warn("Could not start the audio input: \(error)")
            return
        }
        rate.withLock { $0 = Float(format.sampleRate) }
        self.engine = engine
        current = device
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        current = nil
    }

    // MARK: - realtime スレッド

    /// 届いた標本を、チャンネルを平均してモノラルにし、環へ書く。**錠も確保も無い。**
    ///
    /// 交互 (1 つの置き場に全チャンネル) と分離 (チャンネルごとの置き場) のどちらでも、
    /// 置き場ごとのチャンネル数 (`mNumberChannels`) に従って読む。
    static func mix(
        _ list: UnsafePointer<AudioBufferList>, frames: Int,
        timestamp: UnsafePointer<AudioTimeStamp>, into ring: SampleRing
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var channels = 0
        for buffer in buffers { channels += Int(buffer.mNumberChannels) }
        guard channels > 0, frames > 0 else { return }
        let scale = 1 / Float(channels)
        let stamp = timestamp.pointee
        let hostTime =
            stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
        ring.write(count: frames, hostTime: hostTime) { frame in
            var sum: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = Int(buffer.mNumberChannels)
                for channel in 0..<stride { sum += data[frame * stride + channel] }
            }
            return sum * scale
        }
    }

    // MARK: - 抜き差しと構成の変化

    private func observeChanges() {
        var address = CoreAudioDevices.globalAddress(kAudioHardwarePropertyDevices)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.devicesChanged()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener) == noErr
        {
            devicesListener = listener
        }
        // 機材の形式が変わる (標本化率を変えた等) と、エンジンは止まる。同じ機材で始め直す
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            let changed = (note.object as AnyObject?).map(ObjectIdentifier.init)
            self?.control.async { [weak self] in self?.configurationChanged(changed) }
        }
    }

    private func removeObservers() {
        if let devicesListener {
            var address = CoreAudioDevices.globalAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, control, devicesListener)
            self.devicesListener = nil
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// 機材の一覧が変わった。使っている機材が消えたら抜かれた、増えたら挿された、と読む。
    private func devicesChanged() {
        let now = Set(CoreAudioDevices.allObjects())
        let removed = known.subtracting(now)
        let added = now.subtracting(known)
        known = now
        if let current, removed.contains(current) {
            apply(lifecycle.deviceDisconnected(), device: nil)
        }
        if !added.isEmpty {
            let device = resolveDevice()
            apply(lifecycle.deviceConnected(deviceAvailable: device != nil), device: device)
        }
    }

    /// 構成が変わってエンジンが止まった。**同じ機材がまだ在るときだけ**始め直す — 抜かれたなら、
    /// それは一覧の変化 (``devicesChanged()``) が抜かれたと名乗る。
    private func configurationChanged(_ changed: ObjectIdentifier?) {
        guard let engine, changed == ObjectIdentifier(engine), let device = current,
            CoreAudioDevices.allObjects().contains(device), lifecycle.state == .running
        else { return }
        stopEngine()
        startEngine(with: device)
    }
}
