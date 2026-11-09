// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// 見張りの下では道具が目録へ名乗る ([ADR-0049] 決定 2・[#3919])。
///
/// 名乗りは本物 (bootstrap へ登録し、検査の置き場へ目録を置く)。台の知らせ (``WatchFrameListing/follow(_:)``) は
/// 手で渡す — 台が名乗りの中身を読む形は `SharedFrameStageTests` が持つ。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3919]: https://github.com/mokume-metal/mokume/issues/3919
@Suite("見張りの名乗り")
@MainActor
struct WatchFrameListingTests {
    private func makeListing(in directory: URL) -> WatchFrameListing {
        WatchFrameListing(identity: "/work/Bricks") { identity, share in
            FrameAnnouncement.announce(
                sketch: share.sketch, identity: identity, title: share.title, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") })
        }
    }

    @Test("映す世代が断っていなければ名乗り、保存で子が 3 回入れ替わっても項目は 1 件で名前も変わらない")
    func generationsKeepOneEntry() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        defer { listing.withdraw() }
        let share = FrameShare(sketch: "Bricks", title: "Bricks and ball")

        listing.follow(share)
        let first = try #require(FrameListing.entries(in: directory).first)
        #expect(first.sketch == "Bricks")
        #expect(first.identity == "/work/Bricks")
        #expect(first.pid == getpid(), "名乗るのは道具のプロセス")

        // 世代ごとに同じ中身の絵が届く (3 回の保存)
        for _ in 0..<3 {
            for _ in 0..<5 { listing.follow(share) }
        }
        let entries = FrameListing.entries(in: directory)
        #expect(entries.count == 1)
        #expect(entries.first?.serviceName == first.serviceName, "入れ替えで名前が変わった")

        // 題を書き換えて保存しても、名前は変わらない
        listing.follow(FrameShare(sketch: "Bricks", title: "Renamed"))
        #expect(FrameListing.entries(in: directory).map(\.title) == ["Renamed"])
        #expect(FrameListing.entries(in: directory).map(\.serviceName) == [first.serviceName])
    }

    @Test("新しい世代が断れば下ろし、断らない世代が来ればまた名乗る")
    func aRefusingGenerationWithdraws() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        defer { listing.withdraw() }
        let share = FrameShare(sketch: "Bricks", title: "Bricks and ball")
        listing.follow(share)
        let name = try #require(FrameListing.entries(in: directory).first?.serviceName)

        listing.follow(nil)
        #expect(FrameListing.entries(in: directory).isEmpty, "断った世代なのに目録に残っている")
        #expect(Bootstrap.lookUp(name).map { Bootstrap.releaseSend($0) } == nil, "名前を手放していない")

        listing.follow(share)
        #expect(FrameListing.entries(in: directory).count == 1)
    }

    @Test("子が自分のウィンドウへ倒れたら下ろし (倒れた子が名乗る)、共有面へ戻った世代の絵が来ればまた名乗る")
    func aFallenChildTakesOver() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        defer { listing.withdraw() }
        let share = FrameShare(sketch: "Bricks", title: "Bricks and ball")
        listing.follow(share)

        listing.fellBack()
        #expect(FrameListing.entries(in: directory).isEmpty, "倒れた子と道具の名乗りが 2 つ並ぶ")

        listing.follow(share)
        #expect(FrameListing.entries(in: directory).count == 1)
    }

    @Test("断っている世代 (名乗りの中身が無い) しか来なければ、1 度も名乗らない")
    func neverAnnouncesWithoutAShare() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        listing.follow(nil)
        listing.follow(nil)
        #expect(listing.announcement == nil)
        #expect(FrameListing.entries(in: directory).isEmpty)
    }
}
