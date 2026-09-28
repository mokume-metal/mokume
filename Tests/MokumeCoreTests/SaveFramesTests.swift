// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing

@testable import MokumeCore

/// 連番の名前の組み立て。GPU を要さない。
@Suite("連番の名前")
struct FrameSequenceTests {
    @Test("# の並びが番号の桁になる")
    func hashRunBecomesTheDigits() {
        var sequence = FrameSequence(pattern: "out/frame-####.png")
        #expect(sequence?.prefix == "out/frame-")
        #expect(sequence?.digits == 4)
        #expect(sequence?.suffix == ".png")
        #expect(sequence?.next() == "out/frame-0000.png")
        #expect(sequence?.next() == "out/frame-0001.png")
    }

    @Test("桁が揃うので、名前順が撮った順になる")
    func namesSortInCaptureOrder() {
        var sequence = FrameSequence(pattern: "f-###.png")!
        let names = (0..<12).map { _ in sequence.next() }
        #expect(names == names.sorted())
        #expect(names.first == "f-000.png")
        #expect(names.last == "f-011.png")
    }

    @Test("桁に収まらなくなったら、切り詰めずに伸びる")
    func numbersGrowRatherThanTruncate() {
        var sequence = FrameSequence(pattern: "f-#.png")!
        for _ in 0..<10 { _ = sequence.next() }
        // 9 の次は 10。切り詰めると 0 に戻り、撮った絵を黙って失う
        #expect(sequence.next() == "f-10.png")
    }

    @Test("番号の入る場所が無い名前は組み立てない")
    func aPatternWithoutAPlaceForTheNumberIsRefused() {
        #expect(FrameSequence(pattern: "out/frame.png") == nil)
    }
}

/// 書き出す係。GPU を要さない。
@Suite("書き出しの背圧")
struct FrameWriterTests {
    @Test("抱える枚数が上限を超えず、上限までは抱える")
    func theQueueFillsUpToTheLimitAndNoFurther() throws {
        try withTemporaryDirectory("mokume-frame-writer") { directory in
            let writer = FrameWriter(limit: 2)
            // 1 枚あたり 256 KB。書き込みが即座には終わらない大きさにして、
            // 頼む側が上限に当たる状況を作る
            let image = DisplayImage(
                width: 256, height: 256, bytes: [UInt8](repeating: 128, count: 256 * 256 * 4))

            for index in 0..<24 {
                writer.write(image, to: directory.appendingPathComponent("f-\(index).png").path)
                // 上限を超えて抱えたら、長い連番でメモリが伸び続けることになる
                #expect(writer.outstanding <= writer.limit)
            }
            #expect(writer.peakOutstanding == writer.limit)

            writer.drain()
            for index in 0..<24 {
                let url = directory.appendingPathComponent("f-\(index).png")
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
            // **行き先ごとの順番待ちの控えも残らない** (#1627)。控えは仕事が終わった直後に
            // 消えるので、枠が返った後の少しの間だけ残りうる
            #expect(
                pollUntilSettled(within: 10) {
                    (0..<24).allSatisfy {
                        !FrameWriter.isBusy(directory.appendingPathComponent("f-\($0).png").path)
                    }
                },
                "書き終えた行き先の控えが残っている — 長い連番で伸び続ける")
        }
    }

    @Test("drain から返った時点で、頼んだ全部がファイルになっている")
    func drainReturnsOnlyAfterEveryFileExists() throws {
        try withTemporaryDirectory("mokume-frame-writer-drain") { directory in
            let writer = FrameWriter()
            let image = DisplayImage(
                width: 8, height: 8, bytes: [UInt8](repeating: 200, count: 8 * 8 * 4))
            for index in 0..<10 {
                writer.write(image, to: directory.appendingPathComponent("f-\(index).png").path)
            }
            writer.drain()

            // 「書き始めた」だけで返る形だと、ここが偽になる
            let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(written.count == 10)
            #expect(writer.outstanding == 0)
        }
    }

    /// **同じ行き先へ続けて頼むと、頼んだ順に書き、最後に頼んだ絵が残る** ([#1627])。
    ///
    /// 書き込みは 1 枚ずつフレームの外で走り、決着の順は機械の混み具合で決まる。同じ名前へ
    /// 毎フレーム `save()` すると、後に頼んだ絵が先に書き終わり、前の絵が後から置き換える
    /// ことがあった (混ませた機械で 20 試行中 7〜13 回)。**崩れる状況を書く関数の側で作る** —
    /// 1 枚目を、2 枚目が書き終えるまで (期限つきで) 止めておく。順序を保たない書き方なら
    /// 2 枚目が先に書き終わり、1 枚目が後から置き換える。
    ///
    /// 同じファイルを指す別の綴り (`sub/../`・途中のシンボリックリンク・大文字と小文字)
    /// と、撮る係を作り直した後の別の書き手からの頼みも、同じ行き先として扱う。
    ///
    /// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
    @Test(
        "同じ行き先へ続けて頼むと、頼んだ順に書き、最後に頼んだ絵が残る",
        arguments: ["同じ綴り", "sub/../", "シンボリックリンク", "大文字と小文字", "別の書き手"])
    func writesToOnePathSettleInTheOrderAsked(_ spelling: String) throws {
        try withTemporaryDirectory("mokume-frame-writer-order") { directory in
            let tracker = try EncodeTracker(directory, levels: 2)
            let secondEnded = DispatchSemaphore(value: 0)
            let encode: FrameWriter.Encode = { image, url in
                try tracker.write(image, to: url) { which in
                    // **待つ側が期限を持つ。** 順序を保つ書き方では 2 枚目は 1 枚目の後にしか
                    // 始まらないので、ここは期限まで待って抜ける
                    if which == 1 { _ = secondEnded.wait(timeout: .now() + 0.5) }
                } after: { which in
                    if which == 2 { secondEnded.signal() }
                }
            }
            let writer = FrameWriter(encode: encode)
            let path = directory.appendingPathComponent("latest.png").path
            var again = path
            var second = writer
            switch spelling {
            case "sub/../": again = directory.appendingPathComponent("sub/../latest.png").path
            case "シンボリックリンク":
                let link = directory.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
                again = link.appendingPathComponent("latest.png").path
            case "大文字と小文字":
                let values = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                // 区別するボリュームでは別のファイルなので、この綴りは同じ行き先ではない
                guard values.volumeSupportsCaseSensitiveNames == false else { return }
                again = directory.appendingPathComponent("LATEST.png").path
            case "別の書き手": second = FrameWriter(encode: encode)
            default: break
            }

            writer.write(level(1), to: path)
            second.write(level(2), to: again)
            writer.drain()
            second.drain()

            #expect(tracker.events == [.start(1), .end(1), .start(2), .end(2)], "頼んだ順に書いていない")
            #expect(try tracker.content(of: path) == 2, "前の絵が後から置き換えた")
            #expect(writer.takeFailure() == nil)
        }
    }

    /// **書いている間に同じ行き先へ頼まれたものは、最後の 1 つに畳み、頼む側を待たせない** ([#1627])。
    ///
    /// 前の書き込みの後ろに並べて待たせると、同じ名前へ毎フレーム書く使い方でフレームの速さが
    /// 1 枚を書く時間で決まり、1 本返らない書き込みがあるだけで背圧の枠が埋まって頼む側
    /// (main actor) が止まる。1 枚目を止めたまま同じ行き先へ上限の何倍も頼み、**止めている間に
    /// 頼み終えられる**ことを見る。並べて待たせる形では、上限に達したところで 1 枚目の期限
    /// (10 秒) まで返らない。
    ///
    /// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
    @Test("同じ行き先へ書いている間の頼みは最後の 1 つに畳み、頼む側を待たせない")
    func writesQueuedBehindAStuckOneAreFoldedWithoutBlocking() throws {
        try withTemporaryDirectory("mokume-frame-writer-fold") { directory in
            let count = FrameWriter.defaultLimit * 3
            let tracker = try EncodeTracker(directory, levels: count)
            let unstuck = DispatchSemaphore(value: 0)
            let timedOut = Mutex(false)
            let writer = FrameWriter { image, url in
                try tracker.write(image, to: url) { which in
                    guard which == 1 else { return }
                    let answered = unstuck.wait(timeout: .now() + 10) == .success
                    timedOut.withLock { $0 = !answered }
                } after: { _ in }
            }
            let path = directory.appendingPathComponent("latest.png").path

            for index in 1...count { writer.write(level(UInt8(index)), to: path) }
            // ここまで来られた = 1 枚目が止まっている間に頼み終えた
            unstuck.signal()
            writer.drain()

            #expect(timedOut.withLock { $0 } == false, "止まった 1 枚の後ろで、頼む側が待たされた")
            #expect(tracker.events == [.start(1), .end(1), .start(count), .end(count)], "間の頼みを畳んでいない")
            #expect(try tracker.content(of: path) == count, "最後に頼んだ絵が残っていない")
            #expect(writer.outstanding == 0, "畳んだ頼みの枠が返っていない")
        }
    }

    /// **違う行き先どうしは待ち合わない** ([#1627])。順序を保つのは同じ行き先の中だけで、
    /// 連番のように毎回違う名前へ書くときは、今までどおり背圧の上限まで並行に書く。
    ///
    /// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
    @Test("違う行き先への書き込みは、前の書き込みの終わりを待たない")
    func writesToDifferentPathsDoNotWaitForEachOther() throws {
        try withTemporaryDirectory("mokume-frame-writer-parallel") { directory in
            let secondEnded = DispatchSemaphore(value: 0)
            let firstSawTheSecond = Mutex<Bool?>(nil)
            let writer = FrameWriter { _, url in
                switch url.lastPathComponent {
                case "a.png":
                    // 2 枚目が並行に走れば、すぐに合図が来る。1 本ずつ書く形なら期限まで来ない
                    let answered = secondEnded.wait(timeout: .now() + 10) == .success
                    firstSawTheSecond.withLock { $0 = answered }
                default: secondEnded.signal()
                }
            }
            writer.write(level(1), to: directory.appendingPathComponent("a.png").path)
            writer.write(level(2), to: directory.appendingPathComponent("b.png").path)
            writer.drain()

            #expect(firstSawTheSecond.withLock { $0 } == true, "違う行き先の書き込みが、前の書き込みを待った")
        }
    }

    /// 1 画素の絵。**最初のバイトで何枚目かを見分ける** (書く関数を差し替えた検査が読む)。
    private func level(_ value: UInt8) -> DisplayImage {
        DisplayImage(width: 1, height: 1, bytes: [value, value, value, 255])
    }

    @Test("途中のディレクトリは頼まれた側が作る")
    func missingDirectoriesAreCreated() throws {
        try withTemporaryDirectory("mokume-frame-writer-mkdir") { directory in
            let writer = FrameWriter()
            let url = directory.appendingPathComponent("a/b/c/f.png")
            writer.write(
                DisplayImage(
                    width: 2, height: 2, bytes: [UInt8](repeating: 255, count: 2 * 2 * 4)),
                to: url.path)
            writer.drain()
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

/// 差し替えた書く関数の中身。何枚目の書き込みがいつ始まり、いつ終わったかを記す。
/// **フレームの外から書かれる**ので錠で守る。
///
/// 書く関数は隔離の外で走り、絵の中身を直接は読めない (`DisplayImage` は main actor に属する)
/// ので、1 枚ずつ PNG にしてから、先に作った見本と突き合わせて何枚目かを見分ける。
private nonisolated final class EncodeTracker: Sendable {
    enum Event: Equatable, Sendable {
        case start(Int)
        case end(Int)
    }

    private let directory: URL
    /// n 枚目 (1 から) の見本の PNG。
    private let pictures: [Data]
    private let state = Mutex<[Event]>([])

    @MainActor
    init(_ directory: URL, levels: Int) throws {
        self.directory = directory
        pictures = try (1...levels).map { level in
            let url = directory.appendingPathComponent("expected-\(level).png")
            try PNGFile.write(
                DisplayImage(width: 1, height: 1, bytes: [UInt8(level), UInt8(level), UInt8(level), 255]),
                to: url)
            return try Data(contentsOf: url)
        }
    }

    var events: [Event] { state.withLock { $0 } }

    /// 行き先に残っている絵が何枚目か。見本に無ければ 0。
    func content(of path: String) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return pictures.firstIndex(of: data).map { $0 + 1 } ?? 0
    }

    /// ImageIO と同じく、別の名前に書いてから置き換える (#1341)。置き換える直前と直後に
    /// 検査の差し込みを呼ぶ。
    func write(
        _ image: DisplayImage, to url: URL, before: (Int) -> Void, after: (Int) -> Void
    ) throws {
        let staged = directory.appendingPathComponent("\(UUID().uuidString).staged")
        try PNGFile.write(image, to: staged)
        let which = pictures.firstIndex(of: try Data(contentsOf: staged)).map { $0 + 1 } ?? 0
        state.withLock { $0.append(.start(which)) }
        before(which)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        state.withLock { $0.append(.end(which)) }
        after(which)
    }
}

/// 終わるときに残っていた書き損じ ([#789])。GPU を要さない。
///
/// ``FrameRecorder/close()`` は**最後の呼び出し**なので、ここで読まなかったものを
/// 読む ``FrameRecorder/receive(_:)`` はもう来ない。
///
/// [#789]: https://github.com/mokume-metal/mokume/issues/789
@Suite("終わるときの書き損じ")
struct ClosingFailureTests {
    @Test("close() は、最後まで残った書き損じを言う")
    func closeSpeaksTheFailureNobodyElseWillRead() throws {
        try withTemporaryDirectory("mokume-close-still-failure") { directory in
            // 書き先の親をファイルにしておく。ディレクトリを作ることも書くこともできない
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            recorder.writer.write(
                DisplayImage(width: 8, height: 8, bytes: [UInt8](repeating: 200, count: 8 * 8 * 4)),
                to: blocker.appendingPathComponent("last.png").path)

            recorder.close()

            let said = try #require(
                recorder.warnings.message(for: .imageFailure),
                "撮り終わりの書き損じが誰にも読まれていない")
            #expect(said.contains("last.png"))
        }
    }

    @Test("close() は、絵を貰えないまま終わった save() の予約を言う")
    func closeSpeaksTheSavesThatNeverGotAPicture() throws {
        let recorder = FrameRecorder()
        recorder.save("out/never.png", at: 1)

        recorder.close()

        let said = try #require(
            recorder.warnings.message(for: .unwrittenShots),
            "果たせなかった save() の予約が、誰にも知らされていない")
        #expect(said.contains("never.png"))
    }
}

/// 書き損じの知らせが遅れて届くときの数え方 ([#1272])。GPU を要さない。
///
/// 書き込みは隔離の外で走るので、知らせが次のフレームに間に合わないことがある。
/// **まだ決着していないことを「順調」と数えると**、転び続ける出口が負荷の下で外れない。
/// ``FrameRecorder/receive(_:)`` は絵を要するので、その先頭で呼ばれる
/// ``FrameRecorder/absorbOutcomes()`` を直接呼んでフレームの代わりにする。
///
/// [#1272]: https://github.com/mokume-metal/mokume/issues/1272
@Suite("書き損じの知らせが遅れるとき")
struct LateFailureTests {
    private let picture = DisplayImage(
        width: 8, height: 8, bytes: [UInt8](repeating: 200, count: 8 * 8 * 4))

    /// **流れ (連番) の性質である。** `save()` の 1 枚ものは流れではないので保たない
    /// (下の ``aSettledOneOffFailureIsCountedOnce()``・[#1626])。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    @Test("連番を撮っている間は、まだ決着していないフレームでも前の書き損じを保つ")
    func aFrameWithNoNewsKeepsTheLastFailure() throws {
        try withTemporaryDirectory("mokume-late-failure-kept") { directory in
            // 書き先の親をファイルにしておく。ディレクトリを作ることも書くこともできない
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            recorder.beginRecord(blocker.appendingPathComponent("f-##.png").path, at: 1)
            // 連番の 1 枚 (連番の器へ決着する)
            recorder.writer.write(picture, to: blocker.appendingPathComponent("a.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()
            #expect(recorder.failure?.contains("a.png") == true)

            // 次の書き込みがまだ決着していないフレーム。ここで `nil` に戻すと、
            // 差込口の健康状態は「順調」と読んで数えを 0 に戻す
            recorder.absorbOutcomes()
            #expect(recorder.failure?.contains("a.png") == true, "知らせが無いだけで直ったことになっている")

            recorder.close()
        }
    }

    /// **1 度きりの書き損じは、1 回数えて名乗ったら下ろす** ([#1626])。
    ///
    /// 動画だけを撮っている間は、決着した `save()` の後に静止画の書き込みが来ない。保ったままに
    /// すると以後のフレームすべてで「続けて転んだ」と数えられ、3 フレームで撮る係ごと外れて、
    /// 同居している動画が途切れた。差込口の健康状態 (``SeamHealth``) を実際に回して、外れない
    /// ことまで見る。
    ///
    /// **別の `save()` がまだ決着していないことは、保つ理由にならない** (反証 1)。「後に書き込みが
    /// 来る間は保つ」形では、転んだ `save()` の直後に頼んだ `save()` の書き込みが遅いと、同じ 1 回の
    /// 失敗が 2 回・3 回と数えられて外れた。次の `save()` の予約を残したまま回す。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    @Test("1 度きりの save() の書き損じは、次の save() が控えていても 1 回数えて名乗ったら持ち越さない")
    func aSettledOneOffFailureIsCountedOnce() throws {
        try withTemporaryDirectory("mokume-late-failure-once") { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            // 動画だけを撮っている。1 フレームも書かないので、符号化器は要らない
            recorder.beginRecord(directory.appendingPathComponent("motion.mov").path, at: 1)
            // 撮っている最中の `save()` の 1 枚 (予約は配られて書き込みに回った後)
            recorder.writeShot(picture, to: blocker.appendingPathComponent("still.png").path)
            recorder.writer.drain()
            // 次の `save()` がまだ控えている
            recorder.save(directory.appendingPathComponent("next.png").path, at: 99)

            var health = SeamHealth()
            recorder.absorbOutcomes()
            #expect(recorder.failure?.contains("still.png") == true, "決着したフレームで数えていない")
            _ = health.note(recorder.failure)
            // **黙らない。** 外れないので、外したときの診断は出ない
            #expect(recorder.hasFailedToWrite)
            let said = try #require(
                recorder.warnings.message(for: .imageFailure), "1 度きりの書き損じを誰にも言っていない")
            #expect(said.contains("still.png"))

            for _ in 0..<SeamHealth.limit + 2 {
                recorder.absorbOutcomes()
                _ = health.note(recorder.failure)
            }
            #expect(recorder.failure == nil, "後に何も来ない書き損じを持ち越している")
            #expect(health.isAttached, "1 度きりの書き損じで、撮る係ごと外れた")

            recorder.close()
        }
    }

    /// **読まれていない書き損じは、後の成功で消えない** ([#1626])。
    ///
    /// 知らせの器は 1 つなので、同じフレームに頼んだ 2 枚 (`save` を 2 つ・連番と `save`) の
    /// 転んだほうが先に決着し、後に書けたほうが上書きすると、誰も名乗らず穴も残らなかった。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    @Test("同じ間に書き損じと書けたものが決着しても、書き損じが読まれる")
    func aFailureIsNotOverwrittenByALaterSuccess() throws {
        try withTemporaryDirectory("mokume-late-failure-overwritten") { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            // 転ぶほうを先に決着させてから、書けるほうを決着させる
            recorder.writer.write(picture, to: blocker.appendingPathComponent("a.png").path)
            recorder.writer.drain()
            recorder.writer.write(picture, to: directory.appendingPathComponent("b.png").path)
            recorder.writer.drain()

            recorder.absorbOutcomes()
            #expect(recorder.failure?.contains("a.png") == true, "後の成功に上書きされて、書き損じが読まれていない")
            #expect(recorder.hasFailedToWrite)
            #expect(recorder.warnings.message(for: .imageFailure)?.contains("a.png") == true)
        }
    }

    @Test("書けたことが決着したら、書き損じは消える")
    func aSettledSuccessClearsTheFailure() throws {
        try withTemporaryDirectory("mokume-late-failure-cleared") { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            recorder.writer.write(picture, to: blocker.appendingPathComponent("a.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()
            #expect(recorder.failure != nil)

            // 持ち越しが消えないと、直った出口まで続けて転んだことにされる
            recorder.writer.write(picture, to: directory.appendingPathComponent("b.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()
            #expect(recorder.failure == nil)
        }
    }

    /// **並びへ戻るときは、暇だったかによらず仕切り直す** ([#1626])。
    ///
    /// 並びへ入れ直すのは ``SketchRuntime`` で、健康状態を作り直すのと同じ時点で
    /// ``FrameRecorder/startAfresh()`` を呼ぶ。ここではその呼び出しを直接行う。「録っている
    /// 最中」は、続けて転んで外された後に `save()` で戻る形である — 暇ではないので、暇かで
    /// 決めていた頃は前の書き損じを持ち越して、戻った直後に 1 回ぶん数えていた。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    @Test(
        "並びへ戻るときは、前の書き損じを持ち越さない",
        arguments: ["暇から save", "暇から beginRecord", "録っている最中に save"])
    func rejoiningStartsAfresh(_ how: String) throws {
        try withTemporaryDirectory("mokume-late-failure-afresh") { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            if how == "録っている最中に save" {
                recorder.beginRecord(directory.appendingPathComponent("motion.mov").path, at: 1)
            }
            // 1 つ目の書き損じは載せ替え済み、2 つ目は外れている間に決着して口に残っている
            // (連番の器と 1 枚ものの器の両方)
            recorder.writer.write(picture, to: blocker.appendingPathComponent("a.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()
            recorder.writer.write(picture, to: blocker.appendingPathComponent("b.png").path)
            recorder.writeShot(picture, to: blocker.appendingPathComponent("b2.png").path)
            recorder.writer.drain()

            switch how {
            case "暇から beginRecord":
                recorder.beginRecord(directory.appendingPathComponent("f-##.png").path, at: 5)
            default: recorder.save(directory.appendingPathComponent("c.png").path, at: 5)
            }
            recorder.startAfresh()
            // 並びへ戻るときに健康状態は作り直される。ここで前の失敗が見えると、
            // 仕切り直したはずの最初のフレームで 1 回ぶん数えられる
            #expect(recorder.failure == nil)
            recorder.absorbOutcomes()
            #expect(recorder.failure == nil, "外れている間に決着した前の知らせを数えている")
            #expect(recorder.hasFailedToWrite, "持ち越さないついでに、書き損じたことまで忘れている")

            recorder.close()
        }
    }

    /// **外れている間に決着した書き損じは、捨てる前に名乗る** ([#1626])。
    ///
    /// 暇になった撮る係は並びから外れるので、その後に決着した書き損じを読む口は、次に頼まれた
    /// ときの仕切り直ししか無い。そこで黙って捨てると、書けなかった 1 枚が誰にも知らされず、
    /// `mokume render` の終了コードにも出ない (#1282)。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    @Test("外れている間に決着した書き損じを、仕切り直しで黙って捨てない")
    func startingAfreshSpeaksTheFailureItDrops() throws {
        try withTemporaryDirectory("mokume-late-failure-dropped") { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            recorder.writeShot(picture, to: blocker.appendingPathComponent("a.png").path)
            recorder.writer.drain()
            #expect(!recorder.hasFailedToWrite)

            recorder.save(directory.appendingPathComponent("b.png").path, at: 5)
            recorder.startAfresh()
            #expect(recorder.hasFailedToWrite, "捨てた書き損じが、書き出しの穴として残っていない")
            let said = try #require(
                recorder.warnings.message(for: .imageFailure), "捨てた書き損じを誰にも言っていない")
            #expect(said.contains("a.png"))

            recorder.close()
        }
    }

    /// **``FrameRecorder/failure`` は直れば消えるが、書き出したものの穴は消えない** ([#1282])。
    /// 閉じた後に「書けたか」を問う口 (`mokume render` の終了コード) は、こちらを読む。
    ///
    /// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
    @Test("書き損じた後に書けても、1 度書き損じたことは閉じた後まで残る")
    func aFailureIsRememberedAfterARecovery() throws {
        try withTemporaryDirectory("mokume-late-failure-remembered") { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            recorder.writer.write(picture, to: directory.appendingPathComponent("a.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()
            #expect(!recorder.hasFailedToWrite, "書けただけで書き損じたことになっている")

            recorder.writer.write(picture, to: blocker.appendingPathComponent("b.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()
            recorder.writer.write(picture, to: directory.appendingPathComponent("c.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()
            #expect(recorder.failure == nil, "最後に決着したのは書けた 1 枚")
            #expect(recorder.hasFailedToWrite, "直ったことで、穴があったことまで忘れている")

            recorder.close()
            #expect(recorder.hasFailedToWrite)
        }
    }

    @Test("頼まれている最中に頼み足しても、書き損じは消えない")
    func askingMoreWhileBusyKeepsTheFailure() throws {
        try withTemporaryDirectory("mokume-late-failure-busy") { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder()
            recorder.beginRecord(blocker.appendingPathComponent("f-##.png").path, at: 1)
            recorder.writer.write(picture, to: blocker.appendingPathComponent("f-00.png").path)
            recorder.writer.drain()
            recorder.absorbOutcomes()

            // 撮っている最中の save() は仕切り直しではない
            recorder.save(directory.appendingPathComponent("c.png").path, at: 2)
            #expect(recorder.failure != nil)

            recorder.close()
        }
    }
}

/// 撮る係を並びへ入れ直すとき ([#1626] の反証)。GPU を要さない。
///
/// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
@Suite("撮る係を並びへ入れ直す")
struct RecorderRejoinTests {
    /// **並びに居ても、外されていれば入れ直す。** 外された係は、そのフレームを配り終えるまで
    /// 並びに残る。その間の `save()` で居ることだけを見ると、直後に並びから外されて、頼んだ
    /// ものが終わりまで書かれない。
    @Test("並びに残っている外された係は、頼まれたら健康状態ごと入れ直す")
    func aDetachedRecorderStillInTheListRejoins() {
        let recorder = FrameRecorder()
        var health = SeamHealth()
        for _ in 0..<SeamHealth.limit { _ = health.note("full") }
        try? #require(!health.isAttached)
        var outlets: [(seam: any Outlet, health: SeamHealth)] = [(recorder, health)]

        recorder.save("out/next.png", at: 5)
        #expect(SketchRuntime.rejoin(recorder, into: &outlets))

        #expect(outlets.count == 1)
        #expect(outlets[0].health.isAttached, "外されたまま残っている")
        recorder.close()
    }

    @Test("並びに居て外されていなければ、入れ直さない (健康状態の数えを保つ)")
    func anAttachedRecorderKeepsItsHealth() {
        let recorder = FrameRecorder()
        var health = SeamHealth()
        _ = health.note("once")
        var outlets: [(seam: any Outlet, health: SeamHealth)] = [(recorder, health)]

        recorder.save("out/next.png", at: 5)
        #expect(!SketchRuntime.rejoin(recorder, into: &outlets))
        #expect(outlets[0].health.failures == 1)
        recorder.close()
    }
}

/// 録りが覆う番号の幅と、落ちた数 ([#1626]・ADR-0025 決定 2)。GPU を要さない。
///
/// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
@Suite("録りの番号の幅")
struct RecordedSpanTests {
    @Test("途中の穴と、止めたところまでの末尾の欠けを数える")
    func holesAndTheTailAreDropped() {
        var span = RecordedSpan(from: 1)
        for frame in [1, 2, 3, 5, 6] { span.accept(frame) }
        span.expect(through: 10)
        #expect(span.accepted == 5)
        #expect(span.dropped == 5, "4 枚目の穴と、7…10 枚目の末尾")
    }

    /// **1 枚も届かなかった録りも黙らない** (反証 4)。撮り始めたフレームで撮る係が外れると、
    /// 始まり側を「受け取った最初の番号」で決める形では幅が無く、0 と数えていた。
    @Test("1 枚も届かなかった録りは、頼まれたフレームから止めたところまでを落ちた数にする")
    func aRecordingThatGotNothingCountsTheWholeSpan() {
        var span = RecordedSpan(from: 4)
        span.expect(through: 9)
        #expect(span.dropped == 6)

        // `mokume render` はフレーム 0 (最初のフレームの前) で頼む。フレームは 1 から数える
        var fromTheStart = RecordedSpan(from: 0)
        fromTheStart.expect(through: 3)
        #expect(fromTheStart.dropped == 3)
    }

    @Test("止めたところを教えられなければ、1 枚も届かなかった録りは 0 と数える")
    func nothingKnownIsZero() {
        #expect(RecordedSpan(from: 4).dropped == 0)
    }

    @Test("受け取った番号より手前を教えられても、幅は縮めない")
    func anEarlyExpectationDoesNotShrink() {
        var span = RecordedSpan(from: 1)
        for frame in 1...3 { span.accept(frame) }
        span.expect(through: 2)
        #expect(span.dropped == 0)
    }
}

/// スケッチから絵をファイルにする経路。GPU を要する。
@Suite(
    "絵をファイルにする",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SaveFramesTests {

    // MARK: - 検査用のスケッチ

    final class SavingSketch: Sketch {
        /// 走らせる前に差し込む。`Sketch` は引数なしで作れる必要があるため。
        nonisolated(unsafe) static var body: (SavingSketch) -> Void = { _ in }

        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func draw() { Self.body(self) }
    }

    private func makeRuntime(
        _ body: @escaping (SavingSketch) -> Void
    ) throws -> SketchRuntime {
        SavingSketch.body = body
        return try SketchRuntime(sketch: SavingSketch(), gpu: try RenderDevice())
    }

    // MARK: - 出る絵

    @Test("書いたファイルの画素が、出口が受け取る絵と一致する")
    func theFileHoldsExactlyWhatTheOutletReceives() throws {
        try withTemporaryDirectory("mokume-save-matches") { directory in
            let url = directory.appendingPathComponent("still.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0.1, green: 0.1, blue: 0.12))
                sketch.fill(.display(red: 1, green: 0.4, blue: 0.2))
                sketch.circle(16, 12, 16)
                if sketch.frameCount == 1 { sketch.save(url.path) }
            }

            try runtime.advance()
            runtime.closePlugins()

            // 画面へ差し出す絵も出口が受け取る絵も、出どころは同じ 1 本の道である
            let fromTheRoad = try runtime.target.encodeToImage().read()
            let written = try readBack(url)
            #expect(written.width == fromTheRoad.width)
            #expect(written.height == fromTheRoad.height)
            #expect(written.bytes == fromTheRoad.bytes)
        }
    }

    @Test("背景を透けさせると、ファイルにも透けたまま残る")
    func transparencySurvivesTheTripToTheFile() throws {
        try withTemporaryDirectory("mokume-save-alpha") { directory in
            let url = directory.appendingPathComponent("clear.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.transparent)
                sketch.noStroke()
                sketch.fill(.display(red: 1, green: 1, blue: 1))
                sketch.circle(16, 12, 12)
                if sketch.frameCount == 1 { sketch.save(url.path) }
            }

            try runtime.advance()
            runtime.closePlugins()

            let written = try readBack(url)
            // 画面用の面を読み戻す経路なら、ここで背景が黒く潰れている
            #expect(written[0, 0].alpha == 0)
            #expect(written[31, 23].alpha == 0)
            #expect(written[16, 12].alpha == 255)
        }
    }

    // MARK: - 終わりを待てる

    @Test("endRecord から返った時点で、要求した全部がファイルになっている")
    func endRecordReturnsOnlyAfterEveryFrameIsOnDisk() throws {
        try withTemporaryDirectory("mokume-record-drain") { directory in
            let pattern = directory.appendingPathComponent("f-####.png").path
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0, green: 0, blue: 0))
                sketch.circle(Float(sketch.frameCount), 12, 8)
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
                if sketch.frameCount == 6 { sketch.endRecord() }
            }

            for _ in 0..<6 { try runtime.advance() }

            // **後片付けをしていない。** ここで揃っていなければ、止めた直後に
            // プロセスを終えた人は最後の 1 枚を失う
            for index in 0..<5 {
                let url = directory.appendingPathComponent(String(format: "f-%04d.png", index))
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 5)
        }
    }

    /// **連番にも、入らなかった枚数を名乗る** ([#1626] の反証 6)。連番の名前の番号は録りの中の
    /// 通し番号なので、描けなかったフレームは名前の上では穴にならずに詰まる。止める口が名乗る。
    ///
    /// 止め方は 2 通り見る (反証 10)。描いている最中の `endRecord()` は描き終えた手前のフレームまで、
    /// 止まっている間 (フレームの外) の `endRecord()` は描き終えた最後のフレームまでが録りの幅である。
    /// `frameCount - 1` と決め打つ形では、止まっている間に止めると、最後に描けなかった 1 枚を
    /// 数えない。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    @Test("描けなかったフレームを、連番の止め際に落ちた数として名乗る", arguments: ["描いている最中", "止まっている間"])
    func aSequenceSpeaksTheFramesThatDidNotReachIt(_ when: String) throws {
        try withTemporaryDirectory("mokume-record-sequence-dropped") { directory in
            let pattern = directory.appendingPathComponent("f-####.png").path
            let failing = when == "描いている最中" ? 3 : 5
            let runtime = try makeRuntime { sketch in
                sketch.canvas.failureForTesting =
                    sketch.frameCount == failing ? .timedOut(seconds: 5) : nil
                sketch.background(.display(red: 0, green: 0, blue: 0))
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
                if when == "描いている最中", sketch.frameCount == 6 { sketch.endRecord() }
                if when == "止まっている間", sketch.frameCount == 5 { sketch.noLoop() }
            }
            for _ in 0..<6 { try? runtime.advance() }
            if when == "止まっている間" { runtime.endRecord() }

            let said = try #require(
                runtime.recorderWarnings?.message(for: .droppedFrames), "描けなかったフレームを名乗っていない")
            // 1…5 枚目が録りの幅で、描けなかった 1 枚が入らない
            #expect(said.contains("wrote 4 frames. 1 did not reach it"), "\(said)")
            runtime.closePlugins()
        }
    }

    @Test("番号の入る場所が無い名前は、撮り始めずに済ませる")
    func aPatternWithoutANumberNeverStarts() throws {
        try withTemporaryDirectory("mokume-record-refuse") { directory in
            let pattern = directory.appendingPathComponent("frame.png").path
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0, green: 0, blue: 0))
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
            }

            for _ in 0..<5 { try runtime.advance() }
            runtime.closePlugins()

            // 黙って受けると、全部が同じ名前になって 1 枚だけが残る
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(runtime.target.encodePassCount == 0)
        }
    }

    // MARK: - 使わないスケッチは払わない

    @Test("撮らないスケッチは、道を 1 回も通らない")
    func aSketchThatNeverSavesPaysNothing() throws {
        let runtime = try makeRuntime { sketch in
            sketch.background(.display(red: 0.2, green: 0.2, blue: 0.2))
            sketch.circle(16, 12, 10)
        }
        for _ in 0..<10 { try runtime.advance() }
        #expect(runtime.target.encodePassCount == 0)
    }

    @Test("1 枚だけ撮ると、道を通るのはそのフレームだけ")
    func oneStillCostsExactlyOnePass() throws {
        try withTemporaryDirectory("mokume-save-once") { directory in
            let url = directory.appendingPathComponent("one.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0.2, green: 0.2, blue: 0.2))
                if sketch.frameCount == 1 { sketch.save(url.path) }
            }

            for _ in 0..<10 { try runtime.advance() }
            runtime.closePlugins()

            // 付けっぱなしにすると、ここが 10 になる
            #expect(runtime.target.encodePassCount == 1)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("同じフレームに 2 枚頼んでも、読み戻しは 1 回")
    func twoRequestsInOneFrameShareOneReadback() throws {
        try withTemporaryDirectory("mokume-save-twice") { directory in
            let first = directory.appendingPathComponent("a.png")
            let second = directory.appendingPathComponent("b.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0.3, green: 0.1, blue: 0.5))
                if sketch.frameCount == 1 {
                    sketch.save(first.path)
                    sketch.save(second.path)
                }
            }

            try runtime.advance()
            runtime.closePlugins()

            #expect(runtime.target.encodePassCount == 1)
            #expect(runtime.target.encodedStorage?.readCount == 1)
            #expect(try Data(contentsOf: first) == (try Data(contentsOf: second)))
        }
    }

    // MARK: - 転んだとき

    @Test("書き損じが続くと、その差込口が外れる")
    func aRecorderThatKeepsFailingIsDetached() throws {
        try withTemporaryDirectory("mokume-record-failing") { directory in
            // 書き先の親をファイルにしておく。ディレクトリを作ることも書くこともできない
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)
            let pattern = blocker.appendingPathComponent("f-####.png").path

            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0, green: 0, blue: 0))
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
            }

            for _ in 0..<30 { try runtime.advance() }
            let passesWhileFailing = runtime.target.encodePassCount
            for _ in 0..<10 { try runtime.advance() }
            runtime.closePlugins()

            // 転び続ける出口が毎フレーム費用を払い続けないこと (ADR-0024 決定 7)
            #expect(runtime.target.encodePassCount == passesWhileFailing)
            #expect(passesWhileFailing < 30)
        }
    }
}

// MARK: - 共通の道具

/// 検査のあいだだけ使う一時ディレクトリ。
@MainActor
private func withTemporaryDirectory(_ name: String, _ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// 書いた PNG を、変換を挟まずにバイト列として読み戻す。
///
/// **描き直さない。** 面へ描いて読み直すとアルファが乗算され、透けたところの色が
/// 失われる — 透過が残っていることを見る検査が、道具の側の都合で通らなくなる。
@MainActor
private func readBack(_ url: URL) throws -> DisplayImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let data = image.dataProvider?.data as Data?
    else {
        throw ImageWriteFailure.destinationUnavailable(path: url.path)
    }
    return DisplayImage(width: image.width, height: image.height, bytes: [UInt8](data))
}
