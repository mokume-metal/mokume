// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation
import Synchronization
import Testing

@testable import MokumeCore

/// 器を取れなかった枚は、writer が転んでいれば writer の理由で書き損じになる ([#2944])。
///
/// `MovieFile.append` は writer が `.writing` であることを確かめてから画素の器の池を取る。確かめた直後に
/// writer が転ぶと、池は `nil` になり器も借りられない。本物の writer ではその瞬間を決まった所に作れない
/// (転ぶのは符号化器の側で、いつ起きるかは負荷しだい) ので、読む所だけを差し替える
/// (``MovieFile/Reads``)。**GPU は要らない。**
///
/// [#2944]: https://github.com/mokume-metal/mokume/issues/2944
@Suite(
    "止まった writer へ書く枚の理由",
    .serialized,
    .enabled(if: MovieFile.isAvailable, "この機械には ProRes 4444 の符号化器が無い")
)
nonisolated struct MovieFileReadsTests {
    private static let reason = "Disk Full (injected)"

    /// 一色で塗った 1 枚。
    private func image(width: Int = 64, height: Int = 48) -> DisplayImage {
        DisplayImage(
            width: width, height: height,
            bytes: [UInt8](repeating: 120, count: width * height * 4))
    }

    /// 本物の `MovieFile` を開き、`body` の後に必ず閉じる。
    private func withMovieFile(
        _ body: (MovieFile, String) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-movie-reads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reads.mov").path
        let file = try MovieFile(path: path, width: 64, height: 48, frameRate: 30)
        do {
            try await body(file, path)
        } catch {
            try? await file.finish(lastFrameAt: 0)
            throw error
        }
        try? await file.finish(lastFrameAt: 0)
    }

    /// 1 枚書き足して、投げられた失敗を返す。投げなければ `nil`。
    private func failure(of file: MovieFile) async -> MovieWriteFailure? {
        do {
            try await file.append(image(), at: 0)
            return nil
        } catch {
            return error
        }
    }

    /// 状態を `.writing` と読ませ、**池を取りに行った瞬間に** 転んだことにする箱。
    private final class Tripwire: Sendable {
        private let tripped = Mutex(false)
        var status: AVAssetWriter.Status { tripped.withLock { $0 } ? .failed : .writing }
        func trip() { tripped.withLock { $0 = true } }
    }

    @Test("確かめた後に writer が転んで池が無くなれば、bufferUnavailable ではなく writer の理由で書き損じになる")
    func aVanishedPoolAfterTheCheckCarriesTheWritersReason() async throws {
        try await withMovieFile { file, path in
            let wire = Tripwire()
            file.reads.status = { wire.status }
            file.reads.reason = { Self.reason }
            // 状態を確かめた直後に池を取りに来る。その瞬間に転び、池は無い
            file.reads.pool = {
                wire.trip()
                return nil
            }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
        }
    }

    @Test("確かめた後に writer が転んで器を借りられなければ、bufferUnavailable ではなく writer の理由で書き損じになる")
    func aRefusedBorrowAfterTheCheckCarriesTheWritersReason() async throws {
        try await withMovieFile { file, path in
            let wire = Tripwire()
            file.reads.status = { wire.status }
            file.reads.reason = { Self.reason }
            file.reads.borrow = { _ in
                wire.trip()
                return nil
            }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
        }
    }

    @Test("writer が .writing のまま池が無ければ、これまでどおり bufferUnavailable")
    func aMissingPoolOnAHealthyWriterIsStillBufferUnavailable() async throws {
        try await withMovieFile { file, _ in
            file.reads.pool = { nil }
            #expect(await failure(of: file) == .bufferUnavailable)
        }
    }

    @Test("writer が .writing のまま器を借りられなければ、これまでどおり bufferUnavailable")
    func aRefusedBorrowOnAHealthyWriterIsStillBufferUnavailable() async throws {
        try await withMovieFile { file, _ in
            file.reads.borrow = { _ in nil }
            #expect(await failure(of: file) == .bufferUnavailable)
        }
    }

    @Test("差し込まなければ本物を読み、健やかな writer へは書き足せる")
    func withoutReadsTheRealWriterTakesTheFrame() async throws {
        try await withMovieFile { file, _ in
            #expect(await failure(of: file) == nil)
        }
    }
}
