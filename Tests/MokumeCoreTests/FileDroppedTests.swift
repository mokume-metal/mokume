// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 窓へ落としたファイルを、フレームに属する入力の出来事 `fileDropped` として受ける
/// ([#3061](https://github.com/mokume-metal/mokume/issues/3061))。
///
/// 外から送る線・合流点・窓 (`NSDraggingDestination`) を、それぞれ固める。実際にファイルを窓へ
/// 落とす身振りは人の手 (PR 本文の「確認してほしい点」) で、ここは落とされた中身を持つ代役
/// (``FakeDraggingInfo``) を面へ渡して、その先を見る。
@Suite("ファイルの落とし: 合流点")
@MainActor
struct FileDroppedInputTests {
    /// 1 フレーム分を流して、配った呼び出しを返す。
    @discardableResult
    private func run(_ state: InputState, _ events: [InputEvent]) -> [InputCallback] {
        for event in events { state.enqueue(event) }
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        return seen
    }

    @Test("落としは 1 回の呼び出しになり、パスの並びと落とした所が届く")
    func aDropIsOneCallbackWithItsPathsAndPosition() {
        let state = InputState()
        var positions: [(Float, Float)] = []
        state.enqueue(.fileDropped(paths: ["/tmp/a.png", "/tmp/b.png"], x: 10, y: 20))
        state.beginFrame { callback in
            // 呼ばれた中から読める位置は、その出来事を当てた直後の姿
            if case .fileDropped = callback { positions.append((state.x, state.y)) }
        }
        #expect(positions.count == 1)
        #expect(positions.first?.0 == 10 && positions.first?.1 == 20)
        #expect(state.x == 10 && state.y == 20)

        #expect(
            run(state, [.fileDropped(paths: ["/tmp/a.png", "/tmp/b.png"], x: 1, y: 2)])
                == [.fileDropped(paths: ["/tmp/a.png", "/tmp/b.png"])], "パスの並びが変わった・欠けた")
    }

    @Test("落としは mouseMoved を呼ばず、動いた量にも引きずった量にも足さない")
    func aDropIsNotAMovement() {
        let state = InputState()
        run(state, [.mouseMoved(x: 5, y: 5)])
        let seen = run(state, [.fileDropped(paths: ["/tmp/a.png"], x: 300, y: 200)])
        #expect(seen == [.fileDropped(paths: ["/tmp/a.png"])], "\(seen)")
        #expect(state.movedX == 0 && state.movedY == 0, "落とした所への飛びを移動に数えた")
        #expect(state.dragX == 0 && state.dragY == 0)
        #expect(state.previousX == 5 && state.previousY == 5, "前のフレームの位置は、落とす前のまま")
        #expect(state.x == 300 && state.y == 200)
    }

    @Test("落としはフレームの間も押下の状態も変えない")
    func aDropKeepsTheButtonsAsTheyWere() {
        let state = InputState()
        run(state, [.mouseDown(x: 1, y: 1, button: .left)])
        let seen = run(state, [.fileDropped(paths: ["/tmp/a.png"], x: 9, y: 9)])
        #expect(seen == [.fileDropped(paths: ["/tmp/a.png"])])
        #expect(state.isMouseDown, "落としが押下を解いた")
        #expect(state.button == .left)
    }

    @Test(
        "位置が有限でない落としは、位置だけを捨てる。位置は前の値のまま、パスは届いて 1 回呼ばれ、1 度だけ言う",
        arguments: [
            (Float.nan, Float(5)), (Float(5), Float.infinity), (-Float.infinity, Float.nan),
        ])
    func aNonFinitePositionKeepsThePathsAndDropsThePosition(x: Float, y: Float) {
        let state = InputState()
        run(state, [.mouseMoved(x: 40, y: 50)])
        let seen = run(
            state,
            [
                .fileDropped(paths: ["/tmp/a.png"], x: x, y: y),
                .fileDropped(paths: ["/tmp/b.png"], x: x, y: y),
            ])
        #expect(
            seen == [
                .fileDropped(paths: ["/tmp/a.png"]), .fileDropped(paths: ["/tmp/b.png"]),
            ], "パスが届かなかった: \(seen)")
        #expect(state.x == 40 && state.y == 50, "非有限の位置を当てた: (\(state.x), \(state.y))")
        let message = state.warnings.message(for: .nonFinitePosition)
        #expect(message?.contains("fileDropped") == true, "\(String(describing: message))")
    }

    @Test("溜めきれず押し出された落としも、位置は当てる (呼び出しだけが落ちる)")
    func anOverflowedDropStillMovesThePosition() {
        let state = InputState()
        state.enqueue(.fileDropped(paths: ["/tmp/a.png"], x: 77, y: 88))
        for _ in 0..<InputState.queueLimit { state.enqueue(.scrolled(dx: 0, dy: 0)) }
        #expect(state.x == 77 && state.y == 88)
        #expect(state.droppedEvents == 1)
    }
}

@Suite("ファイルの落とし: 線")
struct FileDroppedWireTests {
    private func decode(_ json: String) throws -> RawInputEvent {
        try JSONDecoder().decode(RawInputEvent.self, from: Data(json.utf8))
    }

    /// 書く側 (`wireLine`) の 1 行を、読む側で同じ値に読み戻せる。引用符・改行・日本語・空白を含むパスも。
    @Test("落としは線へ書いて読み戻すと同じ出来事になる")
    func theDropSurvivesTheWire() throws {
        let events: [InputEvent] = [
            .fileDropped(paths: ["/tmp/a.png"], x: 10, y: 20),
            .fileDropped(paths: ["/tmp/a.png", "/tmp/b.png", "/tmp/c.png"], x: 0.5, y: -3),
            .fileDropped(
                paths: ["/tmp/he said \"hi\".png", "/tmp/改行\nと\tタブ.png", "/tmp/日本語 の フォルダ/写真.png"],
                x: 12.25, y: 99),
            .fileDropped(paths: ["/tmp/back\\slash.png"], x: 1, y: 1),
        ]
        for event in events {
            #expect(try decode(event.wireLine).event == event, "往復で変わった: \(event)")
        }
        // 子の標準入力へ 1 行 1 件で渡るので、改行を含むパスでも線は 1 行に収まる
        for event in events {
            #expect(event.wireLine.filter { $0 == "\n" }.count == 1, "線が複数行になった")
        }
    }

    @Test("外から送る形 {type, paths, x, y} が読める")
    func theDocumentedShapeIsRead() throws {
        #expect(
            try decode(#"{"type": "fileDropped", "paths": ["/tmp/a.png"], "x": 10, "y": 20}"#).event
                == .fileDropped(paths: ["/tmp/a.png"], x: 10, y: 20))
        #expect(InputEvent.fileDropped(paths: ["/tmp/a.png"], x: 10, y: 20).wireType == .fileDropped)
    }

    @Test("パスの無い・空の・null の落としは読めない 1 件。位置が欠けたものも")
    func unreadableDrops() throws {
        #expect(try decode(#"{"type": "fileDropped", "x": 1, "y": 2}"#).event == nil)
        #expect(try decode(#"{"type": "fileDropped", "paths": [], "x": 1, "y": 2}"#).event == nil)
        #expect(
            try decode(#"{"type": "fileDropped", "paths": null, "x": 1, "y": 2}"#).event == nil)
        #expect(try decode(#"{"type": "fileDropped", "paths": ["/tmp/a.png"], "y": 2}"#).event == nil)
        #expect(try decode(#"{"type": "fileDropped", "paths": ["/tmp/a.png"], "x": 1}"#).event == nil)
    }

    @Test("文字列でない要素を含むパスの並びは、解けない 1 件")
    func wrongTypedPaths() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"type": "fileDropped", "paths": ["/tmp/a.png", 3], "x": 1, "y": 2}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"type": "fileDropped", "paths": "/tmp/a.png", "x": 1, "y": 2}"#)
        }
    }

    @Test("paths は fileDropped でだけ読む。型違いの値が付いた mouseUp も解ける")
    func pathsAreReadOnFileDroppedOnly() throws {
        #expect(
            try decode(#"{"type": "mouseUp", "x": 1, "y": 2, "paths": "x"}"#).event
                == .mouseUp(x: 1, y: 2, button: .left))
        #expect(RawInputEvent.readKeys(forType: "fileDropped").contains("paths"))
        #expect(!RawInputEvent.readKeys(forType: "mouseDown").contains("paths"))
        #expect(!RawInputEvent.readKeys(forType: "pinched").contains("paths"))
        // 落としは amount も clickCount も読まない
        #expect(!RawInputEvent.readKeys(forType: "fileDropped").contains("amount"))
        #expect(!RawInputEvent.readKeys(forType: "fileDropped").contains("clickCount"))
    }

    /// 外から送る要求では、読めない 1 件だけが `ignored` に数えられ、残りは通る。
    @Test("外から送る要求でも、読めない落としの 1 件だけが ignored に数えられる")
    func theRequestCountsTheBadOneAsIgnored() throws {
        let json = """
            {"id": "a", "events": [
              {"type": "fileDropped", "paths": [], "x": 1, "y": 2},
              {"type": "fileDropped", "paths": ["/tmp/a.png"]},
              {"type": "fileDropped", "paths": ["/tmp/a.png"], "x": 10, "y": 20},
              {"type": "fileDropped", "paths": [1], "x": 10, "y": 20}
            ]}
            """
        let request = try JSONDecoder().decode(InputRequest.self, from: Data(json.utf8))
        let events = request.events.compactMap { $0.event }
        #expect(events == [.fileDropped(paths: ["/tmp/a.png"], x: 10, y: 20)], "\(events)")
    }

    /// 外から送る要求 (区画の `request.json`) を通して、合流点まで届く。ignored・warnings も見る。
    @MainActor
    @Test("区画から送ると、落としが届いて accepted に数えられる。paths を mouseDown に付けると名乗って 1 件は通す")
    func theInboxFeedsTheDropAndNamesStrayPaths() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-dropped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: facet) }
        let body = #"""
            {"id":"d1","events":[
              {"type":"fileDropped","paths":["/tmp/a.png"],"x":10,"y":20},
              {"type":"fileDropped","paths":[],"x":10,"y":20},
              {"type":"mouseDown","x":1,"y":2,"paths":["/tmp/a.png"]}
            ]}
            """#
        try AtomicFile.write(Data(body.utf8), to: facet.appendingPathComponent("request.json"))
        let state = InputState()
        let report = try #require(InputInbox(directory: facet).drain(into: state))
        #expect(report.accepted == 2)
        #expect(report.ignored == 1, "空の paths の 1 件が ignored に数えられない")
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        #expect(seen == [.fileDropped(paths: ["/tmp/a.png"]), .mousePressed])
        let warnings = try #require(report.warnings)
        #expect(warnings.count == 1, "\(warnings)")
        #expect(warnings[0].hasPrefix("events[2]: ") && warnings[0].contains("paths"))
        // 名乗る「読む鍵」は、その種別が読む鍵 (mouseDown は paths を読まない)
        #expect(!warnings[0].contains("clickCount, paths"))
    }
}

/// ドラッグされている中身を持つ代役。本物の `NSDraggingInfo` は AppKit のドラッグの最中にしか作れない。
@MainActor
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    init(pasteboard: NSPasteboard, at location: NSPoint = NSPoint(x: 0, y: 0)) {
        self.draggingPasteboard = pasteboard
        self.draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    /// 使い捨ての落書き板にファイルの URL を載せた、ドラッグの中身。
    static func files(_ paths: [String], at location: NSPoint = .zero) -> FakeDraggingInfo {
        let board = NSPasteboard(name: NSPasteboard.Name("mokume.test.\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        return FakeDraggingInfo(pasteboard: board, at: location)
    }

    /// 使い捨ての落書き板に、ブラウザから落とした文字列や URL を載せた、ドラッグの中身。
    static func text(_ string: String, at location: NSPoint = .zero) -> FakeDraggingInfo {
        let board = NSPasteboard(name: NSPasteboard.Name("mokume.test.\(UUID().uuidString)"))
        board.clearContents()
        board.setString(string, forType: .string)
        return FakeDraggingInfo(pasteboard: board, at: location)
    }
}

@Suite("ファイルの落とし: 窓")
@MainActor
struct FileDroppedSurfaceTests {
    private func makeSurface(_ input: InputState) throws -> SketchSurface {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device,
            input: input, canvasSize: (64, 64))
    }

    /// 窓に載せた面。落とした所を写すには、面が層を持ち窓に載っている必要がある。
    private func withWindowedSurface(
        _ input: InputState, _ body: (SketchSurface) throws -> Void
    ) throws {
        let surface = try makeSurface(input)
        surface.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: true)
        // 素の `NSWindow` は閉じたら自分を解放する。こちらが強い参照を持ったまま閉じると過剰に解放される (#705)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = surface
        try body(surface)
    }

    @Test(
        "面はファイルの URL を受けるよう登録している",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func theSurfaceRegistersForFileURLs() throws {
        let surface = try makeSurface(InputState())
        #expect(surface.registeredDraggedTypes.contains(.fileURL))
    }

    @Test("ドラッグの中身からは、ファイルの URL だけが絶対パスになる")
    func onlyFileURLsBecomePaths() {
        let files = FakeDraggingInfo.files(["/tmp/a.png", "/tmp/日本語 の/b.png"])
        #expect(
            SketchSurface.droppedPaths(from: files.draggingPasteboard)
                == ["/tmp/a.png", "/tmp/日本語 の/b.png"])
        for text in ["https://example.com/a.png", "hello", "file-less text"] {
            let dragging = FakeDraggingInfo.text(text)
            #expect(
                SketchSurface.droppedPaths(from: dragging.draggingPasteboard).isEmpty,
                "文字列 \(text) をパスにした")
        }
        // ブラウザから落とした https の URL は、URL として載っていてもファイルではない
        let board = NSPasteboard(name: NSPasteboard.Name("mokume.test.\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([URL(string: "https://example.com/a.png")! as NSURL])
        #expect(SketchSurface.droppedPaths(from: board).isEmpty)
    }

    @Test(
        "ファイルでない中身のドラッグは断る。ファイルは受ける",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func nonFileDragsAreRefused() throws {
        let surface = try makeSurface(InputState())
        #expect(surface.draggingEntered(FakeDraggingInfo.text("hello")) == [])
        #expect(surface.draggingUpdated(FakeDraggingInfo.text("hello")) == [])
        #expect(surface.draggingEntered(FakeDraggingInfo.files(["/tmp/a.png"])) == .copy)
    }

    @Test(
        "落とすと、合流点と運び先へ同じ 1 件が行き、落とした所が mouseX・mouseY になる",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func aDropReachesTheConfluenceAndTheRelay() throws {
        let input = InputState()
        try withWindowedSurface(input) { surface in
            var lines: [String] = []
            surface.relay = { lines.append($0) }
            // 窓の座標は左下原点。面と窓が同じ大きさ (64 四方) なので、窓の (10, 44) はキャンバスの (10, 20)
            let accepted = surface.performDragOperation(
                FakeDraggingInfo.files(["/tmp/a.png"], at: NSPoint(x: 10, y: 44)))
            #expect(accepted)
            var seen: [InputCallback] = []
            input.beginFrame { seen.append($0) }
            #expect(seen == [.fileDropped(paths: ["/tmp/a.png"])])
            #expect(abs(input.x - 10) < 0.01 && abs(input.y - 20) < 0.01, "(\(input.x), \(input.y))")
            #expect(lines.count == 1, "\(lines)")
            let echoed = try #require(lines.first)
            #expect(
                try JSONDecoder().decode(RawInputEvent.self, from: Data(echoed.utf8)).event
                    == .fileDropped(paths: ["/tmp/a.png"], x: input.x, y: input.y), "\(echoed)")
        }
    }

    @Test(
        "ファイルでない中身の落としは、何も流さずに断る",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func aNonFileDropSendsNothing() throws {
        let input = InputState()
        try withWindowedSurface(input) { surface in
            var lines: [String] = []
            surface.relay = { lines.append($0) }
            // 落とした所は写せる位置にする (写せないから断った、と取り違えないため)
            let dragging = FakeDraggingInfo.text(
                "https://example.com/a.png", at: NSPoint(x: 10, y: 44))
            #expect(!surface.performDragOperation(dragging))
            #expect(lines.isEmpty)
            var seen: [InputCallback] = []
            input.beginFrame { seen.append($0) }
            #expect(seen.isEmpty)
        }
    }

    @Test(
        "落とした所を写せないとき (描く大きさが 0) は、流さずに断る",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func aDropThatCannotBeLocatedSendsNothing() throws {
        let input = InputState()
        // 層を持たせず、窓にも載せない面は、描く大きさが 0 で、落とした所を写せない
        let surface = try makeSurface(input)
        var lines: [String] = []
        surface.relay = { lines.append($0) }
        #expect(!surface.performDragOperation(FakeDraggingInfo.files(["/tmp/a.png"])))
        #expect(lines.isEmpty)
    }
}
