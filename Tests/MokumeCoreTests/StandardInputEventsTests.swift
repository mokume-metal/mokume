// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 標準入力から受け取る、道具の窓の出来事。
@Suite("窓の出来事を標準入力から受ける")
@MainActor
struct StandardInputEventsTests {
    /// 管を 1 本張って、書く側と読む側を渡す。
    private func withPipe(_ body: (StandardInputEvents, FileHandle) throws -> Void) rethrows {
        let pipe = Pipe()
        let reader = StandardInputEvents(descriptor: pipe.fileHandleForReading.fileDescriptor)
        defer { try? pipe.fileHandleForWriting.close() }
        try body(reader, pipe.fileHandleForWriting)
    }

    private func write(_ text: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("書かれた行が、そのフレームの合流点へ入る")
    func deliversLines() throws {
        try withPipe { reader, writer in
            let state = InputState()
            try write(InputEvent.mouseMoved(x: 10, y: 20).wireLine, to: writer)
            reader.drain(into: state)
            state.beginFrame()
            #expect(state.x == 10)
            #expect(state.y == 20)
            #expect(reader.accepted == 1)
        }
    }

    /// **改行が来るまでは解かない。** 半分だけ届いた行を解こうとすると、その 1 件が
    /// 消えるうえに次の行の頭を食う。管は境目を保証しない。
    @Test("半分だけ届いた行は、残りが来てから 1 件として繋がる")
    func joinsSplitLines() throws {
        try withPipe { reader, writer in
            let state = InputState()
            let line = InputEvent.mouseDown(x: 5, y: 6, button: 0).wireLine
            let cut = line.index(line.startIndex, offsetBy: line.count / 2)
            try write(String(line[..<cut]), to: writer)
            reader.drain(into: state)
            #expect(reader.accepted == 0)

            try write(String(line[cut...]), to: writer)
            reader.drain(into: state)
            state.beginFrame()
            #expect(reader.accepted == 1)
            #expect(state.isMouseDown)
        }
    }

    /// **捨てるのはその 1 件だけ。** 送り手が新しい種別を足しても、古い受け手に当たった
    /// ときに落ちるのはその 1 行で、走っているスケッチは止まらない (ADR-0018 決定 3)。
    @Test("解けない行は、その 1 件だけ捨てて残りを通す")
    func ignoresOnlyTheBrokenLine() throws {
        try withPipe { reader, writer in
            let state = InputState()
            try write("{壊れている\n", to: writer)
            try write("{\"type\":\"知らない\"}\n", to: writer)
            try write("{\"type\":\"mouseDown\"}\n", to: writer)  // 位置が無いので解けない
            try write(InputEvent.mouseMoved(x: 7, y: 8).wireLine, to: writer)
            reader.drain(into: state)
            state.beginFrame()
            #expect(reader.ignored == 3)
            #expect(reader.accepted == 1)
            #expect(state.x == 7)
        }
    }

    /// **窓から来ても、直に入れたときと同じ扱いを受ける。**
    ///
    /// 合流が 1 箇所なら、送られた出来事が実操作と違う扱いを受けることは構造的に
    /// 起きない ([ADR-0018](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md) 決定 1)。
    /// 引きずった量は**押した瞬間の飛び**を含まない — そこが崩れると、触って回すものが
    /// 押した瞬間に飛ぶ。
    @Test("押した瞬間に飛ばない — 直に入れたときと同じだけ引きずる")
    func dragMatchesTheDirectPath() throws {
        try withPipe { reader, writer in
            let events: [InputEvent] = [
                .mouseMoved(x: 0, y: 0),
                .mouseDown(x: 100, y: 50, button: 0),
                .mouseMoved(x: 120, y: 60),
            ]
            let viaPipe = InputState()
            for event in events { try write(event.wireLine, to: writer) }
            reader.drain(into: viaPipe)
            viaPipe.beginFrame()

            let direct = InputState()
            for event in events { direct.enqueue(event) }
            direct.beginFrame()

            #expect(viaPipe.dragX == direct.dragX)
            #expect(viaPipe.dragY == direct.dragY)
            // 押下のぶん (0,0 → 100,50) は入らず、押したまま動いたぶんだけ
            #expect(viaPipe.dragX == 20)
            #expect(viaPipe.dragY == 10)
        }
    }

    /// **待たない。** 塞ぐ読み方をすると、次の 1 件が来るまでフレームが進まなくなる。
    @Test("何も来ていなければ、待たずに戻る")
    func doesNotBlockWhenEmpty() throws {
        try withPipe { reader, _ in
            let state = InputState()
            reader.drain(into: state)
            #expect(reader.accepted == 0)
            #expect(!reader.isClosed)
        }
    }

    /// 直に走らせた子の標準入力 (端末) を横取りしないことは、**合図が 1 つ**であること
    /// から従う ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 1)。
    @Test("区画が無ければ、標準入力に触らない")
    func staysAwayWithoutTheFacet() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(StandardInputEvents.makeIfEnabled(at: absent) == nil)
    }
}
