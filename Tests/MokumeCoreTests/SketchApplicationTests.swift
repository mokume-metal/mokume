// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// スケッチが自分で持つ窓 ([#714](https://github.com/mokume-metal/mokume/issues/714))。
///
/// **窓の寿命を、窓自身に決めさせない。** 素の `NSWindow` の既定は「閉じたら自分を解放する」
/// なので、こちらが強い参照を持ったまま閉じられると、参照の指す先が消える。以後その参照を
/// 触るのは未定義で、**症状は原因から遠いところにしか出ない** — 隣の ``SharedFrameStage``
/// では検査の走り終わりでの落下 (signal 11) として出た
/// ([#705](https://github.com/mokume-metal/mokume/issues/705))。
@Suite(
    "スケッチの窓",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SketchApplicationTests {
    /// 何も描かないスケッチ。窓を開くのに要るのは大きさだけなので、既定のままでよい。
    private final class Blank: Sketch {}

    /// **閉じた窓を、閉じた後に触る。**
    ///
    /// 窓を閉じるとアプリケーションは終わりに向かうが、即死ではない。加えてフレームの
    /// 駆動源は窓ではなく**画面**に紐づいているので
    /// ([#223](https://github.com/mokume-metal/mokume/issues/223))、窓が消えた後も
    /// `step(_:)` は呼ばれ続け、`presentFrame()` から `window?.occlusionState` を触る。
    ///
    /// ## 落ちるのを待つ形にしていない理由
    ///
    /// 閉じた瞬間に解放されるわけではない。実測すると、閉じた直後の窓には AppKit の側から
    /// 数百の参照が付いている — つまり**解放が 1 回余分になったことは、ここでは何も起こさない**。
    /// #705 でそれが signal 11 として出たのは 1008 本を走らせた最後であり、いつ・どこで
    /// 出るかを検査から決められない。
    ///
    /// だから**窓が自分を解放しないこと自体**を見る。これは実装の細部ではなく、この窓が
    /// AppKit と結んでいる約束そのものである。開いて閉じて触るところまでを同じ検査に置くのは、
    /// 約束が実際の経路の窓に掛かっていることと、走り終わりまで生きていることを併せて見るため。
    @Test("窓を閉じても、その後に窓を触る経路が未定義にならない")
    func theWindowOutlivesItsClosing() throws {
        let application = try SketchApplication(sketch: Blank(), gpu: RenderDevice())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        #expect(!window.isReleasedWhenClosed)

        window.close()
        #expect(!application.isWindowOnScreen)
    }

    /// **スケッチ自身の窓でも、キーは面へ届く。**
    ///
    /// キーは第一応答者へ配られるので、面がそこに居ない窓では `keyDown` が 1 度も呼ばれず、
    /// 警告も出ない。据え方は道具が出す窓と揃えてあるが ([#963])、揃っていることを人の目に
    /// 委ねると片方だけが直る形になるので、**両方の経路で同じ形の検査を持つ**。
    ///
    /// 合流点ではなく運び先 (`relay`) から見るのは、走らせている入れ物が `private` で
    /// 検査から触れないためである。見たい区間 (窓 → 第一応答者 → 面) はどちらでも同じだけ
    /// 通る。
    ///
    /// [#963]: https://github.com/mokume-metal/mokume/issues/963
    @Test("スケッチの窓へ送ったキーも、面へ届く")
    func keysReachTheSurfaceThroughTheWindow() throws {
        let application = try SketchApplication(sketch: Blank(), gpu: RenderDevice())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        let surface = try #require(window.contentView as? SketchSurface)
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        let event = try #require(KeyEventFixture.keyDown(in: window, characters: "a", keyCode: 0))
        window.sendEvent(event)
        #expect(
            lines == [
                InputEvent.keyDown(code: Key(rawValue: 0), characters: "a", isRepeat: false)
                    .wireLine
            ])
    }

    // MARK: - 最後の窓が閉じたときに終わるか (#1102)

    /// 区画を 1 つ作って渡す。後片付けまで面倒を見る。
    private func withFacet<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// **窓を 1 枚も開かずに見る。** `didFinishLaunching()` を呼ばないので、この 2 本は
    /// AppKit の窓を建てない — 見たいのは判定であって、窓の建ち方ではない。
    ///
    /// 名乗り (``SketchPresence``) を実際に出して確かめる形は採れない。出せば走らせるたびに
    /// メニューバーへ物が増える (#473 の理由で、名乗り自体は検査から出さない)。
    @Test("窓を道具が持つ経路では、最後の窓が閉じてもスケッチは終わらない")
    func theSketchOutlivesTheLastWindowWhenTheToolOwnsIt() throws {
        try withFacet { facet in
            let application = try SketchApplication(sketch: Blank(), gpu: RenderDevice())
            defer { application.willTerminate() }
            application.resolveOutlet(at: facet)

            let delegate = SketchApplicationDelegate(application: application)
            #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        }
    }

    /// **窓の経路は動かさない。** 作品の窓の × が作品を終えることは ADR-0032 の追補
    /// (#826) が決めており、#1102 が触ってよいのは窓を持たない側だけである。
    @Test("自分の窓を持つ経路では、最後の窓が閉じたらスケッチも終わる")
    func theSketchEndsWithItsOwnLastWindow() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        let application = try SketchApplication(sketch: Blank(), gpu: RenderDevice())
        defer { application.willTerminate() }
        // 区画が無いので、出口は窓のまま
        application.resolveOutlet(at: missing)

        let delegate = SketchApplicationDelegate(application: application)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }
}
