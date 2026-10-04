// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 形の組み立て (`createShape { }`) の出口で、状態をどう扱うか ([#1684])。
///
/// 組み立ては入口で状態を写し取り、出口で戻す。**戻す一覧は手で並べてあり**、漏れが見つかる
/// たびに 1 つずつ足されてきた (#836 の断片と数の並び・#1172 の積み履歴・#1607 の組み立て中の
/// 形)。一覧の外にあった状態は、描き方なら外へ漏れ (#1646 の曲線の細かさ)、形に焼き付かない
/// ものなら黙って消えるかフレームに効いていた (#1529 の切り抜き・光)。フレームの境目で同じ形を
/// 塞いだ ``CanvasTests/everyStoredPropertyIsClassified()`` (#1671) と同じく、**`Canvas` の格納と
/// `Style` のフィールドを 1 つ残らずここで分ける。** 格納を 1 つ足したら、ここで止まる。
///
/// [#1684]: https://github.com/mokume-metal/mokume/issues/1684
enum ShapeExit {
    /// 出口で組み立て前の値へ戻す。**形には焼き付く**描き方と、形自身の座標で記録するために
    /// 畳む変換。手順は組み立ての中でその状態を汚す
    case restore((Canvas, ShapeExitFixture) -> Void)
    /// 入口で切り離し、出口で組み立て前へ戻す。積み履歴・組み立て中の形は記録の中で閉じ、溜め場は
    /// 記録したぶんを形として抜く
    case detach
    /// 組み立ての中では断る (注意して、何も変えない)。形に焼き付く先が無いもの (#1529・#1588)。
    /// 口ごとに回すのは `SceneOutsideFrameTests` と `ShapeTests` の組み立ての中の検査。
    ///
    /// 手順はフレームの中 (組み立ての外) でその状態を汚す。**出口が書き戻さないこと**を、
    /// 組み立ての中でフレームを閉じて確かめる (``ShapeExitTests/refusedStateIsNotWrittenBackAcrossAFrameEnd()``)。
    /// 閉じる側 (`abandonFrame()`) が既定へ戻すものには手順を書く。`Style` のフィールドには必須
    /// — 出口は `Style` を写して戻すので、写しから外し忘れるとそこで書き戻す
    case refuse(((Canvas, ShapeExitFixture) -> Void)?)
    /// 出入口では扱わない。理由を書く
    case untouched(String)

    /// 組み立ての中で汚すのに使う道具。
    struct Fixture {
        let sheet: Image
        let shader: Shader
        let numbers: Numbers
    }

    /// 分類の表。名前は `Canvas` の格納の名前、`style.` で始まるものは ``Canvas/Style`` の
    /// フィールド、ほかに `.` を含むものは格納の中に降りる道 (``nestedReaders`` が読み方を持つ)。
    ///
    /// **「戻す」は上から順に汚す。** 揺らぎの設定は先頭に置く — 記録の中で何か積んだ後に書き
    /// 換えると、組み立ての途中の面を描き切らせる経路 (#1855) に入る。塗り・線は、外す口
    /// (`noFill()` / `noStroke()`) より先に色を書く (色を書く口は外した印を戻す)。読む面は、輪郭を
    /// 外してから貼る絵で置いて替える。
    static var table: [(name: String, exit: ShapeExit)] {
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        let restored: [(String, (Canvas, Fixture) -> Void)] = [
            ("noiseStore", { c, _ in
                c.noiseSeed(7)
                c.noiseDetail(2, 0.3)
            }),
            ("currentCurveDetail", { c, _ in c.curveDetail(2) }),
            ("currentCurveTightness", { c, _ in c.curveTightness(1) }),
            ("transform", { c, _ in c.translate(5, 5) }),
            ("currentShader", { c, f in c.shader(f.shader) }),
            ("currentNumbers", { c, f in c.numbers(f.numbers) }),
            ("style.fill", { c, _ in c.fill(red) }),
            ("style.stroke", { c, _ in c.stroke(red) }),
            ("style.strokeWeight", { c, _ in c.strokeWeight(7) }),
            ("style.strokeCap", { c, _ in c.strokeCap(.square) }),
            ("style.strokeJoin", { c, _ in c.strokeJoin(.bevel) }),
            ("style.rectMode", { c, _ in c.rectMode(.center) }),
            ("style.ellipseMode", { c, _ in c.ellipseMode(.corner) }),
            ("style.blendMode", { c, _ in c.blendMode(.add) }),
            ("style.fontName", { c, _ in c.textFont("Helvetica") }),
            ("style.textSize", { c, _ in c.textSize(30) }),
            ("style.textStyle", { c, _ in c.textStyle(.bold) }),
            ("style.horizontalTextAlign", { c, _ in c.textAlign(.right, .top) }),
            ("style.verticalTextAlign", { c, _ in c.textAlign(.right, .top) }),
            ("style.textLeading", { c, _ in c.textLeading(40) }),
            ("style.textWrap", { c, _ in c.textWrap(.character) }),
            ("style.imageMode", { c, _ in c.imageMode(.center) }),
            ("style.tint", { c, _ in c.tint(red) }),
            ("style.picture", { c, f in c.texture(f.sheet) }),
            // 貼る絵で輪郭なしの 1 つを置くと、読む面が替わる (輪郭は焼き場の面へ戻す)
            ("style.hasStroke", { c, _ in c.noStroke() }),
            ("currentTexture", { c, _ in c.rect(0, 0, 3, 3) }),
            ("style.hasFill", { c, _ in c.noFill() }),
        ]
        let detached = [
            "transformStack", "styleStack", "recordingShape",
            // 組み立て中の形 (#1607)。``CanvasTests/shapeState`` と同じ群
            "isBuildingShape", "shapeKind", "currentNormal", "shapePoints", "shapeHasDepth",
            "shapeIndices", "shapeHoles", "holePoints", "curveGuides",
            // 溜め場。記録したぶんを形として抜き、組み立て前の長さへ戻す
            "vertices", "solidVertices", "solidIndices", "formInstances", "solidInstances", "batches",
            "recordedStrokeRanges", "recordedFillRanges", "recordedSolidStrokes", "recordedGPUStrokes",
            // 平面の頂点ごとの被覆の区間 (#1637)。溜め場の頂点と対で切り詰める
            "coverageSpans",
        ]
        let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        let refused: [(String, ((Canvas, Fixture) -> Void)?)] = [
            // シーンの記述 (#1529)。閉じる側が既定へ戻すものは汚す手順を持つ
            ("cameraStorage", { c, _ in c.perspective() }),
            ("activeLights", { c, _ in c.ambientLight(white) }),
            ("activeSurroundings", { c, _ in c.surroundings(.sky) }),
            ("shadowsEnabled", { c, _ in c.shadows(true) }),
            ("shadowRangeValue", { c, _ in c.shadowRange(50) }),
            ("shadowDetailValue", { c, _ in c.shadowDetail(512) }),
            ("shadowBiasValue", { c, _ in c.shadowBias(0.5) }),
            ("pendingEffects", nil), ("pendingComputations", nil), ("forcesThisFrame", nil),
            ("style.clip", { c, _ in c.clip(1, 2, 3, 4) }),
            ("style.material", { c, _ in c.shininess(50) }),
            ("style.castsShadow", { c, _ in c.castShadow(false) }),
            ("style.receivesShadow", { c, _ in c.receiveShadow(false) }),
            // 露出と明るさの丸め方。面全体に効き、形には焼き付かない (#1529 の条件 3)
            ("target.brightness", nil),
            // 塗り直しと画素の口 (#1588)
            ("pendingBackground", nil), ("hasLoadedPixels", nil),
            ("target.pixelMirror.hasPendingWrites", nil),
        ]
        let construction = "面を作ったときに決まり、面と同じだけ生きる"
        let resource = "資源 (置き場・パイプライン)。中身は描くものではない"
        let cache = "控え。中身は入力で決まり、組み立てとは関わらない"
        let count = "計数。数で確かめる検査が読む"
        let testing = "検査の差し込み・上限。製品の経路では既定のまま"
        let flush = "描き切りの印。組み立ての中で描き切るのは面を描き切る 3 経路だけで、出口の安全網 (空の形と注意) が扱う (#1855)"
        let frame = "フレームの内外と境目の印。境目の関数だけが書く"
        let transient = "呼び出しの中でだけ立ち、抜ける前に戻る一時の値"
        let unused = "記録の間は使わない (組み込みの立体は置き場所ごとに頂点へ焼き、平面は畳まない)"
        let untouched: [String: String] = [
            "width": construction, "height": construction,
            "target": "\(construction)。中の露出と明るさの丸め方 (target.brightness) は断る",
            "output": construction, "upscaleStage": construction, "gpu": construction,
            "frameRing": construction, "pipeline": construction, "projection": construction,
            "atlas": construction, "timebase": "時刻と刻み。ランタイムが進める",
            "vertexStorage": resource, "flatInstanceStorage": resource,
            "formInstanceStorage": resource, "solidVertexStorage": resource,
            "solidIndexStorage": resource, "solidInstanceStorage": resource,
            "lightStorageBuffer": resource, "lightingStorage": resource, "materialStorage": resource,
            "surroundingsStorage": resource, "shadowMatrixStorage": resource,
            "blendModeBuffer": resource, "glyphPageBuffer": resource, "uniformsStorage": resource,
            "valuesStorage": resource, "matrixStorage": resource, "computeValuesStorage": resource,
            "uploadStorage": resource, "effectPipelineStorage": resource,
            "imageInputPass": resource, "imageInputUnavailable": resource,
            "computePipelineStorage": resource, "unbakedShadowTexture": resource,
            "emptyNumbers": resource, "blankPicture": resource, "shadowMap": resource,
            "whiteUV": "焼き場の白い区画の位置。面を広げたときだけ変わる",
            "imageCache": cache, "modelCache": cache, "solidMeshes": cache, "solidEdges": cache,
            "typefaces": cache, "solidStrokeGeometry": cache, "modelFills": cache,
            "lastShadowBakeKey": cache, "discOffsets": cache,
            "ringSplitMemo": "分割数の直前の問い合わせ 1 件。中身は入力で決まり、組み立てとは関わらない (#1645)",
            "discSplitMemo": "ringSplitMemo と同じ",
            "atlasPageFrame": "焼き場の頁を作ったフレームの番号。番号どうしで比べる",
            "retainedSerial": "保持した形を置くたびの通し番号。組み立ての中で置いた形も数える",
            "pendingDiscards": "溜め場を捨てた通し番号。出口が入口と比べ、捨てていたら空の形を返す (#1588)",
            "framesDrawn": frame, "isDrawing": frame, "beginDrawFrame": frame,
            "droppedAtTheMainFrame": frame,
            "carriesOver": "持ち越しの区間の印。ランタイムがコールバックの出入口で対で書く (#1672)",
            "carriedOverAmount": "持ち越しの区間で置いた量の印。フレームの頭の検めが読む (#1672)",
            "shadowMapsBuilt": count,
            "shadowBarriersEncoded": count, "shadowBakesEncoded": count, "shadowBakesReused": count,
            "drawsEncodedInLastFrame": count,
            "spheresFromUnit": count,
            "effectCarriesEncoded": count, "effectCarryRestoresEncoded": count,
            "effectChangesKeptEncoded": count, "effectCarryDrawsEncoded": count,
            "depthLoadsEncoded": count, "depthStoresEncoded": count,
            "effectBarriersEncoded": count, "effectPassesEncoded": count,
            "computeEncodersOpened": count, "computeEncodersClosed": count,
            "earlySubmissionsAttempted": count, "earlySubmissionFailedFrame": count,
            "computeBarriersEncoded": count, "uploadBarriersEncoded": count,
            "lastComputeBarrierQueueStages": "最後に積んだ投入の最後の口が待たせる段 (#1687)。積むたびに上書きし、検査が読む。組み立ての中で書く口が無い",
            "glyphQuadsPlaced": count, "drawCallsInLastFrame": count,
            "flatVerticesInLastFrame": count, "flatOutlinesInLastFrame": count,
            "pointScansInLastFrame": count, "placedGraphicsDrops": count,
            "outlinesAssembledThisFrame": count, "pointScansThisFrame": count,
            "stagePassesUsed": count, "placementsFoundOutsideRegions": count,
            // #1637 (細い線を広げて被覆で運ぶ)
            "coverageStorage": resource, "thinStrokesRebuilt": count,
            "openBatchHasThinCoverage": "openSource と同じ (列を閉じるときに Batch.thinCoverage へ移して下ろす)",
            "solidStrokeCoverage": "立体の線を 1 本組む間だけ使う被覆。次の線を組む前に書き直す",
            "solidStrokeIsLonePoint": "立体の線を 1 本組む間だけ使う印。次の線を組む前に書き直す",
            "templateStrokeMatrix": "畳みの雛形を組む間だけ立つ。記録の間は畳まない (unused と同じ理由)",
            // #1656 (途中の描き切りの持ち越しと、置いた描き場所の写し)
            "frameCasters": flush, "casterSegmentsFree": resource,
            "placedPictureCopiesFree": resource, "placedPictureCopiesInUse": resource,
            "placedPictureEpoch": frame,
            "placedPictureCopiesMade": count, "placedPicturesCopied": count,
            "placedPictureCopyLimitReached": count, "shadowBakesAdded": count,
            "shadowMapHolds": count, "shadowRebakeBarriersEncoded": count,
            "shadowsEverEnabled": "影を 1 度でも有効にした面の印。面と同じだけ生き、組み立ての中の shadows() は断られるので立たない",
            "shaders": "この面が作った断片 (弱く持つ)。観測へ失敗を載せる",
            "effectShaders": "この面が作った効果 (弱く持つ)。観測へ失敗を載せる",
            "computations": "この面が作った計算 (弱く持つ)。観測へ失敗を載せる",
            "warnings": "言った注意の控え。組み立ての中で言った注意も残す",
            "passesThisFrame": flush, "depthIsHeld": flush, "pixelLoadFailed": flush,
            "carriesPictureBeforeEffects": flush, "targetChangedSinceUpscale": flush,
            "lightStorage": "光の置き場。記録の中で閉じた立体の列もいまの光を写すが、列ごと形へ抜くので読まれず、フレームの頭で空になる",
            "solidMeshRanges": unused, "flatInstances": unused, "pendingFlat": unused,
            "buildingFlatTemplate": unused,
            "openSource": "開いている列。入口と出口で閉じ (closeBatch)、記録の中で開いた列は形の区間になる",
            "openForm": "openSource と同じ", "openSolid": "openSource と同じ",
            "openFlat": "openSource と同じ",
            "placedGraphics": "置いた描き場所の記録。組み立ての中で置いた描き場所も、置いた時点の絵を守るために載る (#1588)",
            "placers": "自分を置いた面。自分の絵が変わる直前に相手を描き切らせる",
            "paintSurfacesNoted": "断片の面を置いた記録に載せ終えた控え。組み立ての中では控えない",
            "isFlushing": transient, "replayedPaint": transient,
            "solidStrokeCapture": transient,
            "stopsOnPlacementOutsideRegions": testing,
            "placesGlyphs": testing, "instanceCapacity": testing, "particleRoute": testing,
            "uploadByteLimit": testing, "failureForTesting": testing,
            "placesRetainedStrokesOnGPU": testing,
            "failEffectPassForTesting": testing, "failImageInputForTesting": testing,
            "failEarlySubmissionForTesting": testing,
        ]
        return restored.map { ($0.0, .restore($0.1)) }
            + detached.map { ($0, .detach) }
            + refused.map { ($0.0, .refuse($0.1)) }
            + untouched.map { ($0.key, .untouched($0.value)) }
    }

    /// 格納の中に降りる名前の読み方。
    static let nestedReaders: [String: (Canvas) -> String] = [
        "target.brightness": { String(describing: $0.target.brightness) },
        // 写しがまだ無いのは、書き込み待ちが無いのと同じ
        "target.pixelMirror.hasPendingWrites": {
            String(describing: $0.target.pixelMirror?.hasPendingWrites ?? false)
        },
    ]

    /// 格納そのものではなく中身を読む名前。揺らぎの置き場は参照で、綴りが中身を写さない。
    static let valueReaders: [String: (Canvas) -> String] = [
        "noiseStore": { String(describing: $0.noiseSettings) }
    ]

    /// 名前の分類だけを引く。
    static func names(_ matches: (ShapeExit) -> Bool) -> Set<String> {
        Set(table.filter { matches($0.exit) }.map(\.name))
    }

    static var restoredNames: Set<String> {
        names { if case .restore = $0 { true } else { false } }
    }
    static var detachedNames: Set<String> {
        names { if case .detach = $0 { true } else { false } }
    }
    static var refusedNames: Set<String> {
        names { if case .refuse = $0 { true } else { false } }
    }

    /// 渡した名前の綴り。**同じ面の上で比べる** (``CanvasTests`` の綴りと同じ)。
    static func fingerprint(of canvas: Canvas, _ names: Set<String>) -> [String: String] {
        var prints: [String: String] = [:]
        for child in Mirror(reflecting: canvas).children {
            guard let label = child.label, names.contains(label) else { continue }
            prints[label] = valueReaders[label]?(canvas) ?? String(describing: child.value)
        }
        for child in Mirror(reflecting: canvas.style).children {
            guard let label = child.label, names.contains("style.\(label)") else { continue }
            prints["style.\(label)"] = String(describing: child.value)
        }
        for (name, read) in nestedReaders where names.contains(name) { prints[name] = read(canvas) }
        return prints
    }
}

typealias ShapeExitFixture = ShapeExit.Fixture

/// `SketchRuntime` の格納の、組み立ての出口での扱い ([#1936])。
///
/// 組み立ての中で書けて形に焼き付く状態は、`Canvas` の外にもある — 乱数の列 (`randomSeed()`) で、
/// 持ち主はランタイムである。`Canvas` の表 (``ShapeExit/table``) は `Canvas` と `Style` の格納だけを
/// 数えるので、ランタイムの状態は別の表で分ける。分けは 2 つしかない — 戻すか、触らないか。
/// 切り離す・断るは `Canvas` の溜め場と、シーンの記述の口の話で、ランタイムには無い。
///
/// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
enum RuntimeExit {
    /// 出口で組み立て前の値へ戻す。手順は組み立ての中でその状態を汚し、読み方は綴りを返す
    case restore(dirty: (any Sketch) -> Void, read: (SketchRuntime) -> String)
    /// 出口では扱わない。理由を書く
    case untouched(String)
}

extension ShapeExit {
    /// ランタイムの格納の分類。名前は格納の名前 (`lazy var` は綴りの接頭辞を外した名前)。
    ///
    /// **「触らない」は、形に焼き付く値を生まないもの** — 実行の制御と時計・観測・保存と録り・
    /// 差込口・入力・視点の道具。組み立ての中で呼んでもそれぞれの持ち主の約束のままで、出口で戻すと
    /// かえって壊れる (中で呼んだ `noLoop()` を出口で戻すと、止めたつもりのスケッチが動き続ける)。
    static var runtimeTable: [(name: String, exit: RuntimeExit)] {
        let construction = "組み立てのときに決まり、ランタイムと同じだけ生きる"
        let control = "実行の制御と時計。形に焼き付く値を生まず、組み立ての中で呼んでも外の制御としてそのまま効く"
        let seam = "差込口の付け外しと巡回の印。形に焼き付く値を生まない (Sketch+Seams)"
        let recording = "保存と録り。形に焼き付く値を生まない (Sketch+Save)"
        let observation = "観測 (差し出した値・測った値)。形に焼き付く値を生まない (Sketch+Expose)"
        let untouched: [String: String] = [
            "sketch": construction, "canvas": construction, "declaredFrameRate": construction,
            "launchFrameRate": construction, "observer": construction, "inbox": construction,
            "relayed": construction, "params": construction, "paramRegistry": construction,
            "paramStore": construction,
            "input": "入力の合流点。窓と外から書かれ、形に焼き付く値を生まない",
            "timing": control, "now": control, "tempo": control, "firstAdvanceAt": control,
            "lastFrameAt": control, "drawnThrough": control, "isAdvancingFrame": control,
            "hasSetUp": control, "isPaused": control, "isLooping": control,
            "redrawRequested": control, "observingAtTime": control, "presence": control,
            "outlets": seam, "inlets": seam, "seamVisitDepth": seam, "deferredSeamChanges": seam,
            "seamsClosed": seam, "outletJoinedAt": seam,
            "recorder": recording, "closingRecorder": recording, "recordingFailed": recording,
            "pendingOutletFrame": recording, "warnedEncodeFailed": recording, "capture": recording,
            "exposedValues": observation, "measuredValues": observation,
            "orbit": "視点を操る道具の状態。フレームを越える。`orbit = …` の setter は組み立ての中でも断られず、出口でも戻らない。形には焼き付かない — 視点を書くのは `camera` で、`camera` は組み立ての中では断られる (`orbitControl()` は視点を書く前に断る・#1670)",
            "orbitAdvancedAt": "orbit と同じ (道具を最後に進めたフレーム)。`orbitControl()` が書く",
            "warnings": "ランタイムが 1 度だけ言った注意の控え (走っている最中の枚数の代入・#1323)。形に焼き付く値を生まない",
            "seedScopes":"組み立ての入れ子ごとの乱数と揺らぎの控え。入口で積み出口で畳む、出口の仕組みそのもの (#1936・#2041)",
        ]
        let restored: (String, RuntimeExit) = (
            "randomness",
            .restore(
                dirty: { $0.randomSeed(42) },
                // 綴りは `Randomness(state: …)` — 列のどこにいるかが分かる
                read: { String(describing: $0.randomness) })
        )
        return [restored] + untouched.map { ($0.key, .untouched($0.value)) }
    }
}

/// ランタイムを立てるためだけの、何も描かないスケッチ。
final class RuntimeBlank: Sketch {
    var settings = SketchSettings(width: 8, height: 8)
    init() {}
    func draw() {}
}

@Suite(
    "形の組み立ての出口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapeExitTests {
    private func makeCanvas(width: Int = 16, height: Int = 16) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    @Test("Canvas の格納と Style のフィールドは、組み立ての出口での扱いがどれか 1 つに決まっている")
    func everyStoredPropertyHasAnExit() throws {
        // 出入口で戻す状態は手で並べてあり、並べ落とした状態が 1 件ずつ見つかってきた (#836・
        // #1172・#1607・#1646・#1529)。**格納を 1 つ足したら、ここで止まる** — どこにも無い名前は、
        // 組み立ての中で書いたらどうなるかを誰も決めていない
        let canvas = try makeCanvas()
        let table = ShapeExit.table
        var seen: Set<String> = []
        for entry in table {
            #expect(seen.insert(entry.name).inserted, "\(entry.name) が表に 2 度載っている")
        }
        let labels = Mirror(reflecting: canvas).children.compactMap(\.label)
        for label in labels where label != "style" {
            #expect(
                seen.contains(label),
                "\(label) が組み立ての出口の表に無い。戻す・切り離す・断る・触らない (理由つき) のどれかに載せる")
        }
        let fields = Mirror(reflecting: canvas.style).children.compactMap(\.label)
        for field in fields {
            #expect(seen.contains("style.\(field)"), "style.\(field) が組み立ての出口の表に無い")
        }
        for name in seen {
            if name.hasPrefix("style.") {
                #expect(fields.contains(String(name.dropFirst(6))), "\(name) は Style に無い (表から消す)")
            } else if name.contains(".") {
                #expect(ShapeExit.nestedReaders[name] != nil, "\(name) の読み方が無い")
            } else {
                #expect(labels.contains(name), "\(name) は Canvas の格納に無い (表から消す)")
            }
        }
    }

    /// 組み立ての中で書ける状態は `Canvas` の外にもある — ランタイムが持つ乱数の列で、上の表が
    /// 数える `Canvas` の格納と `Style` には原理的に引っかからなかった (#1936)。**ランタイムの格納も
    /// 1 つ残らずここで分ける。** 格納を足したら、ここで止まる。
    @Test("SketchRuntime の格納は、組み立ての出口での扱いがどれか 1 つに決まっている (#1936)")
    func everyRuntimeStorageHasAnExit() throws {
        let runtime = try SketchRuntime(sketch: RuntimeBlank(), gpu: RenderDevice())
        // 最初に触ったときに作る格納 (`lazy var`) は、反射の綴りが `$__lazy_storage_$_<名前>` になる
        let lazyPrefix = "$__lazy_storage_$_"
        let labels = Mirror(reflecting: runtime).children.compactMap(\.label).map {
            $0.hasPrefix(lazyPrefix) ? String($0.dropFirst(lazyPrefix.count)) : $0
        }
        var seen: Set<String> = []
        for entry in ShapeExit.runtimeTable {
            #expect(seen.insert(entry.name).inserted, "\(entry.name) が表に 2 度載っている")
        }
        for label in labels {
            #expect(
                seen.contains(label),
                "\(label) が SketchRuntime の出口の表 (ShapeExit.runtimeTable) に無い。戻す (汚す手順つき)・触らない (理由つき) のどちらかに載せる")
        }
        for name in seen {
            #expect(labels.contains(name), "\(name) は SketchRuntime の格納に無い (表から消す)")
        }
        // 乱数の列が「戻す」に載っていること自体を縛る。表から消せば上の 2 つが赤くなるが、
        // 理由を付けて「触らない」へ移す書き換えは通ってしまう
        let restored = Set(
            ShapeExit.runtimeTable.compactMap { entry -> String? in
                if case .restore = entry.exit { entry.name } else { nil }
            })
        #expect(restored.contains("randomness"), "乱数の列は出口で戻す (中で書いた種は外へ残らない・#1936)")
    }

    /// 戻す状態を**全部汚してから抜け、全部が戻ったかを見る** — 1 例ずつの検査では、次に足した
    /// 状態の戻し落としが黙る (#1671 と同じ形)。切り離す状態も、抜けた直後に組み立て前のまま
    /// であることを一緒に見る。
    @Test("組み立ての中で汚した状態は、出口の直後に組み立て前の値へ戻る (#1646)", arguments: [true, false])
    func everyRestoredStateIsBackAfterTheBuild(insideAFrame: Bool) throws {
        let canvas = try makeCanvas()
        let fixture = ShapeExit.Fixture(
            sheet: try canvas.createImage(4, 4),
            shader: try canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }"),
            numbers: try canvas.makeNumbers(count: 1))
        let watched = ShapeExit.restoredNames.union(ShapeExit.detachedNames)
        var before: [String: String] = [:]
        var inside: [String: String] = [:]
        var after: [String: String] = [:]
        let build = {
            before = ShapeExit.fingerprint(of: canvas, watched)
            _ = canvas.createShape {
                for entry in ShapeExit.table {
                    if case .restore(let dirty) = entry.exit { dirty(canvas, fixture) }
                }
                inside = ShapeExit.fingerprint(of: canvas, watched)
            }
            after = ShapeExit.fingerprint(of: canvas, watched)
        }
        if insideAFrame {
            try canvas.draw { build() }
        } else {
            build()
        }

        for name in ShapeExit.restoredNames.sorted() {
            #expect(inside[name] != nil, "\(name) を読めていない")
            #expect(inside[name] != before[name], "\(name) を汚す手順が汚していない (既定のままでは戻ったかを見分けられない)")
        }
        for name in watched.sorted() {
            #expect(after[name] == before[name], "\(name) が組み立ての後に組み立て前の値へ戻っていない")
        }
        // 汚したのは組み立ての中で、組み立ての途中の面は描き切っていない
        #expect(!canvas.warnings.hasWarned(.shapeDrawnOutWhileBuilding))
    }

    /// 戻すのは外へ残さないためで、**形には中の描き方が焼き付く**。曲線の細かさは、組み立ての中で
    /// 書いた値で刻まれる。比べる相手は、同じ細かさを外で書いてから組み立てた形である。
    @Test("組み立ての中で書いた曲線の細かさは、形に焼き付く (#1646)")
    func theCurveDetailWrittenInsideIsBakedIntoTheShape() throws {
        let canvas = try makeCanvas(width: 160, height: 160)
        func curve() {
            canvas.noFill()
            canvas.beginShape()
            canvas.vertex(20, 130)
            canvas.bezierVertex(20, 20, 140, 20, 140, 130)
            canvas.endShape()
        }
        var written = Shape.empty
        var coarse = Shape.empty
        var fine = Shape.empty
        try canvas.draw {
            written = canvas.createShape {
                canvas.curveDetail(2)
                curve()
            }
            fine = canvas.createShape { curve() }
            canvas.curveDetail(2)
            coarse = canvas.createShape { curve() }
        }
        #expect(!written.isEmpty)
        #expect(written.vertices.count == coarse.vertices.count, "中で書いた細かさ (2) で刻まれていない")
        #expect(written.vertices.count != fine.vertices.count, "細かさ 2 と既定 (20) の形が見分けられない")
    }

    /// #1646 の再現 (probes の Weave の `shapeCurveDetail`) と同じ比べ方。組み立ての中で
    /// `curveDetail(2)` を呼んだ絵と呼ばない絵で、外の曲線が表示の 1 段 (1/255) を越えて違う画素の数。
    @Test("組み立ての中の curveDetail(2) は、外の曲線の絵を変えない (#1646)")
    func theCurveDetailWrittenInsideDoesNotChangeTheCurveOutside() throws {
        func render(changesDetail: Bool) throws -> PixelBuffer {
            let canvas = try makeCanvas(width: 160, height: 160)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                _ = canvas.createShape {
                    if changesDetail { canvas.curveDetail(2) }
                    canvas.rect(0, 0, 10, 10)
                }
                canvas.noFill()
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.strokeWeight(4)
                canvas.beginShape()
                canvas.vertex(20, 130)
                canvas.bezierVertex(20, 20, 140, 20, 140, 130)
                canvas.endShape()
            }
            return try canvas.target.readPixels()
        }
        let leaked = try render(changesDetail: true)
        let plain = try render(changesDetail: false)
        var differing = 0
        for y in 0..<leaked.height {
            for x in 0..<leaked.width {
                let (p, q) = (leaked[x, y], plain[x, y])
                let gap = max(
                    abs(p.red - q.red), abs(p.green - q.green), abs(p.blue - q.blue),
                    abs(p.alpha - q.alpha))
                if gap > 0.004 { differing += 1 }
            }
        }
        #expect(differing == 0, "組み立ての中の curveDetail(2) で、外の曲線が \(differing) 画素違う")
    }

    /// **「断る」に分けた状態を、出口が書き戻さないこと** (#1684 の反証)。組み立ての中では断るので
    /// 普段は変わらず、書き戻しても見分けられない。見分けられるのは、組み立ての中でフレームが
    /// 閉じるとき (描き場所の組み立ての中の `endDraw()`) — 閉じる側が既定へ戻した値を、出口が
    /// 閉じたフレームの値で書き戻すと、材質と影の落とし方・受け方はフレームの頭で戻らないので
    /// 次のフレームへ持ち越される (#1671 が塞いだのと同じ破れ方)。
    ///
    /// 表の「断る」で汚す手順を持つものを全部汚し、組み立ての中で閉じ、出口の直後と次のフレームで
    /// 見る。**`Style` のフィールドは手順が必須** — 出口は `Style` を写して戻すので、ここが表と
    /// 実装の食い違いを縛る。
    @Test("組み立ての中でフレームが閉じても、断る状態を出口が閉じたフレームの値へ書き戻さない (#1684)")
    func refusedStateIsNotWrittenBackAcrossAFrameEnd() throws {
        let host = try makeCanvas()
        let layer = try host.createGraphics(16, 16)
        let fixture = ShapeExit.Fixture(
            sheet: try layer.createImage(4, 4),
            shader: try layer.makeShader(
                "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }"),
            numbers: try layer.makeNumbers(count: 1))
        var dirtied: Set<String> = []
        for entry in ShapeExit.table {
            guard case .refuse(let dirty) = entry.exit else { continue }
            if dirty != nil { dirtied.insert(entry.name) }
            if entry.name.hasPrefix("style.") {
                #expect(dirty != nil, "\(entry.name) を汚す手順が無い (出口が写す Style のフィールドは必須)")
            }
        }
        let refused = ShapeExit.refusedNames
        var baseline: [String: String] = [:]
        var before: [String: String] = [:]
        var closed: [String: String] = [:]
        var after: [String: String] = [:]
        var next: [String: String] = [:]
        try host.draw {
            layer.beginDraw()
            baseline = ShapeExit.fingerprint(of: layer, refused)
            for entry in ShapeExit.table {
                if case .refuse(let dirty?) = entry.exit { dirty(layer, fixture) }
            }
            before = ShapeExit.fingerprint(of: layer, refused)
            _ = layer.createShape {
                layer.rect(0, 0, 4, 4)
                layer.endDraw()
                closed = ShapeExit.fingerprint(of: layer, refused)
            }
            after = ShapeExit.fingerprint(of: layer, refused)
        }
        try host.draw {
            layer.beginDraw()
            next = ShapeExit.fingerprint(of: layer, refused)
            layer.endDraw()
        }
        for name in dirtied.sorted() {
            #expect(before[name] != baseline[name], "\(name) を汚す手順が汚していない")
            #expect(closed[name] != before[name], "\(name) をフレームの終わりが戻していない (この検査は何も見ていない)")
        }
        for name in refused.sorted() {
            #expect(after[name] == closed[name], "\(name) を出口が閉じたフレームの値へ書き戻した")
            #expect(next[name] == baseline[name], "\(name) が次のフレームへ持ち越された")
        }
    }

    /// 露出と明るさの丸め方は描き方 (フレームの外でも効く) だが、面全体の明るさを決めるもので
    /// 形には焼き付かない。組み立ての中では、フレームの中でも外でも注意して無視する ([#1529] の条件 3)。
    ///
    /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
    @Test(
        "組み立ての中の exposure() / toneMapping() は、注意して無視する (#1529)",
        arguments: [true, false], [true, false])
    func brightnessInsideABuildIsIgnored(insideAFrame: Bool, toneMapping: Bool) throws {
        let canvas = try makeCanvas()
        let before = canvas.target.brightness
        var plain = Shape.empty
        var written = Shape.empty
        let build = {
            plain = canvas.createShape { canvas.rect(2, 2, 4, 4) }
            written = canvas.createShape {
                if toneMapping {
                    canvas.toneMapping(.roll)
                } else {
                    canvas.exposure(3)
                }
                canvas.rect(2, 2, 4, 4)
            }
        }
        if insideAFrame {
            try canvas.draw { build() }
        } else {
            build()
        }
        #expect(canvas.target.brightness == before, "組み立ての中で明るさが変わった")
        #expect(
            canvas.warnings.message(for: Canvas.InsideShape.brightness.warning)
                == Canvas.InsideShape.brightness.notice)
        #expect(written.runs == plain.runs)
        #expect(written.vertices.count == plain.vertices.count)
    }

    /// 組み立ての外では、露出と明るさの丸め方はフレームの中でも外でも効く (描き方)。
    @Test("組み立ての外の exposure() は、今までどおり効く")
    func brightnessOutsideABuildStillWorks() throws {
        let canvas = try makeCanvas()
        canvas.exposure(3)
        #expect(canvas.target.brightness.exposure == 3)
        try canvas.draw { canvas.toneMapping(.roll) }
        #expect(canvas.target.brightness.toneMapping == .roll)
        #expect(!canvas.warnings.hasWarned(Canvas.InsideShape.brightness.warning))
    }
}
