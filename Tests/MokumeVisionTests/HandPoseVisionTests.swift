// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Synchronization
import Testing
import mokume

@testable import MokumeCore
@testable import MokumeVision

// MARK: - 偽の推論

/// 用意と推論の門。開くまで待たせる。
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var passed = 0

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func pass() async {
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        passed += 1
    }
}

/// 用意を門で止める偽の推論。推論は決まった手を返す (`hands` が空なら手が写らない絵)。
private nonisolated struct PreparingEstimator: HandPoseEstimator {
    let gate: Gate
    var hands: [RawHand] = []

    func prepare() async { await gate.pass() }
    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        await prepare()
        return hands
    }
}

/// 推論を門で止める偽の推論 (用意はすぐ済む)。
private nonisolated struct StuckEstimator: HandPoseEstimator {
    let gate: Gate
    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        await gate.pass()
        return []
    }
}

/// 絵の中で**いちばん赤い画素**を探し、21 の関節をすべてその画素の中心に置く偽の推論。
///
/// 画素は実物の推論と同じ写し (``VisionHandPoseEstimator/picture(of:)``) で読む。`delay` だけ遅れて返す
/// (遅い推論)。
private nonisolated struct MarkerEstimator: HandPoseEstimator {
    var delay: Duration = .zero

    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard let picture = VisionHandPoseEstimator.picture(of: frame),
            let marker = Self.reddest(in: picture)
        else { return [] }
        let x = (Float(marker.x) + 0.5) / Float(frame.width)
        let y = 1 - (Float(marker.y) + 0.5) / Float(frame.height)
        return [RawHand(handedness: .right, joints: Array(repeating: RawJoint(x: x, y: y, confidence: 1), count: 21))]
    }

    static func reddest(in picture: CGImage) -> (x: Int, y: Int)? {
        guard let bytes = picture.dataProvider?.data as Data? else { return nil }
        var best: (x: Int, y: Int, red: UInt8)?
        for y in 0..<picture.height {
            for x in 0..<picture.width {
                let red = bytes[y * picture.bytesPerRow + x * 4]
                if red > (best?.red ?? 0) { best = (x, y, red) }
            }
        }
        return best.map { ($0.x, $0.y) }
    }
}

/// 黒地に赤い画素を 1 つ置いた絵。
private func markerPicture(width: Int, height: Int, x: Int, y: Int) -> DisplayImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for at in stride(from: 3, to: bytes.count, by: 4) { bytes[at] = 255 }
    bytes[(y * width + x) * 4] = 255
    return DisplayImage(width: width, height: height, bytes: bytes)
}

/// 条件が成り立つまで待つ。**待つ側が期限を持つ** (5 秒)。
private func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// 名乗った行を集める。
private nonisolated final class Told: Sendable {
    let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func append(_ line: String) { lines.withLock { $0.append(line) } }
}

// MARK: - 用意の間の状態 (#3587 の条件 3)

@MainActor
struct HandPosePreparationTests {
    private func pose(
        _ estimator: any HandPoseEstimator, waits: Bool = false, pictures: @escaping () -> HandPoseInput? = { nil }
    ) throws -> HandPose {
        let source = InferenceSource(estimator: estimator, waits: { waits }, frame: pictures)
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        return pose
    }

    @Test("開くと preparing を名乗り、用意の間もフレームは回る。用意が済めば、手が写っていなくても running で、結果は空")
    func preparingThenRunningWithoutHands() async throws {
        let gate = Gate()
        var queue = [HandPoseInput(width: 64, height: 48, hostTime: 9)]
        let pose = try pose(PreparingEstimator(gate: gate)) { queue.isEmpty ? nil : queue.removeFirst() }
        #expect(pose.state == .preparing)
        for _ in 0..<3 { pose.supply() }  // 用意を待たずに返る (返らなければこの検査は進まない)
        #expect(pose.state == .preparing, "用意の間は preparing のまま")
        #expect(pose.hands.isEmpty && pose.hostTime == nil, "用意の間は結果が届かない")
        #expect(pose.report?.state == .preparing, "観測の応答にも載る")

        await gate.open()
        #expect(await eventually { pose.state == .running }, "用意が済めば running")
        #expect(await eventually {
            pose.supply()
            return pose.hostTime == 9
        })
        #expect(pose.hands.isEmpty, "手が写らない絵は空の結果")
        #expect(pose.state == .running, "最初の手が写る前でも running")
    }

    @Test("用意の間に外すと stopped で、その後に用意が済んでも stopped のまま。足し直せば running")
    func aPreparationThatEndsAfterAStopDoesNotOverwriteStopped() async throws {
        let gate = Gate()
        let pose = try pose(PreparingEstimator(gate: gate))
        #expect(pose.state == .preparing)
        pose.close()
        #expect(pose.state == .stopped)
        await gate.open()
        #expect(await eventually { await gate.passed == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(pose.state == .stopped, "止めた後に済んだ用意は状態を変えない")
        try pose.open()
        #expect(pose.state == .running, "用意は済んでいるので、足し直すとすぐ running")
        #expect(await gate.passed == 1, "用意は 1 度きり")
    }

    @Test("固定の時計では、開くときに用意を待つ: 開いた直後から running")
    func theFixedClockWaitsForThePreparationOnOpen() async throws {
        let gate = Gate()
        // 門は別の Task で少し後に開く。開くまで open() が返らない
        Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            await gate.open()
        }
        let pose = try pose(PreparingEstimator(gate: gate), waits: true)
        #expect(pose.state == .running)
    }
}

// MARK: - 固定の時計では推論を待つ (#3587 の条件 4)

@MainActor
struct HandPoseWaitTests {
    @Test("固定の時計では、絵を渡したその supply の中で結果が入る (遅い推論でも)")
    func theFixedClockWaitsForTheResult() throws {
        var queue = [HandPoseInput(width: 4, height: 4, hostTime: 21)]
        let source = InferenceSource(
            estimator: SlowEmptyEstimator(), waits: { true }, frame: { queue.isEmpty ? nil : queue.removeFirst() })
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        pose.supply()
        #expect(pose.hostTime == 21, "同じ supply の中で結果が入る")
        #expect(pose.state == .running)
    }

    @Test("推論が期限を越えたら、結果なしで進め、1 度だけ名乗り、以後は待たない")
    func aStuckInferenceGivesUpAfterThePatience() async throws {
        let gate = Gate()
        let told = Told()
        var queue = [HandPoseInput(width: 4, height: 4, hostTime: 1), HandPoseInput(width: 4, height: 4, hostTime: 2)]
        let source = InferenceSource(
            estimator: StuckEstimator(gate: gate), waits: { true }, patience: .milliseconds(100),
            tell: { told.append($0) }, frame: { queue.isEmpty ? nil : queue.removeFirst() })
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        pose.supply()  // 期限まで待って返る
        #expect(pose.hostTime == nil, "期限を越えたフレームには結果が無い")
        #expect(source.gaveUpWaiting)
        pose.supply()  // もう待たない (待てば、門が開かないので期限まで止まる)
        #expect(told.all.count == 1, "\(told.all)")
        #expect(told.all.first?.contains("took longer than") == true)
        await gate.open()
        #expect(await eventually {
            pose.supply()
            return pose.hostTime == 2
        }, "以後は待たずに worker が推論する")
    }
}

/// 少し遅れて空を返す偽の推論。
private nonisolated struct SlowEmptyEstimator: HandPoseEstimator {
    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        try? await Task.sleep(for: .milliseconds(30))
        return []
    }
}

// MARK: - Vision へ渡す絵 (#3587 の条件 5)

@MainActor
struct HandPosePictureTests {
    @Test("Vision へ渡す絵は、乗算済みを外し sRGB の転送関数を掛けた 8 bit。画素の並びは変えない")
    func thePictureIsStraightAndEncoded() throws {
        // 2×1: 左は不透明度 0.5 で乗算済みの赤 (乗算前は赤 1)、右は不透明な線形 0.5 の灰
        let pixels = PixelBuffer(width: 2, height: 1, components: [0.5, 0, 0, 0.5, 0.5, 0.5, 0.5, 1])
        let frame = HandPoseInput(pixels: pixels, hostTime: 1)
        let picture = try #require(VisionHandPoseEstimator.picture(of: frame))
        #expect(picture.width == 2 && picture.height == 1)
        #expect(picture.alphaInfo == .last, "アルファは乗算していない形で名乗る")
        #expect(picture.colorSpace?.name == CGColorSpace.displayP3)
        let bytes = try #require(picture.dataProvider?.data as Data?)
        #expect(Array(bytes.prefix(4)) == [255, 0, 0, 128], "乗算を外せば赤は 1 (255)")
        #expect(Array(bytes[4..<8]) == [188, 188, 188, 255], "線形 0.5 は sRGB の転送関数で 188")
    }

    @Test("画素を持たない写し・大きさが 0 の写しは、絵にしない (推論は空を返す)")
    func noPixelsNoPicture() async {
        #expect(VisionHandPoseEstimator.picture(of: HandPoseInput(width: 4, height: 4, hostTime: 1)) == nil)
        let hands = await VisionHandPoseEstimator().estimate(HandPoseInput(width: 4, height: 4, hostTime: 1))
        #expect(hands.isEmpty)
    }
}

// MARK: - 走っているスケッチの中 (GPU を要する)

/// 絵を流すカメラの入り口と、絵を受けて手を探す入り口 (#3587 の条件 4・5)。GPU を要する。
@Suite(
    "絵から手を探す入り口 (走っているスケッチ)",
    .serialized,
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct HandPoseFromPictureSketchTests {
    final class Host: Sketch {
        nonisolated(unsafe) static var onSetup: (Host) throws -> Void = { _ in }
        nonisolated(unsafe) static var onDraw: (Host) -> Void = { _ in }
        init() {}
        var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
        func setup() throws { try Self.onSetup(self) }
        func draw() {
            background(0, 0, 0)
            Self.onDraw(self)
        }
    }

    private func run(frames: Int) throws {
        let runtime = try SketchRuntime(sketch: Host(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
    }

    /// 赤い画素の x を 1・5・9 と変えながら流し、フレームごとに手の位置と時刻を記録する。
    private func record(mirrored: Bool, delay: Duration) throws -> [(x: Float?, matches: Bool, clock: Clock)] {
        let xs = [1, 5, 9]
        var camera: Capture?
        var pose: HandPose?
        var seen: [(x: Float?, matches: Bool, clock: Clock)] = []
        Host.onSetup = { sketch in
            let frames = xs.map { markerPicture(width: 16, height: 8, x: $0, y: 2) }
            let capture = try sketch.createCapture(frames: frames, mirrored: mirrored)
            camera = capture
            pose = sketch.createHandPose(
                capture.image, arrival: { capture.lastArrival }, estimator: MarkerEstimator(delay: delay))
        }
        Host.onDraw = { sketch in
            let x = pose?.hands.first?[.indexTip].position.x
            let matches = pose?.hostTime != nil && pose?.hostTime == camera?.lastArrival?.hostTime
            seen.append((x, matches, sketch.clock))
        }
        try run(frames: 6)
        return seen
    }

    @Test("固定の時計で絵の列を流すと、フレーム N の絵に対する結果がフレーム N の draw() に出る (遅い推論でも)")
    func eachFramesResultArrivesOnThatFrame() throws {
        let seen = try record(mirrored: false, delay: .milliseconds(20))
        #expect(seen.allSatisfy { $0.clock != .wallClock }, "ウィンドウを開かずに回す実行は固定の時計")
        #expect(seen.map(\.x) == [1.5, 5.5, 9.5, 1.5, 5.5, 9.5], "\(seen.map(\.x))")
        #expect(seen.allSatisfy { $0.matches }, "結果の host time は、そのフレームに届いた絵の host time")
    }

    @Test("mirrored: true の絵を渡すと、点は反転した絵の画素の座標で返る (x は幅で折り返した位置)")
    func aMirroredPicturesPointsAreInTheMirroredPixels() throws {
        let seen = try record(mirrored: true, delay: .zero)
        // 幅 16 の絵で、赤い画素 x = 1・5・9 は反転して 14・10・6 になる。中心は +0.5
        #expect(seen.map(\.x) == [14.5, 10.5, 6.5, 14.5, 10.5, 6.5], "\(seen.map(\.x))")
    }

    @Test("arrival を省くと、絵を 1 度だけ探す (host time は 0)")
    func withoutAnArrivalThePictureIsSearchedOnce() throws {
        var pose: HandPose?
        var seen: [UInt64?] = []
        var arrivals: [Int?] = []
        Host.onSetup = { sketch in
            let image = try sketch.createImage(16, 8)
            image.write(markerPicture(width: 16, height: 8, x: 3, y: 4))
            pose = sketch.createHandPose(image, arrival: nil, estimator: MarkerEstimator())
        }
        Host.onDraw = { _ in
            seen.append(pose?.hostTime)
            arrivals.append(pose?.lastArrival?.frame)
        }
        try run(frames: 3)
        #expect(seen == [0, 0, 0])
        #expect(Set(arrivals).count == 1, "結果は 1 度だけ届く: \(arrivals)")
        #expect(pose?.hands.first?[.wrist].position == Vector2(3.5, 4.5))
    }
}

// MARK: - 実物の Vision

/// この実行環境で Vision の手の推論が動くか。動かない環境 (Vision のモデルが無い VM など) では、実物の Vision の
/// 検査を名乗って飛ばす。
private nonisolated let visionRuns: Bool = {
    guard let blank = VisionHandPoseEstimator.blank else { return false }
    return (try? VisionHandPoseEstimator.detect(in: blank)) != nil
}()

/// 実物の Vision (#3587 の条件 2・3)。結果の見た目は突き合わせない (OS の更新でモデルが変わりうる)。
@Suite(
    "実物の Vision で手を探す",
    .serialized,
    .enabled(if: visionRuns, "この実行環境では Vision の手の推論が動かない")
)
struct VisionHandPoseTests {
    @Test("黒い絵では手が見つからず、空を返し、落ちない。用意は何度呼んでもよい")
    func aBlackPictureHasNoHands() async {
        let told = Told()
        let estimator = VisionHandPoseEstimator(tell: { told.append($0) })
        await estimator.prepare()
        await estimator.prepare()
        let black = PixelBuffer(
            width: 640, height: 480,
            components: Array((0..<640 * 480).map { _ in [Float16(0), 0, 0, 1] }.joined()))
        let hands = await estimator.estimate(HandPoseInput(width: 640, height: 480, hostTime: 1, pixels: black))
        #expect(hands.isEmpty)
        #expect(told.all.isEmpty, "Vision は失敗していない: \(told.all)")
    }

    @Test("Vision の関節の名前は 21 で、手の関節の名前の順に並ぶ")
    func theJointNamesLineUp() {
        #expect(VisionHandPoseEstimator.jointNames.count == HandJointName.allCases.count)
        #expect(Set(VisionHandPoseEstimator.jointNames).count == 21)
        #expect(VisionHandPoseEstimator.jointNames[HandJointName.indexTip.rawValue] == .indexTip)
        #expect(VisionHandPoseEstimator.jointNames[HandJointName.thumbMCP.rawValue] == .thumbMP)
        #expect(VisionHandPoseEstimator.handedness(.left) == .left)
        #expect(VisionHandPoseEstimator.handedness(.right) == .right)
        #expect(VisionHandPoseEstimator.handedness(.unknown) == .unknown)
    }
}
