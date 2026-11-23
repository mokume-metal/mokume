// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import Vision
import mokume

@testable import MokumeCore
@testable import MokumeVision

// MARK: - 偽の推論

/// 用意と推論の門。開くまで、または ``releaseOne()`` で 1 つずつ通すまで待たせる。
///
/// 遅い推論は時間でなくこの門で作る: 門を通るのは、呼び出しが**入った後に**検査か ``releaser(_:)`` が通したときだけ。
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 入った数 (通ったかどうかを問わない)。
    private(set) var entered = 0
    /// 通った数。
    private(set) var passed = 0
    /// 同時に中にいた数の最大。
    private(set) var mostAtOnce = 0

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    /// 止まっている呼び出しを 1 つ通す。止まっているものが無ければ `false`。
    func releaseOne() -> Bool {
        guard !waiters.isEmpty else { return false }
        waiters.removeFirst().resume()
        return true
    }

    func pass() async {
        entered += 1
        mostAtOnce = max(mostAtOnce, entered - passed)
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        passed += 1
    }
}

/// `gate` に入った呼び出しを、入るたびに 1 つずつ通す係を main actor の外で起こす。止めるには返した Task を cancel する。
///
/// main actor が推論を待って塞がっている間も通せる。通すのは入った後なので、呼び出しは必ず「入った時点ではまだ終わって
/// いない」推論になる (遅さを時間で作らない)。
private func releaser(_ gate: Gate) -> Task<Void, Never> {
    Task.detached {
        while !Task.isCancelled {
            if await !gate.releaseOne() { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }
}

/// 用意を門で止める偽の推論。推論は用意を待ち、決まった手を返す (`hands` が空なら手が写らない絵)。
private nonisolated struct PreparingEstimator: HandPoseEstimator {
    let gate: Gate
    var hands: [RawHand] = []

    func prepare() async { await gate.pass() }
    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        await prepare()
        return hands
    }
}

/// 用意を門で止めるが、**推論は用意を待たない**偽の推論 (用意の終わりより先に結果が出る順を作る)。
private nonisolated struct EagerEstimator: HandPoseEstimator {
    let gate: Gate
    func prepare() async { await gate.pass() }
    func estimate(_ frame: HandPoseInput) async -> [RawHand] { [] }
}

/// 推論を門で止める偽の推論 (用意はすぐ済む)。決まった手を返す。
private nonisolated struct StuckEstimator: HandPoseEstimator {
    let gate: Gate
    var hands: [RawHand] = []
    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        await gate.pass()
        return hands
    }
}

/// 推論した回数を数え、決まった手を返す偽の推論。
private nonisolated final class CountingEstimator: HandPoseEstimator {
    private let calls = Mutex(0)
    let hands: [RawHand]
    init(hands: [RawHand]) { self.hands = hands }
    var count: Int { calls.withLock { $0 } }
    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        calls.withLock { $0 += 1 }
        return hands
    }
}

/// 絵の中で**いちばん赤い画素**を探し、21 の関節をすべてその画素の中心に置く偽の推論。
///
/// 画素は実物の推論と同じ写し (``VisionHandPoseEstimator/picture(of:)``) で読む。`gate` があれば、その門を
/// 通るまで返らない (遅い推論)。
private nonisolated struct MarkerEstimator: HandPoseEstimator {
    var gate: Gate?

    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        if let gate { await gate.pass() }
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

/// 到着の記録を差し替える入れ物。
private final class ArrivalBox {
    var arrival: Arrival?
    func arrive(_ hostTime: UInt64) { arrival = Arrival(frame: 1, time: 0, hostTime: hostTime) }
}

/// Vision の座標で、21 の関節がすべて同じ点にある手。
private nonisolated func rawHand(x: Float, y: Float) -> RawHand {
    RawHand(handedness: .right, joints: Array(repeating: RawJoint(x: x, y: y, confidence: 0.9), count: 21))
}

// MARK: - 用意の間の状態 (#3587 の条件 3)

@MainActor
struct HandPosePreparationTests {
    private func pose(
        _ estimator: any HandPoseEstimator, waits: Bool = false, pictures: @escaping () -> HandPoseInput? = { nil }
    ) throws -> (HandPose, InferenceSource) {
        let source = InferenceSource(estimator: estimator, waits: { waits }, frame: pictures)
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        return (pose, source)
    }

    @Test("開くと preparing を名乗り、用意の間もフレームは回る。用意が済めば、手が写っていなくても running で、結果は空")
    func preparingThenRunningWithoutHands() async throws {
        let gate = Gate()
        var queue = [HandPoseInput(width: 64, height: 48, hostTime: 9)]
        let (pose, _) = try pose(PreparingEstimator(gate: gate)) { queue.isEmpty ? nil : queue.removeFirst() }
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
        let (pose, source) = try pose(PreparingEstimator(gate: gate))
        #expect(pose.state == .preparing)
        pose.close()
        #expect(pose.state == .stopped)
        await gate.open()
        // 用意が済んだと記す所は、状態を名乗るかを決める所と同じ錠の内側。ここまで進めば、名乗るなら名乗り終えている
        #expect(await eventually { source.isPrepared })
        #expect(pose.state == .stopped, "止めた後に済んだ用意は状態を変えない")
        try pose.open()
        #expect(pose.state == .running, "用意は済んでいるので、足し直すとすぐ running")
        #expect(await gate.passed == 1, "用意は 1 度きり")
    }

    @Test("固定の時計では、開くときに用意を待つ: 用意が門で止まっていても、開いた直後から running")
    func theFixedClockWaitsForThePreparationOnOpen() async throws {
        let gate = Gate()
        // 用意が門に入った後でしか通さない。open() が用意を待たなければ、返った時点で preparing のまま
        let opener = releaser(gate)
        defer { opener.cancel() }
        let (pose, _) = try pose(PreparingEstimator(gate: gate), waits: true)
        #expect(pose.state == .running)
        #expect(await gate.passed == 1)
    }

    @Test("用意が済む前に推論が結果を出しても、結果が見えるフレームでは running (preparing のまま結果を見せない)")
    func aResultBeforeThePreparationEndsComesWithRunning() async throws {
        let gate = Gate()  // 用意は最後まで済まない
        var queue = [HandPoseInput(width: 4, height: 4, hostTime: 5)]
        let (pose, _) = try pose(EagerEstimator(gate: gate)) { queue.isEmpty ? nil : queue.removeFirst() }
        #expect(pose.state == .preparing)
        #expect(await eventually {
            pose.supply()
            return pose.hostTime == 5
        })
        #expect(pose.state == .running, "結果が入ったフレームの状態")
        #expect(await gate.passed == 0, "用意そのものはまだ済んでいない")
    }
}

// MARK: - 固定の時計では推論を待つ (#3587 の条件 4)

@MainActor
struct HandPoseWaitTests {
    @Test("固定の時計では、絵を渡したその supply の中で結果が入る (推論が門で止まっていても)")
    func theFixedClockWaitsForTheResult() async throws {
        let gate = Gate()
        let opener = releaser(gate)
        defer { opener.cancel() }
        var queue = [HandPoseInput(width: 4, height: 4, hostTime: 21)]
        let source = InferenceSource(
            estimator: StuckEstimator(gate: gate), waits: { true },
            frame: { queue.isEmpty ? nil : queue.removeFirst() })
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        pose.supply()
        #expect(pose.hostTime == 21, "同じ supply の中で結果が入る")
        #expect(pose.state == .running)
        #expect(await gate.passed == 1)
    }

    @Test("推論が期限を越えたら、結果なしで進め、1 度だけ名乗り、以後は待たない。手放した推論が終わるまで次を起こさない")
    func aStuckInferenceGivesUpAfterThePatience() async throws {
        let gate = Gate()
        let told = Told()
        let pictures = [HandPoseInput(width: 4, height: 4, hostTime: 1), HandPoseInput(width: 4, height: 4, hostTime: 2)]
        var queue = pictures
        // 門が開かない推論は、期限 (短くてよい) を必ず越える
        let source = InferenceSource(
            estimator: StuckEstimator(gate: gate), waits: { true }, patience: .milliseconds(100),
            tell: { told.append($0) }, frame: { queue.isEmpty ? nil : queue.removeFirst() })
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        pose.supply()  // 期限まで待って返る
        #expect(pose.hostTime == nil, "期限を越えたフレームには結果が無い")
        #expect(source.gaveUpWaiting)
        pose.supply()  // もう待たない。手放した推論が終わっていないので、絵 2 は読まずに持つ
        #expect(source.waiting == 2, "手放した推論が走っている間は、次の推論に渡さない")
        #expect(await gate.entered == 1, "同じ推定器で 2 本目を起こしていない")
        #expect(told.all.count == 1, "\(told.all)")
        #expect(told.all.first?.contains("took longer than") == true)
        #expect(told.all.first?.contains("no longer line up") == true, "以後フレームと揃わないことを名乗る")
        await gate.open()
        #expect(await eventually {
            pose.supply()
            return pose.hostTime == 2
        }, "手放した推論が終われば、待たずに worker が推論する")
        #expect(await gate.mostAtOnce == 1, "推論は同時に 1 本だけ")
    }

    @Test("固定の時計で、同じ到着が 2 フレーム続いたら推論し直さず、前の結果のまま")
    func theSameArrivalOnTwoFramesIsNotInferredAgain() throws {
        let estimator = CountingEstimator(hands: [rawHand(x: 0.5, y: 0.5)])
        let box = ArrivalBox()
        let source = InferenceSource(estimator: estimator, waits: { true }, size: { (8, 8) }) { box.arrival }
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        box.arrive(1)
        pose.supply()
        #expect(pose.hostTime == 1 && pose.hands.count == 1)
        pose.supply()  // 到着は同じ 1 のまま
        #expect(estimator.count == 1, "同じ到着は推論し直さない")
        #expect(pose.hostTime == 1 && pose.hands.count == 1, "前の結果のまま")
        box.arrive(2)
        pose.supply()
        #expect(estimator.count == 2)
        #expect(pose.hostTime == 2)
    }

    @Test("固定の時計で、到着がまだ無い (arrival が nil) 間は推論せず、結果は空のまま")
    func noArrivalYetMeansNoResult() throws {
        let estimator = CountingEstimator(hands: [rawHand(x: 0.5, y: 0.5)])
        let source = InferenceSource(estimator: estimator, waits: { true }, size: { (8, 8) }) { nil }
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        for _ in 0..<3 { pose.supply() }
        #expect(estimator.count == 0)
        #expect(pose.hands.isEmpty && pose.hostTime == nil)
        #expect(pose.state == .running)
    }

    @Test("期限で手放した推論が、外した後に終わっても、結果は入らず状態は stopped のまま (スケッチの終わりも同じ close)")
    func anAbandonedInferenceThatEndsAfterTheStopIsDropped() async throws {
        let gate = Gate()
        var queue = [HandPoseInput(width: 4, height: 4, hostTime: 1)]
        let source = InferenceSource(
            estimator: StuckEstimator(gate: gate, hands: [rawHand(x: 0.5, y: 0.5)]), waits: { true },
            patience: .milliseconds(100), tell: { _ in }, frame: { queue.isEmpty ? nil : queue.removeFirst() })
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        pose.supply()  // 門が開かないので期限を越えて手放す
        #expect(source.gaveUpWaiting)
        pose.close()
        await gate.open()
        // 手放した推論が終わり、手放した数が 0 に戻るまで進める
        #expect(await eventually { await gate.passed == 1 && source.worker?.isIdle == true })
        #expect(pose.state == .stopped)
        pose.supply()
        #expect(pose.hands.isEmpty && pose.hostTime == nil, "外した後に終わった推論の結果は入らない")
        try pose.open()
        pose.supply()
        #expect(pose.hands.isEmpty && pose.hostTime == nil, "足し直しても、外す前の絵の結果は出ない")
    }
}

// MARK: - 実時間で、捨てる絵を読み出さない (#3587 の反証 6)

@MainActor
struct HandPoseReadTests {
    @Test("推論中に届いた絵は読み出さずに持ち、空いたフレームで最新の 1 枚だけを読む")
    func picturesArrivingDuringAnInferenceAreNotRead() async throws {
        let gate = Gate()
        let reads = Mutex(0)
        var next: UInt64?
        let source = InferenceSource(estimator: StuckEstimator(gate: gate)) { () -> ArrivedPicture? in
            guard let hostTime = next else { return nil }
            next = nil
            return ArrivedPicture(hostTime: hostTime) {
                reads.withLock { $0 += 1 }
                return HandPoseInput(width: 4, height: 4, hostTime: hostTime)
            }
        }
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        next = 1
        pose.supply()
        #expect(await eventually { await gate.entered == 1 }, "絵 1 の推論が門で止まっている")
        for hostTime in [2, 3, 4] as [UInt64] {
            next = hostTime
            pose.supply()
        }
        #expect(reads.withLock { $0 } == 1, "推論中に届いた絵 2・3・4 は読み出していない")
        #expect(source.waiting == 4, "最新の 1 枚だけを持つ")
        await gate.open()
        #expect(await eventually {
            pose.supply()
            return pose.hostTime == 4
        })
        #expect(reads.withLock { $0 } == 2, "読んだのは絵 1 と、空いた後の絵 4 だけ")
    }
}

// MARK: - Vision へ渡す絵 (#3587 の条件 5)

/// 画素の写しは main の外で作り、比べられる (#4098)。推論と同じく main actor に載せない。
nonisolated struct HandPosePictureTests {
    @Test("Vision へ渡す絵は、乗算済みを外し sRGB の転送関数を掛けた 8 bit。画素の並びは変えない")
    func thePictureIsStraightAndEncoded() throws {
        // 2×1: 左は不透明度 0.5 で乗算済みの赤 (乗算前は赤 1)、右は不透明な線形 0.5 の灰
        let pixels = PixelBuffer(width: 2, height: 1, components: [0.5, 0, 0, 0.5, 0.5, 0.5, 0.5, 1])
        let frame = HandPoseInput(pixels: pixels, hostTime: 1)
        #expect(frame == HandPoseInput(width: 2, height: 1, hostTime: 1, pixels: pixels), "大きさは画素のもの")
        #expect(frame != HandPoseInput(width: 2, height: 1, hostTime: 1), "画素の有無も比べる")
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

// MARK: - Vision の点から画素の座標へ (#3587 の条件 2・5)

nonisolated struct HandPoseMappingTests {
    @Test("正規化の値は画素の角の座標: 0.5 は中央、1 は幅・高さ (幅 − 1 ではない)。画素 i の中心は i + 0.5")
    func normalizedValuesAreCornerCoordinates() throws {
        // 奇数の大きさ: 中央は画素 2 の中心 (2.5) で、半画素の補正が入れば外れる
        let frame = HandPoseInput(width: 5, height: 3, hostTime: 1)
        let mapped = HandPoseResult(
            raw: [rawHand(x: 0, y: 0), rawHand(x: 1, y: 1), rawHand(x: 0.5, y: 0.5), rawHand(x: 0.7, y: 0.5)],
            of: frame)
        #expect(mapped.hands.map { $0[.wrist].position } == [
            Vector2(0, 3), Vector2(5, 0), Vector2(2.5, 1.5), Vector2(3.5, 1.5),
        ])
    }

    @Test("Vision の点の写し: 位置は Vision の座標のまま、信頼度と左右はそのまま。返らなかった関節は埋めない")
    func visionPointsBecomeRawJoints() throws {
        let hand = VisionHandPoseEstimator.rawHand(chirality: .left) { name in
            (location: CGPoint(x: 0.25, y: name == .indexTip ? 0.9 : 0.75), confidence: 0.5)
        }
        #expect(hand.handedness == .left)
        #expect(hand.joints.count == 21)
        #expect(hand.joints[HandJointName.wrist.rawValue] == RawJoint(x: 0.25, y: 0.75, confidence: 0.5))
        #expect(hand.joints[HandJointName.indexTip.rawValue] == RawJoint(x: 0.25, y: 0.9, confidence: 0.5))
        // 画素の座標へ: 640×480 で (0.25, 0.75) は (160, 120)、y = 0.9 の指先は手首より上 (y が小さい)
        let result = HandPoseResult(raw: [hand], of: HandPoseInput(width: 640, height: 480, hostTime: 1))
        let pixels = try #require(result.hands.first)
        #expect(pixels[.wrist].position == Vector2(160, 120))
        #expect(pixels[.indexTip].position.y < pixels[.wrist].position.y)

        let short = VisionHandPoseEstimator.rawHand(chirality: .right) { name in
            name == .littleTip ? nil : (location: CGPoint(x: 0.5, y: 0.5), confidence: 0.1)
        }
        #expect(short.joints.count == 20, "Vision が返さなかった関節は埋めない")
    }

    @MainActor
    @Test("Vision が関節を 1 つ返さなかった手は、手ごと捨て、結果は空で、1 度だけ名乗る")
    func aHandMissingOneJointIsDroppedAndToldOnce() throws {
        let short = VisionHandPoseEstimator.rawHand(chirality: .right) { name in
            name == .littleTip ? nil : (location: CGPoint(x: 0.5, y: 0.5), confidence: 0.1)
        }
        let told = Told()
        let dropped = DroppedHands { told.append($0) }
        let box = ArrivalBox()
        let source = InferenceSource(
            estimator: CountingEstimator(hands: [short]), dropped: dropped, waits: { true }, size: { (8, 8) }
        ) { box.arrival }
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        for hostTime in [1, 2] as [UInt64] {
            box.arrive(hostTime)
            pose.supply()
            #expect(pose.hostTime == hostTime && pose.hands.isEmpty, "20 点の手は結果に残らない")
        }
        #expect(dropped.total == 2)
        #expect(told.all.count == 1, "\(told.all)")
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
    private func record(mirrored: Bool, gate: Gate?) throws -> [(x: Float?, matches: Bool, clock: Clock)] {
        let xs = [1, 5, 9]
        var camera: Capture?
        var pose: HandPose?
        var seen: [(x: Float?, matches: Bool, clock: Clock)] = []
        Host.onSetup = { sketch in
            let frames = xs.map { markerPicture(width: 16, height: 8, x: $0, y: 2) }
            let capture = try sketch.createCapture(frames: frames, mirrored: mirrored)
            camera = capture
            pose = sketch.createHandPose(
                capture.image, arrival: { capture.lastArrival }, estimator: MarkerEstimator(gate: gate))
        }
        Host.onDraw = { sketch in
            let x = pose?.hands.first?[.indexTip].position.x
            let matches = pose?.hostTime != nil && pose?.hostTime == camera?.lastArrival?.hostTime
            seen.append((x, matches, sketch.clock))
        }
        try run(frames: 6)
        return seen
    }

    @Test("固定の時計で絵の列を流すと、フレーム N の絵に対する結果がフレーム N の draw() に出る (推論が門で止まっていても)")
    func eachFramesResultArrivesOnThatFrame() async throws {
        let gate = Gate()
        let opener = releaser(gate)
        defer { opener.cancel() }
        let seen = try record(mirrored: false, gate: gate)
        #expect(seen.allSatisfy { $0.clock != .wallClock }, "ウィンドウを開かずに回す実行は固定の時計")
        #expect(seen.map(\.x) == [1.5, 5.5, 9.5, 1.5, 5.5, 9.5], "\(seen.map(\.x))")
        #expect(seen.allSatisfy { $0.matches }, "結果の host time は、そのフレームに届いた絵の host time")
        #expect(await gate.passed == 6, "どのフレームの推論も、門に入ってから通した")
    }

    @Test("mirrored: true の絵を渡すと、点は反転した絵の画素の座標で返る (x は幅で折り返した位置)")
    func aMirroredPicturesPointsAreInTheMirroredPixels() throws {
        let seen = try record(mirrored: true, gate: nil)
        // 幅 16 の絵で、赤い画素 x = 1・5・9 は反転して 14・10・6 になる。偽の推論が画素の中心を返すので +0.5
        // (写しそのものに半画素の補正は無い・HandPoseMappingTests)
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

// MARK: - 手の写真での確認 (写真を渡したときだけ)

/// 確かめる手の写真のパス。リポジトリには写真を置かない (帰属と容量)。メンテナが手元の写真を渡して回す:
/// `MOKUME_HAND_PHOTO=<指を上へ立てた手の写真> swift test --filter HandPhotoTests`
private nonisolated let handPhoto: String? = ProcessInfo.processInfo.environment["MOKUME_HAND_PHOTO"]

/// 写真を、向きの情報 (EXIF) を当てた絵として読む。
private nonisolated func uprightPicture(at path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// 左右を入れ替えた絵 (`mirrored: true` のカメラの絵と同じ並び)。
private nonisolated func mirrored(_ picture: CGImage) -> CGImage? {
    guard
        let context = CGContext(
            data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.translateBy(x: CGFloat(picture.width), y: 0)
    context.scaleBy(x: -1, y: 1)
    context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
    return context.makeImage()
}

/// 実物の Vision に手の写真を渡し、正の経路 (手が見つかる) を確かめる (#3587 の条件 2)。計測ではなく期待を持つ。
/// 写真が無ければ名乗って飛ばす。結果の見た目 (点の位置そのもの) は突き合わせず、数・範囲・向きだけを見る。
@Suite(
    "手の写真で実物の Vision を確かめる",
    .serialized,
    .enabled(if: handPhoto != nil, "MOKUME_HAND_PHOTO に手の写真のパスを渡したときだけ走る"),
    .enabled(if: visionRuns, "この実行環境では Vision の手の推論が動かない")
)
struct HandPhotoTests {
    /// 写真の手を画素の座標で返す。
    private func hands(in picture: CGImage) throws -> [Hand] {
        let raw = try VisionHandPoseEstimator.detect(in: picture)
        let converted = HandPoseResult.converting(
            raw, of: HandPoseInput(width: picture.width, height: picture.height, hostTime: 1))
        #expect(converted.dropped == 0, "Vision が関節を欠かして捨てた手がある")
        return converted.result.hands
    }

    @Test("立てた手の写真で、手が見つかり、手ごとに 21 点・信頼度 0〜1・左右が入り、指先は手首より上に写る")
    func aRaisedHandIsFoundWithTwentyOneJoints() throws {
        let path = try #require(handPhoto)
        let picture = try #require(uprightPicture(at: path), "写真を読めない: \(path)")
        let found = try hands(in: picture)
        #expect(!found.isEmpty, "手が見つからない")
        for hand in found {
            #expect(hand.joints.count == 21)
            #expect(hand.joints.allSatisfy { (0...1).contains($0.confidence) })
            #expect(hand.handedness != .unknown, "左右が入る")
            // 画素の座標は y が下向き。指を上へ立てた手なら、中指の先は手首より上 (y が小さい)
            #expect(hand[.middleTip].position.y < hand[.wrist].position.y, "y の向きが逆")
            #expect(hand.joints.allSatisfy {
                (0...Float(picture.width)).contains($0.position.x) && (0...Float(picture.height)).contains($0.position.y)
            }, "点が絵の中にある")
        }
    }

    @Test("左右を入れ替えた写真では、手首の x が幅で折り返した位置に来る (入れ替えた絵の画素の座標)")
    func aMirroredPhotoMirrorsTheX() throws {
        let path = try #require(handPhoto)
        let picture = try #require(uprightPicture(at: path))
        let flipped = try #require(mirrored(picture))
        let straight = try #require(try hands(in: picture).first)
        let turned = try #require(try hands(in: flipped).first)
        let width = Float(picture.width)
        // 推論は左右を入れ替えた絵でも同じ点を返すとは限らないので、幅の 5% までのずれを許す
        #expect(abs(turned[.wrist].position.x - (width - straight[.wrist].position.x)) < width * 0.05)
        #expect(abs(turned[.wrist].position.y - straight[.wrist].position.y) < Float(picture.height) * 0.05)
    }
}
