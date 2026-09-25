// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 利用者が読む 10 通の文面を、**実装とは別の場所に写して突き合わせる**。
///
/// 畳んだ拍子に変わっていないことをここで見る。実際に 2 度動いている — 7 本を 1 つの型へ
/// 畳んだとき「頼んだ」が「頼んた」になり ([#947]・語幹だけを差し替えて音便を落とした)、
/// その後 3 スロットの組み立てごと畳んで英語の 9 文になった (ADR-0038 決定 3)。切り抜きの
/// 1 文は後から足した ([#1505])。
///
/// [#947]: https://github.com/mokume-metal/mokume/issues/947
/// [#1505]: https://github.com/mokume-metal/mokume/issues/1505
private let outsideFrameNotices: [Canvas.OutsideFrame: String] = [
    .camera:
        "The camera and projection are placed again every frame, so call this from "
            + "draw(). The camera placed during setup belongs to no frame, and was ignored",
    .transform:
        "Transforms are written again every frame, so call this from draw(). The "
            + "transform written during setup belongs to no frame, and was ignored",
    .style:
        "Pushing and popping style only works inside a frame. The style pushed during "
            + "setup belongs to no frame, and was ignored",
    .clip:
        "The clip is written again every frame, so call this from draw(). The clip "
            + "written during setup belongs to no frame, and was ignored",
    .light:
        "Lights are placed again every frame, so call this from draw(). The light "
            + "placed during setup belongs to no frame, and was ignored",
    .surroundings:
        "The surroundings are placed again every frame, so call this from draw(). The "
            + "surroundings placed during setup belong to no frame, and were ignored",
    .shadow:
        "Shadows are written again every frame, so call this from draw(). The shadow "
            + "written during setup belongs to no frame, and was ignored",
    .material:
        "Materials are written again every frame, so call this from draw(). The "
            + "material written during setup belongs to no frame, and was ignored",
    .particles:
        "Particles are handled where you draw, in draw(). The particles emitted during "
            + "setup belong to no frame, and were ignored",
    .compute:
        "Compute is a preamble to drawing, so ask for it from draw(). The compute asked "
            + "for during setup belongs to no frame, and was ignored",
]

/// 文面そのものの検査。**GPU は要らない** ので、GPU の無い環境でも走る。
@Suite("フレームの外で置き直したときの文面")
struct OutsideFrameNoticeTests {
    @Test("10 通とも原文のまま")
    func noticesKeepTheirWording() {
        for (subject, original) in outsideFrameNotices {
            #expect(subject.notice == original, "\(subject) の文面が変わっている")
        }
    }

    @Test("種類を足したら、原文も足すことになる")
    func everySubjectHasAnOriginal() {
        for subject in Canvas.OutsideFrame.allCases {
            #expect(outsideFrameNotices[subject] != nil, "\(subject) の原文が検査に無い")
        }
    }

    @Test("鍵は種類ごとに分かれている")
    func keysAreDistinct() {
        // 畳むときに鍵を取り違えると、ある注意が別の注意を黙らせる。振る舞いの側は
        // 「光の注意は、視点の注意を黙らせない」が見ているので、ここは構造で見る
        let keys = Set(Canvas.OutsideFrame.allCases.map(\.warning))
        #expect(keys.count == Canvas.OutsideFrame.allCases.count)
    }
}

/// 「初回だけ知らせる」控えそのものの検査。GPU は要らない。
///
/// 見るのは 3 つ — **同じ注意を繰り返さない**・**別の注意を黙らせない**・**言った文面が
/// 変わらない**。旗を 31 個持っていたときは、この 3 つを守っていたのは呼び出し側に
/// 写された `guard` / 代入の組で、写しが 1 つ抜けても絵にもログにも出なかった ([#734])。
///
/// [#734]: https://github.com/mokume-metal/mokume/issues/734
@Suite("初回だけ言う注意")
struct WarningLogTests {
    /// 検査のための鍵。**種類が 2 つ以上あることに意味がある** (取り違えを見るため)。
    private enum Key: Hashable {
        case first
        case second
    }

    @Test("同じ注意を 2 度頼んでも、言うのは 1 度だけ")
    func saysTheSameWarningOnlyOnce() {
        var log = WarningLog<Key>()
        var built = 0
        // **文面を組み立てた回数で数える。** 言うときにしか組み立てないので、これが
        // そのまま「標準エラーへ書いた回数」になる
        for _ in 0..<3 {
            log.warnOnce(.first, { () -> String in built += 1; return "一度きり" }())
        }
        #expect(built == 1)
        #expect(log.hasWarned(.first))
    }

    @Test("別の注意は、互いに黙らせない")
    func differentWarningsDoNotSilenceEachOther() {
        var log = WarningLog<Key>()
        var built: [Key] = []
        log.warnOnce(.first, { () -> String in built.append(.first); return "ひとつめ" }())
        log.warnOnce(.second, { () -> String in built.append(.second); return "ふたつめ" }())
        log.warnOnce(.first, { () -> String in built.append(.first); return "ひとつめ" }())
        #expect(built == [.first, .second])
        #expect(log.hasWarned(.first))
        #expect(log.hasWarned(.second))
    }

    @Test("頼んでいない注意は、言ったことになっていない")
    func doesNotClaimWarningsItNeverSaid() {
        var log = WarningLog<Key>()
        log.warnOnce(.first, "ひとつめ")
        #expect(!log.hasWarned(.second))
        #expect(log.message(for: .second) == nil)
    }

    @Test("控えた文面は、渡した文面そのもの")
    func keepsTheWordingItSaid() {
        var log = WarningLog<Key>()
        log.warnOnce(.first, "ひとつめ: 値は \(1 + 1) でした")
        #expect(log.message(for: .first) == "ひとつめ: 値は 2 でした")
    }

    @Test("2 度目の文面は控えを上書きしない")
    func keepsTheFirstWordingWhenAskedAgain() {
        var log = WarningLog<Key>()
        log.warnOnce(.first, "はじめの文面")
        log.warnOnce(.first, "あとの文面")
        #expect(log.message(for: .first) == "はじめの文面")
    }
}

/// 面が実際に通す経路で、注意が 1 度だけ・同じ文面で出るかを見る。GPU を要する。
///
/// 上の検査は控えの型だけを見るので、**呼び出し側が控えを通しているか**は分からない。
/// フレームの外で光と視点を書く経路は、どちらも描かずに済み、旗を畳む前から
/// 「初回だけ」で守られていた ([ADR-0021] 決定 4)。
@Suite(
    "面が言う注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CanvasWarningTests {
    /// 畳む前に `Diagnostics.warn` へ渡していた文面。**原文は `outsideFrameNotices`
    /// が 7 つまとめて持つ** ので、ここでは引くだけにする (写しを 2 つ持たない)。
    private let lightOutsideFrame = outsideFrameNotices[.light]!
    private let cameraOutsideFrame = outsideFrameNotices[.camera]!
    /// 同じく `Canvas+Material.swift` の文面。**呼んだ関数の名前が入る。**
    private let badShininess =
        "shininess(): got a value that is not a number, or an infinite one, or one outside "
            + "the range, so the material was left as it was"

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    @Test("フレームの外で光を置くと、原文のまま知らせる")
    func warnsAboutLightsOutsideTheFrame() throws {
        let canvas = try makeCanvas()
        #expect(!canvas.warnings.hasWarned(.lightOutsideFrame))

        canvas.ambientLight(.linear(red: 1, green: 1, blue: 1))
        #expect(canvas.warnings.hasWarned(.lightOutsideFrame))
        #expect(canvas.warnings.message(for: .lightOutsideFrame) == lightOutsideFrame)
        #expect(canvas.activeLights.isEmpty)
    }

    /// 2 度目に黙っているかを、**入口ごとに文面が変わる注意**で見る。
    ///
    /// `shininess()` と `metalness()` は同じ ``Canvas/Warning/badMaterial`` を言い、
    /// 文面には呼んだ関数の名前が入る。2 度目も言っていれば、控えの文面が
    /// `metalness()` に入れ替わる — 同じ文面の注意を 2 度呼ぶ形では、これが見えない。
    @Test("同じ注意は、入口が違っても 2 度目からは黙る")
    func staysSilentTheSecondTimeEvenFromAnotherEntrance() throws {
        let canvas = try makeCanvas()
        canvas.shininess(Float.nan)
        #expect(canvas.warnings.message(for: .badMaterial) == badShininess)

        canvas.metalness(Float.nan)
        #expect(canvas.warnings.message(for: .badMaterial) == badShininess)
    }

    @Test("光の注意は、視点の注意を黙らせない")
    func oneWarningDoesNotSilenceAnother() throws {
        let canvas = try makeCanvas()
        canvas.ambientLight(.linear(red: 1, green: 1, blue: 1))
        #expect(!canvas.warnings.hasWarned(.cameraOutsideFrame))

        canvas.camera()
        #expect(canvas.warnings.hasWarned(.cameraOutsideFrame))
        #expect(canvas.warnings.message(for: .cameraOutsideFrame) == cameraOutsideFrame)
        // 先に言った側も残っている (鍵が食い合っていない)
        #expect(canvas.warnings.message(for: .lightOutsideFrame) == lightOutsideFrame)
    }

    @Test("面ごとに別々に数える")
    func countsPerCanvas() throws {
        let first = try makeCanvas()
        let second = try makeCanvas()
        first.ambientLight(.linear(red: 1, green: 1, blue: 1))
        #expect(first.warnings.hasWarned(.lightOutsideFrame))
        #expect(!second.warnings.hasWarned(.lightOutsideFrame))
    }
}

/// `beginShape()` の外で呼べる、頂点の仲間の入口。`vertex` は 4 つの形を別々に数える。
///
/// `endContour` と `normal` は #1520 で加わった。直す前は、形の外では注意なしで黙っていた
/// (`normal` は向きを控え、次の `beginShape()` が消していた)。
enum OutsideShapeCall: CaseIterable {
    case vertex
    case vertexWithDepth
    case vertexWithUV
    case vertexWithDepthAndUV
    case bezierVertex
    case quadraticVertex
    case curveVertex
    case beginContour
    case endContour
    case normal
    case index

    /// 形の中で呼べば、点を置くか・穴を始めるか・穴を閉じるか・向きを控えるか・番号を積む
    /// 呼び出し。
    func call(on canvas: Canvas) {
        switch self {
        case .vertex: canvas.vertex(4, 4)
        case .vertexWithDepth: canvas.vertex(4, 4, 1)
        case .vertexWithUV: canvas.vertex(4, 4, 0.5, 0.5)
        case .vertexWithDepthAndUV: canvas.vertex(4, 4, 1, 0.5, 0.5)
        case .bezierVertex: canvas.bezierVertex(4, 12, 8, 14, 12, 12)
        case .quadraticVertex: canvas.quadraticVertex(6, 14, 12, 12)
        case .curveVertex: canvas.curveVertex(4, 4)
        case .beginContour: canvas.beginContour()
        case .endContour: canvas.endContour()
        case .normal: canvas.normal(0, 0, 1)
        case .index: canvas.index(0)
        }
    }

    /// 形の外で呼んだときの原文 (`Canvas+Vertices.swift`)。**呼んだ関数の名前が入り、理由の
    /// 部分は入口によらない** ([#1498])。直す前はどの入口も `vertex():` を名乗っていた。
    ///
    /// `CurveContinuation/notice` と同じく、文の骨組みから組み立てず全文を写す。`vertex` の
    /// 文面は #1498 の前から変えていない側で、4 つの形が同じ原文を持つ。
    ///
    /// [#1498]: https://github.com/mokume-metal/mokume/issues/1498
    var notice: String {
        switch self {
        case .vertex, .vertexWithDepth, .vertexWithUV, .vertexWithDepthAndUV:
            "vertex(): call this between beginShape() and endShape(). This call does nothing"
        case .bezierVertex:
            "bezierVertex(): call this between beginShape() and endShape(). This call does nothing"
        case .quadraticVertex:
            "quadraticVertex(): call this between beginShape() and endShape(). This call does "
                + "nothing"
        case .curveVertex:
            "curveVertex(): call this between beginShape() and endShape(). This call does nothing"
        case .beginContour:
            "beginContour(): call this between beginShape() and endShape(). This call does nothing"
        case .endContour:
            "endContour(): call this between beginShape() and endShape(). This call does nothing"
        case .normal:
            "normal(): call this between beginShape() and endShape(). This call does nothing"
        case .index:
            "index(): call this between beginShape() and endShape(). This call does nothing"
        }
    }
}

/// 手前の点から曲線を続ける 2 つの入口。
enum CurveContinuation: CaseIterable {
    case bezier
    case quadratic

    /// 手前に点があれば、そこから (12, 12) まで曲線を引く呼び出し。
    func call(on canvas: Canvas) {
        switch self {
        case .bezier: canvas.bezierVertex(4, 12, 8, 14, 12, 12)
        case .quadratic: canvas.quadraticVertex(6, 14, 12, 12)
        }
    }

    /// 形の中で手前に点が無いときの原文。**呼んだ関数の名前が入る** — 文の骨組みから
    /// 組み立てず、2 通りとも写す (実装と同じ組み立てを検査が持つと、両方が揃って
    /// 間違えても通ってしまう)。
    var notice: String {
        switch self {
        case .bezier:
            "bezierVertex(): a curve continues from the last point placed, and there is no point "
                + "yet in this shape or beginContour() hole, so this call does nothing. Place a "
                + "vertex() first"
        case .quadratic:
            "quadraticVertex(): a curve continues from the last point placed, and there is no "
                + "point yet in this shape or beginContour() hole, so this call does nothing. "
                + "Place a vertex() first"
        }
    }

    /// 形の外で呼んだときの原文。形の外の入口の一覧 (``OutsideShapeCall``) から引き、写しを
    /// 2 つ持たない。
    var outsideNotice: String {
        switch self {
        case .bezier: OutsideShapeCall.bezierVertex.notice
        case .quadratic: OutsideShapeCall.quadraticVertex.notice
        }
    }
}

/// 形の中で手前に点が無いまま曲線を続けたときの注意 ([#1485])。GPU を要する。
///
/// 直す前は、形の外で呼んだときと同じ `vertex(): call this between beginShape() and
/// endShape()…` を言っていた。呼んだ場所は既にその間なので、書き手は `beginShape` の
/// 位置を探しに行ってしまう。**何もしない振る舞いは直す前から約束どおり**で、直したのは
/// 注意の文面と鍵だけである。
///
/// [#1485]: https://github.com/mokume-metal/mokume/issues/1485
@Suite(
    "手前に点が無い曲線の注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CurveWithoutStartWarningTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    @Test(
        "形の中で手前に点が無ければ、呼んだ関数の名前で「手前に点が無い」と言う",
        arguments: CurveContinuation.allCases)
    func namesTheCallAndTheMissingStart(_ curve: CurveContinuation) throws {
        let canvas = try makeCanvas()
        var placed: Int?
        try canvas.draw {
            canvas.beginShape()
            curve.call(on: canvas)
            placed = canvas.shapePoints.count
            canvas.endShape()
        }
        #expect(canvas.warnings.message(for: .curveWithoutStart) == curve.notice)
        #expect(!canvas.warnings.hasWarned(.vertexOutsideShape), "形の中なのに、形の外の注意を言った")
        #expect(placed == 0, "手前に点が無いのに点を置いた")
    }

    /// 穴は外周の点から始めない (#1449) ので、穴の最初も「手前に点が無い」に当たる。
    @Test("穴の最初で呼んでも、同じ注意を言う", arguments: CurveContinuation.allCases)
    func saysTheSameAtTheStartOfAHole(_ curve: CurveContinuation) throws {
        let canvas = try makeCanvas()
        var placedInHole: Int?
        try canvas.draw {
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(16, 0)
            canvas.vertex(16, 16)
            canvas.beginContour()
            curve.call(on: canvas)
            placedInHole = canvas.holePoints?.count
            canvas.endContour()
            canvas.endShape(.close)
        }
        #expect(canvas.warnings.message(for: .curveWithoutStart) == curve.notice)
        #expect(!canvas.warnings.hasWarned(.vertexOutsideShape), "形の中なのに、形の外の注意を言った")
        #expect(placedInHole == 0, "穴の最初の \(curve) が穴に点を置いた")
    }

    /// 文面は #1498 で呼んだ関数の名前を名乗るようになった。ここが見るのは、形の外では
    /// 手前の点の注意ではなく形の外の注意のほうを言うことである。
    @Test(
        "形の外で呼べば、形の外の注意を言い、点を置かない",
        arguments: CurveContinuation.allCases)
    func keepsTheOutsideNoticeOutsideAShape(_ curve: CurveContinuation) throws {
        let canvas = try makeCanvas()
        var placed: Int?
        try canvas.draw {
            curve.call(on: canvas)
            placed = canvas.shapePoints.count
        }
        #expect(canvas.warnings.message(for: .vertexOutsideShape) == curve.outsideNotice)
        #expect(!canvas.warnings.hasWarned(.curveWithoutStart), "形の外なのに、手前の点の注意を言った")
        #expect(placed == 0, "形の外なのに点を置いた")
    }

    /// 鍵を取り違えると、先に言った側が後の側を黙らせる。順番を入れ替えて両方の向きを見る。
    @Test("形の外の注意と手前の点の注意は、互いに黙らせない", arguments: [true, false])
    func theTwoNoticesDoNotSilenceEachOther(outsideFirst: Bool) throws {
        let canvas = try makeCanvas()
        func callOutside() { CurveContinuation.bezier.call(on: canvas) }
        func callWithoutStart() {
            canvas.beginShape()
            CurveContinuation.bezier.call(on: canvas)
            canvas.endShape()
        }
        try canvas.draw {
            if outsideFirst {
                callOutside()
                callWithoutStart()
            } else {
                callWithoutStart()
                callOutside()
            }
        }
        #expect(
            canvas.warnings.message(for: .vertexOutsideShape)
                == CurveContinuation.bezier.outsideNotice)
        #expect(
            canvas.warnings.message(for: .curveWithoutStart) == CurveContinuation.bezier.notice)
    }

    /// `badMaterial` の検査と同じく、**入口ごとに文面が変わる注意**で 2 度目を見る。2 度目も
    /// 言っていれば、控えの文面が後から呼んだ関数の名前に入れ替わる。
    @Test("入口が違っても、2 度目からは黙る")
    func staysSilentTheSecondTimeEvenFromTheOtherEntrance() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.beginShape()
            CurveContinuation.quadratic.call(on: canvas)
            CurveContinuation.bezier.call(on: canvas)
            canvas.endShape()
        }
        #expect(
            canvas.warnings.message(for: .curveWithoutStart) == CurveContinuation.quadratic.notice)
    }
}

/// 形の外で頂点の仲間を呼んだときの注意 ([#1498])。GPU を要する。
///
/// 直す前は、どの入口で呼んでも `vertex(): call this between beginShape() and endShape()…`
/// を言っていた。理由は正しいが名乗る関数が違うので、書き手は呼んでいない `vertex()` を
/// 探しに行ってしまう。**何もしない振る舞いは直す前から約束どおり**で、直したのは注意が
/// 名乗る関数の名前だけである。鍵は入口のすべてで共有したまま動かさない。
///
/// [#1498]: https://github.com/mokume-metal/mokume/issues/1498
@Suite(
    "形の外で呼んだ頂点の仲間の注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct VertexOutsideShapeWarningTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    @Test(
        "形の外で呼べば、呼んだ関数の名前で注意を言い、何もしない",
        arguments: OutsideShapeCall.allCases)
    func namesTheCallOutsideAShape(_ call: OutsideShapeCall) throws {
        let canvas = try makeCanvas()
        var points: Int?
        var indices: Int?
        var holeStarted: Bool?
        var guides: Int?
        var building: Bool?
        var normalWritten: Bool?
        try canvas.draw {
            call.call(on: canvas)
            points = canvas.shapePoints.count
            indices = canvas.shapeIndices.count
            holeStarted = canvas.holePoints != nil
            guides = canvas.curveGuides.count
            building = canvas.isBuildingShape
            normalWritten = canvas.currentNormal != nil
        }
        #expect(canvas.warnings.message(for: .vertexOutsideShape) == call.notice)
        #expect(!canvas.warnings.hasWarned(.curveWithoutStart), "形の外なのに、手前の点の注意を言った")
        #expect(points == 0, "形の外の \(call) が点を置いた")
        #expect(indices == 0, "形の外の \(call) が番号を積んだ")
        #expect(holeStarted == false, "形の外の \(call) が穴を始めた")
        #expect(guides == 0, "形の外の \(call) が通過点を溜めた")
        #expect(building == false, "形の外の \(call) が形を始めた")
        // 控えた向きは次の beginShape() が消すので、どの頂点にも効かない (#1520)
        #expect(normalWritten == false, "形の外の \(call) が向きを控えた")
    }

    /// 鍵は入口のすべてで 1 つ。**入口ごとに文面が変わる**ので、2 度目も言っていれば控えの
    /// 文面が後から呼んだ関数の名前に入れ替わる (`badMaterial` の検査と同じ見方)。
    @Test("入口が違っても、2 度目からは黙る")
    func staysSilentTheSecondTimeEvenFromAnotherEntrance() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            OutsideShapeCall.index.call(on: canvas)
            OutsideShapeCall.vertex.call(on: canvas)
        }
        #expect(
            canvas.warnings.message(for: .vertexOutsideShape) == OutsideShapeCall.index.notice)
    }

    /// #1520 で加わった入口も、同じ鍵を言う。先に言っていれば、後の `vertex` は黙る。
    @Test(
        "加わった入口の後でも、2 度目からは黙る",
        arguments: [OutsideShapeCall.normal, .endContour])
    func staysSilentAfterTheAddedEntrances(_ call: OutsideShapeCall) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            call.call(on: canvas)
            OutsideShapeCall.vertex.call(on: canvas)
        }
        #expect(canvas.warnings.message(for: .vertexOutsideShape) == call.notice)
    }
}

/// 形の外で `endShape()` を呼んだときの原文 ([#1520])。
///
/// [#1520]: https://github.com/mokume-metal/mokume/issues/1520
private let shapeNotBegunNotice =
    "endShape(): no shape was begun with beginShape(), so there is nothing to end. This call "
    + "does nothing"

/// 形の中で、穴を開かずに `endContour()` を呼んだときの原文 ([#1528])。
///
/// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
private let contourNotBegunNotice =
    "endContour(): no hole was begun with beginContour(), so there is nothing to end. This call "
    + "does nothing"

/// 形の中で、向きにならない値を `normal()` に渡したときの原文 ([#1528])。
///
/// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
private let badNormalNotice =
    "normal(): got a direction that is not a number, or an infinite one, or one with no length, "
    + "so the vertices placed after this take their facing from the shape, as if no normal() had "
    + "been written"

/// 形の始まりが無いまま `endShape()` を呼んだときの注意 ([#1520])。GPU を要する。
///
/// 直す前は注意なしで黙って返っていた。**何もしない振る舞いは直す前のまま**で、足したのは
/// 注意だけである。鍵を ``Canvas/Warning/vertexOutsideShape`` と分けるのは、あちらの文面
/// (`beginShape()` と `endShape()` の間で呼べ) が `endShape()` には直す先を指さないため。
///
/// [#1520]: https://github.com/mokume-metal/mokume/issues/1520
@Suite(
    "形の始まりが無い endShape() の注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapeNotBegunWarningTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    @Test("一度も beginShape() を呼ばずに endShape() を呼ぶと、endShape() を名乗って注意する")
    func warnsWhenNoShapeWasBegun() throws {
        let canvas = try makeCanvas()
        try canvas.draw { canvas.endShape() }
        #expect(canvas.warnings.message(for: .shapeNotBegun) == shapeNotBegunNotice)
        #expect(!canvas.warnings.hasWarned(.vertexOutsideShape), "形の外の頂点の注意を言った")
    }

    @Test("形を閉じた直後にもう一度 endShape() を呼ぶと、2 度目で注意する")
    func warnsOnTheSecondEndShape() throws {
        let canvas = try makeCanvas()
        var warnedAfterFirst: Bool?
        try canvas.draw {
            canvas.beginShape()
            canvas.vertex(2, 2)
            canvas.vertex(14, 2)
            canvas.vertex(8, 14)
            canvas.endShape(.close)
            warnedAfterFirst = canvas.warnings.hasWarned(.shapeNotBegun)
            canvas.endShape(.close)
        }
        #expect(warnedAfterFirst == false, "対になった endShape() で注意した")
        #expect(canvas.warnings.message(for: .shapeNotBegun) == shapeNotBegunNotice)
    }

    /// 鍵を取り違えると、先に言った側が後の側を黙らせる。順番を入れ替えて両方の向きを見る。
    @Test("形の外の頂点の注意とは、互いに黙らせない", arguments: [true, false])
    func theTwoNoticesDoNotSilenceEachOther(endShapeFirst: Bool) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            if endShapeFirst {
                canvas.endShape()
                OutsideShapeCall.vertex.call(on: canvas)
            } else {
                OutsideShapeCall.vertex.call(on: canvas)
                canvas.endShape()
            }
        }
        #expect(canvas.warnings.message(for: .shapeNotBegun) == shapeNotBegunNotice)
        #expect(
            canvas.warnings.message(for: .vertexOutsideShape) == OutsideShapeCall.vertex.notice)
    }
}

/// 形の中で、頂点の口を誤って呼んだときの注意 ([#1528])。GPU を要する。
///
/// 直す前は、穴を開かずに呼んだ `endContour()` と、向きにならない値を渡した `normal()` が
/// 注意なしで黙っていた。**振る舞い (何もしない・書かれていない向きに倒す) は直す前のまま**
/// で、足したのは注意だけである。
///
/// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
@Suite(
    "形の中で誤って呼んだ頂点の口の注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct InsideShapeMisuseWarningTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    /// 穴を 1 つ閉じた後にもう一度閉じる場面も見る。閉じた後は「開いた穴が無い」ので、
    /// 最初から開いていない場面と同じ注意になる。
    @Test("穴を開かずに endContour() を呼ぶと注意し、穴を増やさない", arguments: [false, true])
    func warnsAboutEndContourWithoutAHole(afterClosingOne: Bool) throws {
        let canvas = try makeCanvas()
        var holesBefore: Int?
        var holesAfter: Int?
        var pointsBefore: Int?
        var pointsAfter: Int?
        try canvas.draw {
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(16, 0)
            canvas.vertex(16, 16)
            canvas.vertex(0, 16)
            if afterClosingOne {
                canvas.beginContour()
                canvas.vertex(4, 4)
                canvas.vertex(4, 12)
                canvas.vertex(12, 8)
                canvas.endContour()
            }
            holesBefore = canvas.shapeHoles.count
            pointsBefore = canvas.shapePoints.count
            canvas.endContour()
            holesAfter = canvas.shapeHoles.count
            pointsAfter = canvas.shapePoints.count
            canvas.endShape(.close)
        }
        #expect(canvas.warnings.message(for: .contourNotBegun) == contourNotBegunNotice)
        #expect(!canvas.warnings.hasWarned(.vertexOutsideShape), "形の中なのに、形の外の注意を言った")
        #expect(holesAfter == holesBefore, "閉じる穴が無いのに穴が増えた")
        #expect(pointsAfter == pointsBefore, "閉じる穴が無いのに外周が変わった")
    }

    @Test(
        "向きにならない値を normal() に渡すと注意し、書かれていない向きに倒す",
        arguments: [SIMD3<Float>(.nan, 0, 1), SIMD3<Float>(0, 0, 0), SIMD3<Float>(.infinity, 0, 1)])
    func warnsAboutADirectionThatIsNotOne(_ direction: SIMD3<Float>) throws {
        let canvas = try makeCanvas()
        var written: SIMD3<Float>?
        try canvas.draw {
            canvas.beginShape()
            canvas.normal(0, 0, 1)
            canvas.normal(direction.x, direction.y, direction.z)
            written = canvas.currentNormal
            canvas.endShape()
        }
        #expect(canvas.warnings.message(for: .badNormal) == badNormalNotice)
        #expect(!canvas.warnings.hasWarned(.vertexOutsideShape), "形の中なのに、形の外の注意を言った")
        #expect(written == nil, "向きにならない値の後も、向きが書かれたまま")
    }

    /// 同じ入口 (`endContour` / `normal`) が形の外では ``Canvas/Warning/vertexOutsideShape`` を
    /// 言う。鍵を取り違えると、先に言った側が後の側を黙らせる。順番を入れ替えて両方の向きを見る。
    @Test(
        "形の外の注意と形の中の注意は、同じ入口でも互いに黙らせない",
        arguments: [OutsideShapeCall.endContour, .normal], [true, false])
    func insideAndOutsideDoNotSilenceEachOther(
        _ call: OutsideShapeCall, outsideFirst: Bool
    ) throws {
        let canvas = try makeCanvas()
        func callInside() {
            canvas.beginShape()
            canvas.vertex(0, 0)
            switch call {
            case .normal: canvas.normal(Float.nan, 0, 1)
            default: canvas.endContour()
            }
            canvas.vertex(16, 0)
            canvas.vertex(16, 16)
            canvas.endShape(.close)
        }
        try canvas.draw {
            if outsideFirst {
                call.call(on: canvas)
                callInside()
            } else {
                callInside()
                call.call(on: canvas)
            }
        }
        #expect(canvas.warnings.message(for: .vertexOutsideShape) == call.notice)
        switch call {
        case .normal: #expect(canvas.warnings.message(for: .badNormal) == badNormalNotice)
        default: #expect(canvas.warnings.message(for: .contourNotBegun) == contourNotBegunNotice)
        }
    }
}

/// 形の中の正しい使い方では、#1520 / #1528 で足した注意をどれも言わない。GPU を要する。
///
/// 閉じ忘れた穴を畳むのは ``Canvas/endShape(_:)`` の約束で、中で穴を畳む道は公開の
/// ``Canvas/endContour()`` と分けてある。同じ道を通すと、穴を閉じた形・穴の無い形の
/// `endShape()` が「閉じる穴が無い」を言う。
@Suite(
    "正しく並べた形の注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct WellFormedShapeWarningTests {
    enum Ending: CaseIterable {
        /// 穴を開いて `endContour()` で閉じる。
        case closedHole
        /// 穴を開いたまま、`endShape()` に畳ませる。
        case openHole
        /// 穴を開かない。
        case noHole
    }

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    @Test("向きを書いて並べ、どの閉じ方でも注意を増やさない", arguments: Ending.allCases)
    func saysNothing(_ ending: Ending) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.beginShape()
            canvas.normal(0, 0, 1)
            canvas.vertex(0, 0)
            canvas.vertex(16, 0)
            canvas.vertex(16, 16)
            canvas.vertex(0, 16)
            if ending != .noHole {
                canvas.beginContour()
                canvas.vertex(4, 4)
                canvas.vertex(4, 12)
                canvas.vertex(12, 8)
                if ending == .closedHole { canvas.endContour() }
            }
            canvas.endShape(.close)
        }
        for key in [
            Canvas.Warning.vertexOutsideShape, .shapeNotBegun, .contourNotBegun, .badNormal,
        ] {
            #expect(!canvas.warnings.hasWarned(key), "\(ending) の形で \(key) を言った")
        }
    }
}
