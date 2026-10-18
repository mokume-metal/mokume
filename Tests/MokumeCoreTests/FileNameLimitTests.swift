// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 作れない長さのファイル名を、作る前に断る (`beginRecord`・`save`・`render --out` の行き先・
/// [#2774])。ファイルシステムには書かない — 判定を直に呼ぶ。
///
/// 線は APFS (macOS 27.0) の実測で、静止画 (ImageIO) は 247、動画は 255。数え方は
/// ``FileNameLength/of(_:)`` (`bundle` の名前と共有)。
///
/// [#2774]: https://github.com/mokume-metal/mokume/issues/2774
@Suite("ファイル名の長さを作る前に検める")
struct FileNameLimitTests {
    private func name(_ count: Int, ending suffix: String, in directory: String = "/tmp/out/") -> String
    {
        directory + String(repeating: "a", count: count - suffix.utf16.count) + suffix
    }

    // MARK: - 線

    @Test("静止画は 247 まで、動画は 255 までを作れる名前とする")
    func theLinesAreWhereTheWritesStartToFail() {
        #expect(FrameRecorder.imageNameLimit == 247)
        #expect(FileNameLength.limit == 255)
        #expect(FrameRecorder.shotNameTooLong(name(247, ending: ".png")) == nil)
        #expect(FrameRecorder.shotNameTooLong(name(248, ending: ".png"))?.length == 248)
        #expect(FrameRecorder.nameTooLong(name(255, ending: ".mov")) == nil)
        let long = FrameRecorder.nameTooLong(name(256, ending: ".mov"))
        #expect(long?.length == 256)
        #expect(long?.limit == 255)
        // 大文字の拡張子も動画
        #expect(FrameRecorder.nameTooLong(name(255, ending: ".MOV")) == nil)
    }

    /// **数え方は分解した後の UTF-16 の単位。** `が` は 2、`a` は 1。
    @Test("分解で 2 と数える字は、数え方どおりに線を越える")
    func decomposedCharactersCountAsTheFileSystemCountsThem() {
        let fits = "/tmp/" + String(repeating: "が", count: 100) + String(repeating: "a", count: 43) + ".png"
        let over = "/tmp/" + String(repeating: "が", count: 100) + String(repeating: "a", count: 44) + ".png"
        #expect(FrameRecorder.nameTooLong(fits) == nil)
        #expect(FrameRecorder.nameTooLong(over)?.length == 248)
        // 渡された形の文字数 (147) では線の手前に見える
        #expect(over.count - "/tmp/".count < 247)
    }

    @Test("見るのはファイル名だけで、置き場のディレクトリの長さは見ない")
    func onlyTheFileNameIsCounted() {
        let directory = "/tmp/" + String(repeating: "d", count: 300) + "/"
        #expect(FrameRecorder.nameTooLong(directory + "frame-###.png") == nil)
        #expect(FrameRecorder.shotNameTooLong(directory + "shot.png") == nil)
    }

    // MARK: - 連番は伸びた後で見る

    /// 0 枚目の名前は線ちょうど (247) で書ける。`##` は 100 枚目 (番号 100) から 3 桁に伸びて 248 になる。
    @Test("連番は、番号が桁に収まらず伸びた後の最後の枚の名前で見る")
    func aSeriesIsCheckedAtItsLastFrame() {
        let pattern = name(247, ending: "-##.png")
        #expect(FrameRecorder.nameTooLong(pattern, frameCount: 100) == nil)  // 最後は番号 99
        let long = FrameRecorder.nameTooLong(pattern, frameCount: 101)  // 最後は番号 100
        #expect(long?.length == 248)
        #expect(long?.index == 100)
        // 枚数が分からない `beginRecord` は 0 枚目で見るので通る
        #expect(FrameRecorder.nameTooLong(pattern) == nil)
        // 1 枚だけなら伸びない
        #expect(FrameRecorder.nameTooLong(pattern, frameCount: 1) == nil)
    }

    // MARK: - beginRecord

    @Test("1 枚目の名前が作れない長さなら、撮り始めずに長さを名乗る")
    func beginRecordRefusesATooLongFirstName() {
        let recorder = FrameRecorder(frameRate: 30)
        let pattern = name(248, ending: "-###.png")
        recorder.beginRecord(pattern, at: 1)
        #expect(!recorder.isRecording)
        let message = recorder.warnings.message(for: .fileNameTooLong) ?? ""
        #expect(message.contains("Not starting"))
        #expect(message.contains("248"))
        #expect(message.contains("247"))

        let movie = FrameRecorder(frameRate: 30)
        movie.beginRecord(name(256, ending: ".mov"), at: 1)
        #expect(!movie.isRecording)
        #expect((movie.warnings.message(for: .fileNameTooLong) ?? "").contains("255"))
    }

    /// 線ちょうどの 1 枚目は始める。途中で桁が伸びて越える回は、枚数が先に分からないので始める前には
    /// 断らない (断ると、そこまで撮れていた録りを失う)。
    @Test("線ちょうどの連番は撮り始める")
    func beginRecordStartsAtTheLine() {
        let recorder = FrameRecorder(frameRate: 30)
        recorder.beginRecord(name(247, ending: "-##.png"), at: 1)
        #expect(recorder.isRecording)
        #expect(recorder.warnings.message(for: .fileNameTooLong) == nil)
    }

    // MARK: - save

    @Test("save は作れない長さの名前を積まず、長さを理由に書き損じとして名乗る")
    func saveRefusesATooLongName() {
        let recorder = FrameRecorder(frameRate: 30)
        let path = name(248, ending: ".png")
        recorder.save(path, at: 1)
        #expect(!recorder.hasUnwrittenShots(upTo: Int.max), "書けない名前が積まれている")
        #expect(recorder.hasFailedToWrite)
        let message = recorder.imageFailureMessage(for: path) ?? ""
        #expect(message.contains("248"))
        #expect(message.contains("247"))
        #expect(message.contains("Nothing was saved"))
    }

    @Test("線ちょうどの名前の save は積まれる")
    func saveKeepsAnAcceptableName() {
        let recorder = FrameRecorder(frameRate: 30)
        recorder.save(name(247, ending: ".png"), at: 1)
        #expect(recorder.hasUnwrittenShots(upTo: Int.max))
        #expect(!recorder.hasFailedToWrite)
    }
}
