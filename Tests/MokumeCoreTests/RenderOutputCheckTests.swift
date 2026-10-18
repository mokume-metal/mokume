// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 子が 0 で終わった後に、道具が書き出し先を確かめる口 (`RenderRequest.inspectOutput`・[#2481])。
/// GPU は要らない。
///
/// **頼みを無視して 0 で終わる古い子** (道具と依存の版のずれ) は、何も書かずに終わる。終了コードでは
/// 見分けられないので、書き出し先に頼んだものが揃っているかを見る。
///
/// [#2481]: https://github.com/mokume-metal/mokume/issues/2481
@Suite("書き出し先の確かめ")
struct RenderOutputCheckTests {
    private func image(_ level: UInt8) -> DisplayImage {
        DisplayImage(
            width: 64, height: 48, bytes: [UInt8](repeating: level, count: 64 * 48 * 4))
    }

    /// 検査のあいだだけ使う一時ディレクトリ。
    private func withDirectory(
        _ name: String, _ body: (URL) throws -> Void
    ) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// `frames` 枚の動画を本物の書き手で書く。
    private func writeMovie(_ path: String, frames: Int, frameRate: Int = 24) {
        let writer = MovieWriter(path: path, frameRate: frameRate)
        for frame in 1...frames {
            writer.write(
                image(UInt8(frame * 8)), frame: frame, time: Double(frame - 1) / Double(frameRate))
        }
        writer.finish()
    }

    private func request(_ destination: String, frames: Int, frameRate: Int = 24) throws
        -> RenderRequest
    {
        try #require(
            RenderRequest(frameRate: frameRate, frameCount: frames, destination: destination))
    }

    /// 前の回の残りに見せる: 更新時刻を 1 時間前へ戻す。
    private func makeStale(_ path: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: path)
    }

    // MARK: - .mov

    @Test("頼んだ枚数の動画が、この回に書かれていれば、揃っている")
    func aCompleteMovieIsAccepted() throws {
        try withDirectory("mokume-check-mov") { directory in
            let path = directory.appendingPathComponent("take.mov").path
            let start = Date()
            writeMovie(path, frames: 6)
            let shortfall = try request(path, frames: 6).inspectOutput(since: start)
            #expect(shortfall == nil)
        }
    }

    @Test("動画が無ければ、書かれていないと言う")
    func aMissingMovieIsNotWritten() throws {
        try withDirectory("mokume-check-mov-missing") { directory in
            let path = directory.appendingPathComponent("take.mov").path
            let shortfall = try request(path, frames: 6).inspectOutput(since: Date())
            #expect(shortfall == .notWritten)
        }
    }

    @Test("頼んだ枚数に足りない動画は、見つけた枚数を言う")
    func aShortMovieNamesWhatItHolds() throws {
        try withDirectory("mokume-check-mov-short") { directory in
            let path = directory.appendingPathComponent("take.mov").path
            let start = Date()
            writeMovie(path, frames: 4)
            let shortfall = try request(path, frames: 6).inspectOutput(since: start)
            #expect(shortfall == .frames(found: 4))
            // 多すぎるのも頼みと違う
            let tooMany = try request(path, frames: 3).inspectOutput(since: start)
            #expect(tooMany == .frames(found: 4))
        }
    }

    /// **前の回の残りを数えない。** 同じ行き先へ書き直す回に古い子が何も書かずに終わると、前の回の
    /// 動画が揃って見える。
    @Test("前の回に書かれた動画は、この回のものとして数えない")
    func aMovieLeftByAnEarlierRunIsNotThisRuns() throws {
        try withDirectory("mokume-check-mov-stale") { directory in
            let path = directory.appendingPathComponent("take.mov").path
            writeMovie(path, frames: 6)
            try makeStale(path)
            let shortfall = try request(path, frames: 6).inspectOutput(since: Date())
            #expect(shortfall == .notWritten)
        }
    }

    @Test("動画として読めないファイルは、読めないと言う")
    func aFileThatIsNotAMovieIsUnreadable() throws {
        try withDirectory("mokume-check-mov-garbage") { directory in
            let path = directory.appendingPathComponent("take.mov").path
            let start = Date()
            try Data("not a movie".utf8).write(to: URL(fileURLWithPath: path))
            let shortfall = try request(path, frames: 6).inspectOutput(since: start)
            #expect(shortfall == .unreadable)
        }
    }

    // MARK: - 連番

    private func writeFrames(_ names: [String], in directory: URL) throws {
        for name in names {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    @Test("頼んだ枚数の連番が、この回に書かれていれば、揃っている")
    func aCompleteSeriesIsAccepted() throws {
        try withDirectory("mokume-check-seq") { directory in
            let start = Date()
            try writeFrames(["f-000.png", "f-001.png", "f-002.png"], in: directory)
            let destination = directory.appendingPathComponent("f-###.png").path
            let shortfall = try request(destination, frames: 3).inspectOutput(since: start)
            #expect(shortfall == nil)
        }
    }

    @Test("連番が途中で途切れていれば、途切れるまでの枚数を言う")
    func aSeriesWithAGapNamesWhereItStops() throws {
        try withDirectory("mokume-check-seq-gap") { directory in
            let start = Date()
            // 2 枚目 (f-001) が無い。そこで数えるのをやめるので、後ろの f-002 は数えない
            try writeFrames(["f-000.png", "f-002.png"], in: directory)
            let destination = directory.appendingPathComponent("f-###.png").path
            let shortfall = try request(destination, frames: 3).inspectOutput(since: start)
            #expect(shortfall == .leadingFrames(found: 1))
        }
    }

    @Test("連番が 1 枚も無ければ 0 枚と言う")
    func anEmptyDirectoryHoldsNoFrames() throws {
        try withDirectory("mokume-check-seq-none") { directory in
            let destination = directory.appendingPathComponent("f-###.png").path
            let shortfall = try request(destination, frames: 3).inspectOutput(since: Date())
            #expect(shortfall == .leadingFrames(found: 0))
        }
    }

    /// **欠けた所で打ち切る。** 何も書かれていない回に、頼んだ枚数ぶん (最大 `Int32.max`) 調べ続けない。
    /// 打ち切らない実装は、この枚数のファイルを 1 つずつ調べて戻らない。
    @Test("何も書かれていなければ、最初の 1 枚で打ち切って戻る")
    func anEmptyPlaceIsCheckedOnce() throws {
        try withDirectory("mokume-check-seq-huge") { directory in
            let destination = directory.appendingPathComponent("f-#.png").path
            let started = Date()
            let shortfall = try request(destination, frames: 5_000_000).inspectOutput(
                since: Date())
            #expect(shortfall == .leadingFrames(found: 0))
            #expect(Date().timeIntervalSince(started) < 2, "欠けていても調べ続けている")
        }
    }

    @Test("前の回に書かれた連番や、中身の無いファイルは数えない")
    func staleOrEmptyFramesAreNotCounted() throws {
        try withDirectory("mokume-check-seq-stale") { directory in
            try writeFrames(["f-000.png", "f-001.png"], in: directory)
            try makeStale(directory.appendingPathComponent("f-001.png").path)
            // 空のファイルは、絵が入っていない
            try Data().write(to: directory.appendingPathComponent("f-002.png"))
            let start = Date().addingTimeInterval(-10)
            let destination = directory.appendingPathComponent("f-###.png").path
            let shortfall = try request(destination, frames: 3).inspectOutput(since: start)
            #expect(shortfall == .leadingFrames(found: 1))
            // 前の回の残りが先頭に在れば、先頭で止まる
            try makeStale(directory.appendingPathComponent("f-000.png").path)
            let stale = try request(destination, frames: 3).inspectOutput(since: start)
            #expect(stale == .leadingFrames(found: 0))
        }
    }
}
