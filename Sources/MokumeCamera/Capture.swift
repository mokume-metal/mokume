// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics

/// カメラの絵を受け取る入り口。``Sketch/createCapture(_:_:device:)`` が作り、走っている
/// スケッチへ足す。
///
/// 受け取った絵は ``image`` に入り、普通の ``Image`` として描ける (貼る・効果を通す・
/// 立体に貼る — [ADR-0028] 決定 5)。毎フレーム呼ぶ口は無い。`draw()` の前に、届いた
/// 新しい 1 枚が ``image`` へ書かれている。
///
/// ```swift
/// final class Mirror: Sketch {
///     var camera: Capture?
///     func setup() { camera = try? createCapture(640, 480) }
///     func draw() {
///         guard let camera else { return }
///         image(camera.image, 0, 0)
///         if camera.state != .running { text("\(camera.state)", 20, 40) }
///     }
/// }
/// ```
///
/// ## 来ないことには理由がある
///
/// 絵が来ないとき、``state`` がその理由を名乗る — 許可を待っている・拒まれた・カメラが
/// 無い・抜かれた。観測の応答の `inputs` にも同じものが載る ([ADR-0028] 決定 4)。
/// 許可を待ったまま 3 秒経っても 1 枚も来ないときと、許可を拒まれたときは、どのアプリの
/// 許可を見ればよいかを 1 度だけ知らせる。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class Capture: Inlet {
    /// 受け取った絵。大きさは作ったときに決まり、変わらない。
    public let image: Image
    /// 選んだカメラ。既定の 1 台を使っているなら `nil`。
    public let device: CaptureDevice?
    /// このフレームで新しい 1 枚が ``image`` に書かれたか。
    public private(set) var isNewFrame = false

    let input: ExternalInput<DisplayImage>
    private let source: any CaptureSource
    private weak var owner: (any Sketch)?
    private let now: () -> TimeInterval
    private let warn: (String) -> Void
    private var openedAt: TimeInterval?
    private var warnedWaiting = false
    private var warnedDenied = false

    /// 許可を待ったまま、何秒何も来なければ知らせるか。
    static let patience: TimeInterval = 3

    init(
        image: Image, device: CaptureDevice?, name: String, source: any CaptureSource,
        owner: (any Sketch)?,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.image = image
        self.device = device
        self.source = source
        self.owner = owner
        self.now = now
        self.warn = warn
        input = ExternalInput(name: name, state: .waitingForPermission)
    }

    /// 出どころの状態。
    public var state: SourceState { input.state }
    /// 最後に絵が届いたフレーム。まだ 1 枚も届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }
    /// 幅 (画素)。``image`` の幅と同じ。
    public var width: Int { image.width }
    /// 高さ (画素)。``image`` の高さと同じ。
    public var height: Int { image.height }

    /// 止める。カメラを閉じ、以後 ``image`` は変わらない。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``Sketch/detach(_:)-(Inlet)`` と同じ)。
    public func stop() {
        owner?.detach(self)
    }

    // MARK: - Inlet

    public func open() throws {
        openedAt = now()
        source.start(into: input)
    }

    public func supply() {
        source.pump(into: input)
        if let picture = input.take() {
            image.write(picture)
            isNewFrame = true
        } else {
            isNewFrame = false
        }
        noticeIfStuck()
    }

    public func close() {
        source.stop()
        input.setState(.stopped)
    }

    public var report: SourceReport? { input.report }

    // MARK: - 知らせ

    /// 許可で止まっているなら、どこを見ればよいかを 1 度だけ言う。
    private func noticeIfStuck() {
        switch state {
        case .waitingForPermission:
            guard !warnedWaiting, lastArrival == nil, let openedAt,
                now() - openedAt >= Self.patience
            else { return }
            warnedWaiting = true
            warn(
                "The camera has been waiting for permission for \(Int(Self.patience)) seconds and "
                    + "no frame has arrived. macOS asks on behalf of \(Self.responsibleApp()): "
                    + "answer the dialog, or allow it in System Settings > Privacy & Security > Camera")
        case .denied:
            guard !warnedDenied else { return }
            warnedDenied = true
            warn(
                "Camera access is denied for \(Self.responsibleApp()), so no frame will arrive. "
                    + "Allow it in System Settings > Privacy & Security > Camera, then start the "
                    + "sketch again")
        default:
            break
        }
    }

    /// 許可を問われるアプリ。束ねた `.app` ならそれ自身、端末から動かしたなら端末のアプリ
    /// (許可は「責任を負うプロセス」に付く — #1957 の実測)。
    static func responsibleApp(
        bundle: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let bundle { return bundle }
        if let launcher = environment["__CFBundleIdentifier"] { return launcher }
        if let terminal = environment["TERM_PROGRAM"] { return terminal }
        return "the app that started this sketch"
    }
}
