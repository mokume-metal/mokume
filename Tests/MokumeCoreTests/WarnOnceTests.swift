// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 畳む前に 7 つの `warn*OutsideFrame()` が持っていた文面 ([#947]) と、
/// 後から同じ形で足した変換 ([#941])。
///
/// **実装とは別の場所に写して突き合わせる。** 利用者が読む 1 行なので、畳んだ拍子に
/// 変わっていないことをここで見る — 実際、7 本を 1 つの型へ畳んだとき「頼んだ」が
/// 「頼んた」になった (語幹だけを差し替えて音便を落とした)。
///
/// [#947]: https://github.com/mokume-metal/mokume/issues/947
private let outsideFrameNotices: [Canvas.OutsideFrame: String] = [
    .camera:
        "視点と投影はフレームごとに置き直すものなので、描くところ (draw) で呼んでください。"
            + "初期化のときに書いた視点はどのフレームにも属さないため、無視しました",
    .transform:
        "変換はフレームごとに書き直すものなので、描くところ (draw) で呼んでください。"
            + "初期化のときに書いた変換はどのフレームにも属さないため、無視しました",
    .style:
        "スタイルの積み降ろしはフレームの中でだけできます。"
            + "初期化のときに積んだスタイルはどのフレームにも属さないため、無視しました",
    .light:
        "光はフレームごとに置き直すものなので、描くところ (draw) で呼んでください。"
            + "初期化のときに置いた光はどのフレームにも属さないため、無視しました",
    .surroundings:
        "周囲はフレームごとに置き直すものなので、描くところ (draw) で呼んでください。"
            + "初期化のときに置いた周囲はどのフレームにも属さないため、無視しました",
    .shadow:
        "影はフレームごとに書き直すものなので、描くところ (draw) で呼んでください。"
            + "初期化のときに書いた影はどのフレームにも属さないため、無視しました",
    .material:
        "材質はフレームごとに書き直すものなので、描くところ (draw) で呼んでください。"
            + "初期化のときに書いた材質はどのフレームにも属さないため、無視しました",
    .particles:
        "粒は描くところ (draw) で扱います。"
            + "初期化のときに出した粒はどのフレームにも属さないため、無視しました",
    .compute:
        "計算は描くところ (draw) の前置きなので、そこで頼んでください。"
            + "初期化のときに頼んだ計算はどのフレームにも属さないため、無視しました",
]

/// 文面そのものの検査。**GPU は要らない** ので、GPU の無い環境でも走る。
@Suite("フレームの外で置き直したときの文面")
struct OutsideFrameNoticeTests {
    @Test("9 つとも原文のまま")
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
        "shininess(): 数でない値・無限・範囲の外の値が渡されたので、材質を変えませんでした"

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
