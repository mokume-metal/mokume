// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeVision

/// 21 の関節がそれぞれ別の位置にある手。
private nonisolated func makeHand(_ handedness: Handedness = .right, shift: Float = 0) -> Hand {
    let joints = HandJointName.allCases.map {
        HandJoint(position: Vector2(Float($0.rawValue) + shift, 2 * Float($0.rawValue)), confidence: 0.5)
    }
    return Hand(handedness: handedness, joints: joints)!
}

/// Vision の座標で、21 の関節がすべて同じ点にある手。
private nonisolated func makeRawHand(x: Float, y: Float, confidence: Float = 0.9) -> RawHand {
    RawHand(
        handedness: .left,
        joints: Array(repeating: RawJoint(x: x, y: y, confidence: confidence), count: 21))
}

// MARK: - 結果の型と座標の写し (GPU も Vision も要らない)

/// 結果の型 (#3586・#3129 の条件 5・7)。
nonisolated struct HandPoseResultTests {
    @Test("Vision の座標 (0〜1・左下が原点) は、入力の絵の画素の座標 (左上が原点・y は下向き) になる")
    func visionCoordinatesBecomePixelCoordinates() throws {
        let frame = HandPoseInput(width: 640, height: 480, hostTime: 77)
        let result = HandPoseResult(raw: [makeRawHand(x: 0.25, y: 0.75)], of: frame)
        let hand = try #require(result.hands.first)
        #expect(hand.joints.count == 21)
        for joint in hand.joints {
            #expect(joint.position == Vector2(160, 120))
            #expect(joint.confidence == 0.9)
        }
        #expect(hand.handedness == .left)
        #expect(result.hostTime == 77, "絵の host time を持つ")
    }

    @Test("四隅: 左下 (0, 0) は画面の左下、右上 (1, 1) は画面の右上")
    func theCornersLandOnTheCorners() throws {
        let frame = HandPoseInput(width: 640, height: 480, hostTime: 1)
        let corners = HandPoseResult(raw: [makeRawHand(x: 0, y: 0), makeRawHand(x: 1, y: 1)], of: frame)
        #expect(corners.hands[0][.wrist].position == Vector2(0, 480))
        #expect(corners.hands[1][.wrist].position == Vector2(640, 0))
    }

    @Test("大きさは入力の絵のもの: 同じ点でも絵が違えば画素の座標も違う。左右は入れ替えない")
    func theSizeIsTheInputPictures() {
        let raw = [makeRawHand(x: 0.25, y: 0.5)]
        let wide = HandPoseResult(raw: raw, of: HandPoseInput(width: 800, height: 200, hostTime: 1))
        let small = HandPoseResult(raw: raw, of: HandPoseInput(width: 100, height: 40, hostTime: 1))
        #expect(wide.hands[0][.wrist].position == Vector2(200, 100))
        #expect(small.hands[0][.wrist].position == Vector2(25, 20))
    }

    @Test("関節が 21 に満たない手は捨てる。手が無ければ空の結果")
    func malformedHandsAreDropped() {
        let frame = HandPoseInput(width: 10, height: 10, hostTime: 5)
        let short = RawHand(handedness: .right, joints: [RawJoint(x: 0, y: 0, confidence: 1)])
        #expect(HandPoseResult(raw: [short, makeRawHand(x: 0.5, y: 0.5)], of: frame).hands.count == 1)
        let empty = HandPoseResult(raw: [], of: frame)
        #expect(empty.hands.isEmpty)
        #expect(empty.hostTime == 5, "手が写らない絵でも、結果は絵の host time を持つ")
    }

    @Test("手の関節は 21 でなければ作れない")
    func aHandNeedsTwentyOneJoints() {
        let joint = HandJoint(position: Vector2(0, 0), confidence: 1)
        #expect(Hand(handedness: .left, joints: Array(repeating: joint, count: 20)) == nil)
        #expect(Hand(handedness: .left, joints: Array(repeating: joint, count: 22)) == nil)
        #expect(Hand(handedness: .left, joints: Array(repeating: joint, count: 21)) != nil)
        #expect(HandJointName.allCases.count == 21)
        #expect(HandJointName.indexTip.rawValue == 8)
    }

    @Test("結果の列を JSON に書いて読み戻すと等しい。関節が 21 でない手は読めない")
    func resultsRoundTripThroughJSON() throws {
        let results = [
            HandPoseResult(hostTime: 123_456_789_012, hands: [makeHand(.left), makeHand(.unknown, shift: 3)]),
            HandPoseResult(hostTime: 2, hands: []),
        ]
        let data = try JSONEncoder().encode(results)
        #expect(try JSONDecoder().decode([HandPoseResult].self, from: data) == results)

        let broken = #"{"handedness":"left","joints":[{"position":{"x":0,"y":0},"confidence":1}]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Hand.self, from: Data(broken.utf8)) }
    }
}

// MARK: - 記録した結果の再生 (入り口を直に回す)

/// 記録した結果を流す入り口 (#3586・#3129 の条件 7)。走っているスケッチを使わず、入り口を直に回す。
@MainActor
struct RecordedHandPoseTests {
    private func pose(_ frames: [HandPoseResult?]) throws -> HandPose {
        let pose = HandPose(name: "hand pose (recorded)", source: RecordedHandPoseSource(frames: frames))
        try pose.open()
        return pose
    }

    @Test("結果は i 番目のフレームで入り、最後まで行けば最初に戻る。host time は元の絵のもの")
    func resultsArriveFrameByFrameAndWrap() throws {
        let first = HandPoseResult(hostTime: 10, hands: [makeHand(.left)])
        let second = HandPoseResult(hostTime: 20, hands: [makeHand(.right), makeHand(.left, shift: 5)])
        let pose = try pose([first, second])
        #expect(pose.state == .running)
        #expect(pose.hands.isEmpty && pose.hostTime == nil && pose.lastArrival == nil, "届く前")

        var seen: [(hands: [Hand], hostTime: UInt64?)] = []
        for _ in 0..<5 {
            pose.supply()
            seen.append((pose.hands, pose.hostTime))
        }
        #expect(seen.map(\.hostTime) == [10, 20, 10, 20, 10])
        #expect(seen[0].hands == first.hands && seen[1].hands == second.hands)
        #expect(pose.lastArrival?.hostTime == 10, "到着の記録の host time は、結果の元の絵のもの")
    }

    @Test("nil のフレームは新しい結果が無く、前の結果が最新のまま残る。空の結果は手が写らなかったことを言う")
    func nilKeepsTheLatestAndEmptyMeansNoHands() throws {
        let hand = HandPoseResult(hostTime: 1, hands: [makeHand()])
        let none = HandPoseResult(hostTime: 3, hands: [])
        let pose = try pose([hand, nil, none])
        pose.supply()
        #expect(pose.hands.count == 1)
        pose.supply()
        #expect(pose.hands.count == 1 && pose.hostTime == 1, "nil のフレームは前の結果のまま")
        pose.supply()
        #expect(pose.hands.isEmpty && pose.hostTime == 3, "手が写らなければ空の結果。落ちない")
        #expect(pose.state == .running)
    }

    @Test("同じ列を 2 回流すと同じ点が同じフレームに出る。書き出して読み戻した列からも同じ")
    func replayIsDeterministic() throws {
        let recorded: [HandPoseResult?] = [
            HandPoseResult(hostTime: 1, hands: [makeHand(.left)]), nil,
            HandPoseResult(hostTime: 3, hands: [makeHand(.right, shift: 2)]),
        ]
        func play(_ frames: [HandPoseResult?]) throws -> [[Hand]] {
            let pose = try pose(frames)
            return (0..<7).map { _ in
                pose.supply()
                return pose.hands
            }
        }
        let first = try play(recorded)
        #expect(first == (try play(recorded)))
        let reread = try JSONDecoder().decode(
            [HandPoseResult?].self, from: JSONEncoder().encode(recorded))
        #expect(first == (try play(reread)))
    }

    @Test("空の列は unavailable のまま何も入らない。外すと stopped で、結果は消え、足し直せば続きが入る")
    func emptyAndStopped() throws {
        let empty = try pose([])
        empty.supply()
        #expect(empty.state == .unavailable && empty.hands.isEmpty)

        let pose = try pose([HandPoseResult(hostTime: 1, hands: [makeHand()]), HandPoseResult(hostTime: 2, hands: [])])
        pose.supply()
        #expect(pose.hands.count == 1)
        pose.close()
        #expect(pose.state == .stopped)
        #expect(pose.hands.isEmpty && pose.hostTime == nil, "外した入り口は、外す前の結果を見せない")
        pose.supply()
        #expect(pose.hands.isEmpty, "外している間は何も入らない")
        try pose.open()
        #expect(pose.state == .running)
        pose.supply()
        #expect(pose.hostTime == 2, "外していた間は進まず、続きの 2 番目が入る")
        #expect(pose.report?.state == .running)
    }
}

// MARK: - 推論 (差し替えた偽物で回す)

/// 偽の推論が何を見たかの記録と、1 枚目を止めておく門。
private actor Trace {
    private(set) var started: [UInt64] = []
    private(set) var finished: [UInt64] = []
    private var gated: [CheckedContinuation<Void, Never>] = []
    private var isOpen = true

    func closeGate() { isOpen = false }
    func openGate() {
        isOpen = true
        for waiter in gated { waiter.resume() }
        gated = []
    }
    func begin(_ hostTime: UInt64) { started.append(hostTime) }
    func end(_ hostTime: UInt64) { finished.append(hostTime) }
    func pass() async {
        if isOpen { return }
        await withCheckedContinuation { gated.append($0) }
    }
}

/// 決まった手を返す偽の推論。`gatedTime` の絵では門が開くまで終わらない (遅い推論)。
private nonisolated struct FakeEstimator: HandPoseEstimator {
    let trace: Trace
    var hands: [RawHand] = [makeRawHand(x: 0.25, y: 0.75)]
    var gatedTime: UInt64?

    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        await trace.begin(frame.hostTime)
        if frame.hostTime == gatedTime { await trace.pass() }
        await trace.end(frame.hostTime)
        return hands
    }
}

/// `condition` が成り立つまで入り口を回す。**待つ側が期限を持つ** (2 秒)。
@MainActor
private func settle(_ pose: HandPose, until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        pose.supply()
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// 差し替えた推論で入り口を回す (#3586・#3129 の条件 3・4・5・9)。
@MainActor
struct InferencePoseTests {
    /// 取り出すたびに、次の絵を 1 枚ずつ渡す写し。
    private final class Pictures {
        var queue: [HandPoseInput]
        init(_ queue: [HandPoseInput]) { self.queue = queue }
        func next() -> HandPoseInput? { queue.isEmpty ? nil : queue.removeFirst() }
    }

    private func pose(_ estimator: any HandPoseEstimator, _ pictures: Pictures) throws -> HandPose {
        let source = InferenceSource(estimator: estimator, frame: pictures.next)
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        return pose
    }

    private static func picture(_ hostTime: UInt64) -> HandPoseInput {
        HandPoseInput(width: 640, height: 480, hostTime: hostTime)
    }

    @Test("推論の結果は画素の座標で入り、元の絵の host time を持つ。推論が終わった時刻ではない")
    func resultCarriesThePicturesHostTime() async throws {
        let pose = try pose(FakeEstimator(trace: Trace()), Pictures([Self.picture(4242)]))
        #expect(pose.state == .running)
        #expect(await settle(pose) { !pose.hands.isEmpty })
        #expect(pose.hands[0][.indexTip].position == Vector2(160, 120))
        #expect(pose.hostTime == 4242)
        #expect(pose.lastArrival?.hostTime == 4242)
    }

    @Test("手が写らない絵では空の結果が届き、落ちず、状態は running のまま")
    func noHandsGivesAnEmptyResult() async throws {
        let pose = try pose(FakeEstimator(trace: Trace(), hands: []), Pictures([Self.picture(7)]))
        #expect(await settle(pose) { pose.hostTime == 7 })
        #expect(pose.hands.isEmpty)
        #expect(pose.state == .running)
    }

    @Test("同じ絵を 2 度推論しない: 新しい絵が届いたときだけ推論する")
    func eachPictureIsInferredOnce() async throws {
        let trace = Trace()
        let pictures = Pictures([Self.picture(1)])
        let pose = try pose(FakeEstimator(trace: trace), pictures)
        #expect(await settle(pose) { pose.hostTime == 1 })
        for _ in 0..<5 { pose.supply() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await trace.started == [1])
    }

    @Test("遅い推論の間も入り口は止まらず、溜めない: 推論中に届いた絵は最新の 1 枚だけを推論する")
    func slowInferenceNeitherBlocksNorQueues() async throws {
        let trace = Trace()
        await trace.closeGate()
        // 1 枚目が門で止まっている間に、2・3・4 枚目が届く
        let pictures = Pictures([Self.picture(1)])
        let pose = try pose(FakeEstimator(trace: trace, gatedTime: 1), pictures)
        pose.supply()
        let deadline = ContinuousClock.now + .seconds(2)
        while await trace.started.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await trace.started == [1], "1 枚目の推論が始まって止まっている")

        for hostTime in [2, 3, 4] as [UInt64] {
            pictures.queue = [Self.picture(hostTime)]
            pose.supply()  // 推論を待たずに返る (返らなければこの検査は進まない)
        }
        #expect(pose.hands.isEmpty, "遅い推論の間は、結果がまだ無い")
        #expect(pose.state == .running)

        await trace.openGate()
        #expect(await settle(pose) { pose.hostTime == 4 })
        #expect(await trace.started == [1, 4], "間の 2・3 枚目は捨てた。最新の 4 枚目だけ推論した")
        #expect(pose.lastArrival?.hostTime == 4, "結果は最新の絵のもの")
    }

    @Test("止めた後に終わった推論の結果は入れない。足し直した後も、外す前の絵の結果は出ない")
    func resultsAfterStopAreDiscarded() async throws {
        let trace = Trace()
        await trace.closeGate()
        let pictures = Pictures([Self.picture(1)])
        let pose = try pose(FakeEstimator(trace: trace, gatedTime: 1), pictures)
        pose.supply()
        let deadline = ContinuousClock.now + .seconds(2)
        while await trace.started.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

        pose.close()
        try pose.open()  // 足し直し。止める前に始めた推論はまだ止まっている
        await trace.openGate()
        while await trace.finished.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<3 { pose.supply() }
        #expect(pose.hands.isEmpty && pose.hostTime == nil, "止める前に始めた推論の結果は入らない")

        // 足し直した後の絵は、ふつうに推論される
        pictures.queue = [Self.picture(2)]
        #expect(await settle(pose) { pose.hostTime == 2 })
    }
}

// MARK: - 走っているスケッチの中 (GPU を要する)

/// 入り口の供給は足した順に回り、`draw()` の前に済む (#3586・#3129 の条件 5・7)。GPU を要する。
@Suite(
    "手の関節点の入り口 (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct HandPoseSketchTests {
    /// 渡した手続きを `setup()` と `draw()` で走らせるスケッチ。
    final class Host: Sketch {
        nonisolated(unsafe) static var onSetup: (Host) -> Void = { _ in }
        nonisolated(unsafe) static var onDraw: (Host) -> Void = { _ in }
        init() {}
        var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
        func setup() { Self.onSetup(self) }
        func draw() {
            background(0, 0, 0)
            Self.onDraw(self)
        }
    }

    private func run(frames: Int) throws {
        let runtime = try SketchRuntime(sketch: Host(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
    }

    @Test("記録した結果は、同じフレームに同じ点が出る。2 回流しても、JSON に書いて読み戻した列でも同じ")
    func recordedResultsReplayIdentically() throws {
        let recorded: [HandPoseResult?] = [
            HandPoseResult(hostTime: 10, hands: [makeHand(.left)]), nil,
            HandPoseResult(hostTime: 30, hands: []), HandPoseResult(hostTime: 40, hands: [makeHand(.right, shift: 4)]),
        ]
        func record(_ results: [HandPoseResult?]) throws -> [[Hand]] {
            var pose: HandPose?
            var seen: [[Hand]] = []
            Host.onSetup = { pose = $0.createHandPose(results: results) }
            Host.onDraw = { _ in seen.append(pose?.hands ?? []) }
            try run(frames: 9)
            return seen
        }
        let first = try record(recorded)
        #expect(first.count == 9)
        #expect(first[0].count == 1 && first[1].count == 1 && first[2].isEmpty && first[3].count == 1)
        #expect(first[4] == first[0], "最後まで行けば最初に戻る")
        #expect(try record(recorded) == first)
        let reread = try JSONDecoder().decode([HandPoseResult?].self, from: JSONEncoder().encode(recorded))
        #expect(try record(reread) == first)
    }

    @Test("絵と到着の記録から組むと、絵の大きさで画素の座標になり、到着の host time が結果に付く。同じ到着は推論しない")
    func imageAndArrivalDriveTheInference() async throws {
        let image = try Image(
            width: 640, height: 480, pixels: Array(repeating: .zero, count: 640 * 480), gpu: try RenderDevice())
        var arrival: Arrival?
        let trace = Trace()
        let source = InferenceSource(estimator: FakeEstimator(trace: trace), image: image) { arrival }
        let pose = HandPose(name: "hand pose", source: source)
        try pose.open()
        pose.supply()
        let startedEarly = await trace.started
        #expect(pose.hostTime == nil && startedEarly.isEmpty, "絵がまだ届いていなければ推論しない")

        arrival = Arrival(frame: 3, time: 0.05, hostTime: 987_654)
        #expect(await settle(pose) { pose.hostTime == 987_654 })
        #expect(pose.hands[0][.wrist].position == Vector2(160, 120), "640×480 の絵に Vision の (0.25, 0.75) は (160, 120)")
        #expect(pose.lastArrival?.hostTime == 987_654, "結果の時刻は絵の host time と一致する")
        for _ in 0..<5 { pose.supply() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await trace.started == [987_654], "同じ到着の絵は 2 度推論しない")
    }

    @Test("絵の入り口を先に足せば、手の入り口はそのフレームで書かれたばかりの絵を見る (供給は足した順)")
    func suppliesRunInTheOrderTheyWereAdded() async throws {
        /// `supply()` のたびに host time を 1 進める、絵を書く入り口 (`Capture`) の代わり。
        final class Painter: Inlet {
            private(set) var hostTime: UInt64 = 0
            func supply() { hostTime += 1 }
        }
        func firstPictureSeen(painterFirst: Bool) async throws -> UInt64? {
            let trace = Trace()
            Host.onSetup = { sketch in
                let painter = Painter()
                let source = InferenceSource(estimator: FakeEstimator(trace: trace)) {
                    painter.hostTime == 0 ? nil : HandPoseInput(width: 8, height: 8, hostTime: painter.hostTime)
                }
                let hands = HandPose(name: "hand pose", source: source)
                if painterFirst {
                    sketch.attach(painter)
                    sketch.attach(hands)
                } else {
                    sketch.attach(hands)
                    sketch.attach(painter)
                }
            }
            Host.onDraw = { _ in }
            try run(frames: 1)
            let deadline = ContinuousClock.now + .seconds(2)
            while await trace.started.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            return await trace.started.first
        }
        #expect(try await firstPictureSeen(painterFirst: true) == 1, "絵の入り口が先なら、1 フレーム目で 1 枚目の絵を見る")
        // 陰性対照: 順を逆にすると、1 フレーム目には絵がまだ無い (推論は始まらない)
        #expect(try await firstPictureSeen(painterFirst: false) == nil)
    }
}
