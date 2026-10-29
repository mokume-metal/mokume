// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 1 本のファイルの書き手 (`.mov`・`.mp4`・`.gif`) は、**書き損じなく閉じ終えるまで、行き先にあったものに触れない**
/// ([#3426](https://github.com/mokume-metal/mokume/issues/3426))。
///
/// 書き手は行き先の隣の一時ファイルへ書き、閉じ終えたときだけ 1 回の置き換えで行き先に置く。**GPU は要らない** —
/// 出口が受け取る絵と時刻を ``MovieWriter`` へ直接渡し、行き先の中身 (バイト) と隣のファイルを見る。
@Suite("書き手は閉じ終えるまで行き先の前のファイルに触れない (#3426)")
struct OutputKeepsPreviousTests {
    /// 行き先に前の回から居た完成品の代わり。書き手が触れば変わる。
    private static let previous = Data("the previous finished movie".utf8)

    /// 試す書き手。`.mov` は符号化器の無い機械では外す。
    private static var kinds: [(name: String, format: MovieWriter.Format)] {
        var kinds: [(String, MovieWriter.Format)] = [("loop.gif", .gif), ("loop.mp4", .h264)]
        if MovieFile.isAvailable { kinds.insert(("motion.mov", .proRes4444), at: 0) }
        return kinds
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = try TestScratch.directory("mokume-keeps-previous")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func picture(_ index: Int, width: Int = 48, height: Int = 32) -> DisplayImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let inside = abs(x - (6 + index * 3)) < 5 && abs(y - height / 2) < 5
                bytes[offset] = inside ? 230 : UInt8(x * 255 / max(1, width - 1))
                bytes[offset + 1] = inside ? 60 : UInt8(y * 255 / max(1, height - 1))
                bytes[offset + 2] = 100
                bytes[offset + 3] = 255
            }
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    /// 行き先の隣にある、この行き先の一時ファイル (`AtomicFile` の名前の型)。
    private func temporaries(of destination: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) ?? []
        return names.filter { AtomicFile.writer(ofTemporary: $0, for: destination) != nil }
    }

    private func frameCount(atPath path: String) -> Int? {
        path.hasSuffix(".gif") ? GIFFile.frameCount(atPath: path) : MovieFile.videoSampleCount(atPath: path)
    }

    /// `until` が立つまで待つ (期限つき)。
    private func wait(upTo seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    // MARK: - 完了条件 1・2・9 (書いている間と、閉じ終えたとき)

    @Test("書いている間は行き先が前のままで、隣の一時ファイルへ書く。閉じ終えたら新しい動きに置き換わり、一時ファイルは残らない")
    func theDestinationKeepsThePreviousUntilTheClose() async throws {
        try await withDirectory { directory in
            for (name, format) in Self.kinds {
                let destination = directory.appendingPathComponent(name)
                try Self.previous.write(to: destination)
                let started = Date()
                let writer = MovieWriter(path: destination.path, frameRate: 25, format: format)
                for index in 0..<5 {
                    writer.write(picture(index), frame: index + 1, time: Double(index) / 25)
                }
                // 書いている間: 隣に一時ファイルができ、行き先は前の回のまま
                let appeared = await wait(upTo: 20) { !temporaries(of: destination).isEmpty }
                #expect(appeared, "\(name): 隣に一時ファイルができない")
                #expect(try Data(contentsOf: destination) == Self.previous, "\(name): 書いている間に行き先が変わった")

                writer.finish()
                #expect(writer.takeFailure() == nil, "\(name): 書き損じた")
                #expect(try Data(contentsOf: destination) != Self.previous, "\(name): 置き換わっていない")
                #expect(frameCount(atPath: destination.path) == 5, "\(name): 5 枚ではない")
                #expect(temporaries(of: destination).isEmpty, "\(name): 一時ファイルが残った: \(temporaries(of: destination))")
                // 前のファイルの更新日時を引き継がず、この回のもの (`mokume render` の事後の確かめが、この回のものと読む)
                let modified = try #require(
                    try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date)
                #expect(modified >= started.addingTimeInterval(-1), "\(name): 更新日時がこの回のものではない: \(modified)")
            }
        }
    }

    @Test("行き先が無かったなら、閉じ終えるまで無いままで、閉じたら置かれる")
    func anAbsentDestinationStaysAbsentUntilTheClose() async throws {
        try await withDirectory { directory in
            for (name, format) in Self.kinds {
                let destination = directory.appendingPathComponent("fresh-\(name)")
                let writer = MovieWriter(path: destination.path, frameRate: 25, format: format)
                for index in 0..<3 {
                    writer.write(picture(index), frame: index + 1, time: Double(index) / 25)
                }
                _ = await wait(upTo: 20) { !temporaries(of: destination).isEmpty }
                #expect(!FileManager.default.fileExists(atPath: destination.path), "\(name): 閉じる前に行き先ができた")
                writer.finish()
                #expect(writer.takeFailure() == nil)
                #expect(frameCount(atPath: destination.path) == 3)
            }
        }
    }

    @Test("255 まで作れる名前の行き先にも書ける (一時ファイルの名前を詰めるので、243〜255 の名前でも黙って書き損じにならない)")
    func theLongestNamesStillWrite() async throws {
        try await withDirectory { directory in
            for (name, format) in Self.kinds {
                let ext = String(name.drop { $0 != "." })
                for length in [243, 255] {
                    let long = String(repeating: "n", count: length - ext.count) + ext
                    #expect(FileNameLength.of(long) == length)
                    let destination = directory.appendingPathComponent(long)
                    try Self.previous.write(to: destination)
                    let writer = MovieWriter(path: destination.path, frameRate: 25, format: format)
                    for index in 0..<3 {
                        writer.write(picture(index), frame: index + 1, time: Double(index) / 25)
                    }
                    writer.finish()
                    #expect(writer.takeFailure() == nil, "\(ext) \(length): 書き損じた")
                    #expect(frameCount(atPath: destination.path) == 3, "\(ext) \(length): 置き換わっていない")
                    #expect(temporaries(of: destination).isEmpty, "\(ext) \(length): 一時ファイルが残った")
                }
            }
        }
    }

    // MARK: - 完了条件 4 (書き損じたとき)

    @Test("1 枚でも書き損じた録りは、行き先に置かず前のファイルを残す。失敗の行は行き先の名前と、前のファイルが残ったことを言う")
    func aFailedFrameLeavesThePreviousAndSaysSo() async throws {
        try await withDirectory { directory in
            for (name, format) in Self.kinds {
                let destination = directory.appendingPathComponent(name)
                try Self.previous.write(to: destination)
                let writer = MovieWriter(path: destination.path, frameRate: 25, format: format)
                for index in 0..<3 {
                    writer.write(picture(index), frame: index + 1, time: Double(index) / 25)
                }
                // 途中で大きさが変わった絵は、書き手が断る (書き損じ)。後の絵は書けても、この録りは置かない
                writer.write(picture(3, width: 20, height: 20), frame: 4, time: 3.0 / 25)
                writer.write(picture(4), frame: 5, time: 4.0 / 25)
                writer.finish()
                let failure = try #require(writer.takeFailure(), "\(name): 書き損じを名乗っていない")
                #expect(failure.contains(destination.path), "\(name): \(failure)")
                #expect(failure.contains("is left as it was"), "\(name): 前のファイルが残ったと言っていない: \(failure)")
                #expect(!failure.contains(".tmp"), "\(name): 一時ファイルの名前を出した: \(failure)")
                #expect(try Data(contentsOf: destination) == Self.previous, "\(name): 前のファイルが変わった")
                #expect(temporaries(of: destination).isEmpty, "\(name): 一時ファイルが残った")
            }
        }
    }

    @Test("行き先が無いまま書き損じたら、行き先は無いままで、一時ファイルも残らず、前のファイルが残ったとは言わない")
    func aFailedRecordingWithoutAPreviousLeavesNothing() async throws {
        try await withDirectory { directory in
            for (name, format) in Self.kinds {
                let destination = directory.appendingPathComponent("none-\(name)")
                let writer = MovieWriter(path: destination.path, frameRate: 25, format: format)
                writer.write(picture(0), frame: 1, time: 0)
                writer.write(picture(1, width: 20, height: 20), frame: 2, time: 1.0 / 25)
                writer.finish()
                let failure = try #require(writer.takeFailure())
                #expect(!failure.contains("left as it was"), "\(failure)")
                #expect(!FileManager.default.fileExists(atPath: destination.path), "\(name): 行き先ができた")
                #expect(temporaries(of: destination).isEmpty, "\(name): 一時ファイルが残った")
            }
        }
    }

    /// 本物の `MovieFile` を一時ファイルの段取りで開き、`images` を書いて閉じる。投げられた書き損じを返す。
    ///
    /// - Parameter whenClosed: 書き手が「済んだ」と言った直後、中身を確かめる前に呼ぶ手 (引数は書いた場所 =
    ///   一時ファイル)。本物の書き手では作れない形 (済んだのに空・置く直前に行き先が変わる) を差し込む。
    private nonisolated static func record(
        _ images: [DisplayImage], to path: String, format: MovieFile.Format = .h264,
        placement: AtomicFile.Placement, whenClosed: (@Sendable (String) -> Void)? = nil
    ) async -> MovieWriteFailure? {
        do {
            let width = images.first?.width ?? 48
            let height = images.first?.height ?? 32
            let file = try MovieFile(
                path: path, width: width, height: height, frameRate: 25, format: format, placement: placement)
            file.readsForTesting.closed = whenClosed
            for (index, image) in images.enumerated() { try await file.append(image, at: Double(index) / 25) }
            try await file.finish(lastFrameAt: Double(max(0, images.count - 1)) / 25)
            return nil
        } catch {
            return error
        }
    }

    @Test("閉じた後に空だったら、置かず前のファイルを残す (本物の書き手では作れない形は、閉じた直後に一時ファイルを切り詰めて差し込む)")
    func anEmptyCloseLeavesThePrevious() async throws {
        try await withDirectory { directory in
            let destination = directory.appendingPathComponent("empty.mp4")
            try Self.previous.write(to: destination)
            let placement = try AtomicFile.reserve(destination)
            let temporary = placement.temporary.path
            let failure = await Self.record(
                (0..<3).map { picture($0) }, to: destination.path, placement: placement,
                whenClosed: { path in
                    // 閉じた直後の確かめが読むのは、一時ファイル (行き先ではない)
                    #expect(path == temporary)
                    FileManager.default.createFile(atPath: path, contents: Data())
                })
            guard case .writeFailed(let path, let reason)? = failure else {
                Issue.record("空のファイルを書き損じにしなかった: \(String(describing: failure))")
                return
            }
            #expect(path == destination.path)
            #expect(reason.contains("without writing anything"), "\(reason)")
            #expect(try Data(contentsOf: destination) == Self.previous)
            #expect(temporaries(of: destination).isEmpty)
        }
    }

    @Test("1 枚も受け取らずに閉じても、前のファイルは残る")
    func closingWithoutAFrameLeavesThePrevious() async throws {
        try await withDirectory { directory in
            let destination = directory.appendingPathComponent("a.mp4")
            try Self.previous.write(to: destination)
            let failure = await Self.record([], to: destination.path, placement: try AtomicFile.reserve(destination))
            #expect(failure != nil, "1 枚も受け取らずに閉じられた")
            #expect(try Data(contentsOf: destination) == Self.previous)
            #expect(temporaries(of: destination).isEmpty)

            let gif = directory.appendingPathComponent("a.gif")
            try Self.previous.write(to: gif)
            let placement = try AtomicFile.reserve(gif)
            let gifFailure = await Self.closeEmptyGIF(path: gif.path, placement: placement)
            #expect(gifFailure != nil, "1 枚も受け取らずに閉じられた")
            #expect(try Data(contentsOf: gif) == Self.previous)
            #expect(temporaries(of: gif).isEmpty)
        }
    }

    private nonisolated static func closeEmptyGIF(path: String, placement: AtomicFile.Placement) async
        -> MovieWriteFailure?
    {
        do {
            let file = try GIFFile(path: path, frameRate: 25, placement: placement)
            try await file.finish(lastFrameAt: 0)
            return nil
        } catch {
            return error
        }
    }

    @Test("置く直前に行き先がディレクトリになっていたら、置き換えが断られ、ディレクトリの中身は無傷で、一時ファイルは残らず、縦横の名乗りも出ない")
    func aFailedPlacementTouchesNothing() async throws {
        try await withDirectory { directory in
            let destination = directory.appendingPathComponent("raced.mp4")
            let keep = destination.appendingPathComponent("keep.txt")
            let placement = try AtomicFile.reserve(destination)
            // 奇数の辺: 置けていれば縦横の名乗りが出る形
            let images = (0..<3).map { picture($0, width: 65, height: 49) }
            let (failure, said) = await Diagnostics.$digest.withValue(WarningDigest()) {
                let failure = await Self.record(
                    images, to: destination.path, placement: placement,
                    whenClosed: { _ in
                        // 書いている間に、別の主体が同じ場所へディレクトリを置いた
                        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                        try? Data("x".utf8).write(to: keep)
                    })
                return (failure, Diagnostics.takeUnreported())
            }
            guard case .writeFailed(let path, _)? = failure else {
                Issue.record("ディレクトリへ置いた: \(String(describing: failure))")
                return
            }
            #expect(path == destination.path)
            #expect(FileManager.default.fileExists(atPath: keep.path), "ディレクトリの中身が消えた")
            #expect(temporaries(of: destination).isEmpty, "一時ファイルが残った")
            #expect(said.isEmpty, "置けなかったのに縦横を名乗った: \(said)")
        }
    }

    // MARK: - 完了条件 7 (縦横の名乗りは置いた後に、行き先の名前で)

    @Test("縦横の名乗りは、置けたときだけ、行き先の名前で出る")
    func theSizeNoteNamesTheDestinationAfterPlacing() async throws {
        try await withDirectory { directory in
            let destination = directory.appendingPathComponent("odd.mp4")
            let placement = try AtomicFile.reserve(destination)
            let images = (0..<3).map { picture($0, width: 65, height: 49) }
            let (failure, said) = await Diagnostics.$digest.withValue(WarningDigest()) {
                let failure = await Self.record(images, to: destination.path, placement: placement)
                return (failure, Diagnostics.takeUnreported())
            }
            #expect(failure == nil, "\(String(describing: failure))")
            #expect(FileManager.default.fileExists(atPath: destination.path))
            // 名乗りは 1 行で、行き先の名前を言い、一時ファイルの名前は出ない
            #expect(said.count == 1 && said[0].hasPrefix(destination.path), "\(said)")
            #expect(said.allSatisfy { !$0.contains(".tmp") }, "\(said)")
        }
    }

    // MARK: - 完了条件 8 (ディレクトリ・シンボリックリンク)

    @Test("行き先がディレクトリなら、書き始める前に断り、中身に触れない")
    func aDirectoryDestinationIsRefusedUntouched() async throws {
        try await withDirectory { directory in
            for (name, format) in Self.kinds {
                let destination = directory.appendingPathComponent("dir-\(name)")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let keep = destination.appendingPathComponent("keep.txt")
                try Data("x".utf8).write(to: keep)
                let writer = MovieWriter(path: destination.path, frameRate: 25, format: format)
                writer.write(picture(0), frame: 1, time: 0)
                writer.finish()
                let failure = try #require(writer.takeFailure(), "\(name)")
                #expect(failure.contains("Is a directory"), "\(name): \(failure)")
                #expect(FileManager.default.fileExists(atPath: keep.path), "\(name): ディレクトリの中身が消えた")
                #expect(temporaries(of: destination).isEmpty)
            }
        }
    }

    @Test("行き先がシンボリックリンクなら、リンクが普通のファイルに置き換わり、指す先は変わらない (今と同じ)")
    func aSymlinkDestinationIsReplacedNotFollowed() async throws {
        try await withDirectory { directory in
            let target = directory.appendingPathComponent("target.bin")
            try Self.previous.write(to: target)
            let destination = directory.appendingPathComponent("link.mp4")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
            let writer = MovieWriter(path: destination.path, frameRate: 25, format: .h264)
            for index in 0..<3 {
                writer.write(picture(index), frame: index + 1, time: Double(index) / 25)
            }
            writer.finish()
            #expect(writer.takeFailure() == nil)
            #expect(try Data(contentsOf: target) == Self.previous, "指す先が書き換わった")
            let type = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
            #expect(type == .typeRegular, "リンクのままだ: \(String(describing: type))")
            #expect(MovieFile.videoSampleCount(atPath: destination.path) == 3)
        }
    }

    // MARK: - 完了条件 5 (子が落ちたとき)

    @Test("落ちた書き手の一時ファイルは、次に同じ名前へ書く回が片付け、行き先は落ちる前のまま")
    func anAbandonedTemporaryIsSweptByTheNextRecording() async throws {
        try await withDirectory { directory in
            let destination = directory.appendingPathComponent("crashed.mp4")
            try Self.previous.write(to: destination)
            // 居ないプロセスの番号 (pid) を名前に持つ一時ファイル。落とされた書き手が残したもの
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try child.run()
            child.waitUntilExit()
            let deadPid = child.processIdentifier
            let stale = AtomicFile.temporaryURL(for: destination, writer: deadPid, sequence: 1)
            try Data("half a movie".utf8).write(to: stale)
            #expect(AtomicFile.writer(ofTemporary: stale.lastPathComponent, for: destination) == deadPid)

            let writer = MovieWriter(path: destination.path, frameRate: 25, format: .h264)
            AtomicFile.settleSweeps()
            #expect(!FileManager.default.fileExists(atPath: stale.path), "落ちた書き手の一時ファイルが片付かない")
            #expect(try Data(contentsOf: destination) == Self.previous, "行き先が落ちる前と変わった")
            for index in 0..<3 {
                writer.write(picture(index), frame: index + 1, time: Double(index) / 25)
            }
            writer.finish()
            #expect(writer.takeFailure() == nil)
        }
    }
}
