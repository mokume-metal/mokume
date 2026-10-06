// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 窓の出し方 (#679・#1624)。GPU は要らない — 起動の性質と、開く大きさの指定から
/// 決まるところだけを見る (大きさの指定は窓を 1 枚作って当てるが、画面に出さない)。
///
/// **位置そのものは見ない。** 覚えるのも復元するのも AppKit が持っており、こちらは
/// 「覚えているものがあればそれを使う」と書いただけである。実際に動かないことは
/// 動きの証跡が担う ([ADR-0019](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md) 決定 1 と同じ分担)。
@Suite("窓の出し方")
struct WindowPlacementTests {
    /// **合図は版の刻印 1 つ。** 道具が渡すもので、新しい合図を作っていない。
    @Test("刻印が渡されていれば、見張りが起こした入れ替えとみなす")
    func theStampMarksARelaunch() {
        #expect(WindowPlacement.isRelaunch(stamp: "abc123"))
        #expect(!WindowPlacement.isRelaunch(stamp: nil))
    }

    /// **入れ替えでは前面を取らない。** 保存のたびに前面が移ると、打っている手が止まる。
    @Test("前面を取るのは、初めての起動のときだけ")
    func onlyTheFirstLaunchTakesFocus() {
        #expect(WindowPlacement.takesFocus(isRelaunch: false))
        #expect(!WindowPlacement.takesFocus(isRelaunch: true))
    }

    // MARK: - 開く大きさの指定 (#1624)

    /// 指定を覚える先を、その場限りで作る。**後片付けまで面倒を見る** — 既定のままだと、
    /// 検査を走らせたプロセスの記憶に指定が残る。
    private func withDefaults<T>(_ body: (UserDefaults, String) throws -> T) throws -> T {
        let suite = "mokume.test.placement.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return try body(defaults, "mokume.test.window.\(UUID().uuidString)")
    }

    @Test("指定しなければ、これまでどおり描く大きさの半分の点で開く")
    func theDefaultScaleIsHalf() {
        let scale = SketchSettings().windowScale
        #expect(scale == 0.5)
        #expect(
            WindowPlacement.requestedSize(width: 1280, height: 720, scale: scale)
                == NSSize(width: 640, height: 360))
        // 道具の窓の既定 (差し出し元が来る前の大きさ) は、既定のスケッチの開く大きさと同じ
        let settings = SketchSettings()
        #expect(
            WindowPlacement.requestedSize(
                width: settings.width, height: settings.height, scale: settings.windowScale)
                == SharedFrameWindow.defaultSize)
    }

    /// 作例 1 (#1624): 320x180 の画素絵を 4 倍の窓で見せる。
    @Test("倍率 4 なら、320x180 を 1280x720 点で開く")
    func pixelArtOpensFourTimesLarger() {
        #expect(
            WindowPlacement.requestedSize(width: 320, height: 180, scale: 4)
                == NSSize(width: 1280, height: 720))
    }

    @Test("画面に収まらなければ、縦横比を保って縮める。収まれば (ちょうどでも) そのまま")
    func shrinksToFitKeepingTheShape() {
        let bounds = NSSize(width: 1440, height: 870)
        // 横が溢れる
        #expect(
            WindowPlacement.fitted(NSSize(width: 2880, height: 1620), within: bounds)
                == NSSize(width: 1440, height: 810))
        // 縦が溢れる
        #expect(
            WindowPlacement.fitted(NSSize(width: 1000, height: 1740), within: bounds)
                == NSSize(width: 500, height: 870))
        // 境界: ちょうど収まる・収まっている
        #expect(WindowPlacement.fitted(bounds, within: bounds) == bounds)
        #expect(
            WindowPlacement.fitted(NSSize(width: 640, height: 360), within: bounds)
                == NSSize(width: 640, height: 360))
    }

    @Test("指定が変わったときだけ「新しい」と答え、覚え直す")
    func onlyAChangedRequestIsNew() throws {
        try withDefaults { defaults, name in
            let small = NSSize(width: 160, height: 120)
            let large = NSSize(width: 960, height: 540)
            // 覚えている指定が無い = 前の版が覚えた大きさかもしれない
            #expect(WindowPlacement.takesNewRequest(small, autosaveName: name, defaults: defaults))
            #expect(!WindowPlacement.takesNewRequest(small, autosaveName: name, defaults: defaults))
            #expect(WindowPlacement.takesNewRequest(large, autosaveName: name, defaults: defaults))
            #expect(!WindowPlacement.takesNewRequest(large, autosaveName: name, defaults: defaults))
            // 名前が違えば別に覚える (作品の窓とプレビュー)
            #expect(
                WindowPlacement.takesNewRequest(
                    large, autosaveName: name + ".other", defaults: defaults))
        }
    }

    /// 完了条件 3 の 2 つを窓で見る。**指定を変えれば新しい指定で開き、変えなければ手で
    /// 変えた大きさが残る** — 後者が破れると、見張りの下で保存のたびに窓が戻る (#679)。
    @Test("指定を変えれば窓は新しい指定の大きさになり、変えなければ手で変えた大きさが残る")
    @MainActor
    func honoursOnlyAChangedRequest() throws {
        try withDefaults { defaults, name in
            var warnings: [String] = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let first = NSSize(width: 320, height: 240)
            #expect(
                WindowPlacement.honour(
                    first, in: window, autosaveName: name, defaults: defaults,
                    warn: { warnings.append($0) }))
            #expect(window.contentLayoutRect.size == first)

            // 人が手で広げた。同じ指定でもう一度開いても、広げた大きさのまま
            let resized = NSSize(width: 500, height: 300)
            window.setContentSize(resized)
            #expect(
                !WindowPlacement.honour(
                    first, in: window, autosaveName: name, defaults: defaults,
                    warn: { warnings.append($0) }))
            #expect(window.contentLayoutRect.size == resized)

            // 指定を変えた (probes#25 の 320x240 → 1920x1080 の縮尺版)
            let second = NSSize(width: 192, height: 108)
            #expect(
                WindowPlacement.honour(
                    second, in: window, autosaveName: name, defaults: defaults,
                    warn: { warnings.append($0) }))
            #expect(window.contentLayoutRect.size == second)
            #expect(warnings.isEmpty, "収まる大きさで縮めたと言った: \(warnings)")
        }
    }

    /// **既定の 480x270 どうしなら、これまでと同じずらし量** (`-(270 + 44)`)。作品の窓が
    /// 高くなれば、そのぶん下へ (#1624)。
    @Test("プレビューのずらし量は 2 枚の丈から決まり、既定どうしならこれまでと同じ")
    func previewNudgeFollowsBothHeights() {
        #expect(SharedFramePreview.nudge == NSSize(width: 0, height: -(270 + 44)))
        #expect(
            WindowPlacement.nudgeBelow(artworkHeight: 270, previewHeight: 270)
                == SharedFramePreview.nudge)
        #expect(
            WindowPlacement.nudgeBelow(artworkHeight: 720, previewHeight: 270)
                == NSSize(width: 0, height: -(495 + 44)))
    }

    @Test("ちょうど中央に置く原点")
    func centresExactly() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        #expect(
            WindowPlacement.centred(NSSize(width: 480, height: 298), in: visible)
                == NSPoint(x: 480, y: 313))
    }

    /// 画面を大きく超える指定 (完了条件 4)。**断らずに縮め、縮めたことを言う。**
    @Test("画面を超える指定は、縦横比を保って縮めて開き、そのことを 1 行言う")
    @MainActor
    func shrinksAnOversizedRequestAndSaysSo() throws {
        try withDefaults { defaults, name in
            var warnings: [String] = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let huge = NSSize(width: 160_000, height: 90_000)
            WindowPlacement.honour(
                huge, in: window, autosaveName: name, defaults: defaults,
                warn: { warnings.append($0) })
            guard NSScreen.main != nil else { return }  // 画面の無い実行環境では縮める先が無い
            let size = window.contentLayoutRect.size
            #expect(size.width < huge.width)
            #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.01, "縦横比が崩れた: \(size)")
            #expect(warnings.count == 1)
        }
    }
}
