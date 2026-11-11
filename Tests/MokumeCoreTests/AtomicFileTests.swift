// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// JSON を区画へ置く口 ([#989](https://github.com/mokume-metal/mokume/issues/989))。GPU は要らない。
///
/// **入口は 2 つで、名前が失敗の扱いを決める。** かつては同じ処理が 8 箇所にあり、
/// `try?` で捨てる・`warn` で名乗る・`throws` で投げるの 3 通りが混ざっていた。
@Suite("JSON を置く口")
struct AtomicFileTests {
    /// **宣言順と辞書順が違う**見本 (宣言は zebra → apple → middle)。
    private struct Sample: Encodable {
        let zebra: Int
        let apple: String
        let middle: Bool
    }

    private let sample = Sample(zebra: 1, apple: "a", middle: true)

    private func makeFacet() throws -> URL {
        let directory = try TestScratch.directory("mokume-atomic")
        return directory
    }

    /// 書かれた JSON に現れる鍵を、現れた順に取る。
    private func keys(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { return nil }
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
    }

    @Test("鍵の並びは辞書順で決まる")
    func spellsKeysInSortedOrder() throws {
        let url = try makeFacet().appendingPathComponent("sample.json")
        try AtomicFile.writeJSON(sample, to: url)

        // 宣言順 (zebra, apple, middle) ではなく辞書順で届く。`.sortedKeys` を付けて
        // いなかった頃は辞書の走査順で、プロセスごとに変わっていた (#854 の実測)
        #expect(keys(in: try String(contentsOf: url, encoding: .utf8)) == ["apple", "middle", "zebra"])
    }

    @Test("置けたら真、置けなければ偽")
    func reportsWhetherItLanded() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("report.json")
        #expect(AtomicFile.publishJSON(sample, to: url, "見本"))

        // 書き込み先を塞ぐ。**捨てたかどうかで続きが変わる呼び手が居る** —
        // 置けたときだけ識別子を控える (RemoteParams)・数を進める (ParamStore)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        #expect(AtomicFile.publishJSON(sample, to: url, "見本") == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: facet.path)
    }

    @Test("置けなかったことは、置き場所ごとに 1 度だけ名乗る")
    func namesTheFailureOnlyOnce() throws {
        let facet = try makeFacet()
        let blocked = facet.appendingPathComponent("blocked.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: facet.path)
        }

        #expect(AtomicFile.hasWarned(about: blocked) == false)
        _ = AtomicFile.publishJSON(sample, to: blocked, "最初の名乗り")
        #expect(AtomicFile.warning(about: blocked)?.contains("最初の名乗り") == true)

        // 2 度目は黙る。つまみを掴んでいる間は入力のたびにここへ来るので、毎回言うと
        // 標準エラーが流れて他の注意が読めなくなる
        _ = AtomicFile.publishJSON(sample, to: blocked, "二度目の名乗り")
        #expect(AtomicFile.warning(about: blocked)?.contains("二度目") == false)

        // 鍵は置き場所。別の面の失敗は、別に名乗る
        let other = facet.appendingPathComponent("other.json")
        #expect(AtomicFile.hasWarned(about: other) == false)
    }

    /// 符号化が拒んだ理由を落とさない (#2263)。`localizedDescription` は「正しい形式で
    /// ない」としか言わず、何がどこで拒まれたかが消える。
    @Test("値を符号化できずに置けなかったときは、型と、何がどこで拒まれたかを名乗る")
    func namesWhatTheEncoderRefused() throws {
        struct Reading: Encodable { let level: Double }
        let url = try makeFacet().appendingPathComponent("reading.json")
        #expect(AtomicFile.publishJSON(Reading(level: .nan), to: url, "読み") == false)
        let line = try #require(AtomicFile.warning(about: url))
        #expect(!line.contains("\n"))
        #expect(line.contains("EncodingError"))
        #expect(line.contains("nan"))
        #expect(line.contains("level"), "拒まれた場所を言わない: \(line)")
    }

    /// 区画に残っている一時ファイルの名前。
    private func temporaries(in facet: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: facet.path).filter { $0.hasSuffix(".tmp") }
    }

    /// **2 つのプロセスが同じ名前へ同時に書く並びを、1 プロセスで決定的に作る。**
    ///
    /// 作る → 相手が作る → 相手が置く → 自分が置く。`watch` は切り替えの瞬間だけ 2 世代を
    /// 重ねるので、両方が同じ区画へ応答や絵を置くとこの並びになる。一時ファイルの名前が
    /// 固定だった頃は相手が自分の一時ファイルを上書きして持ち去り、自分の置く段が
    /// 「一時ファイルが無い」で投げていた (手元の 2 プロセスの実測で書き込みの 4 割強・
    /// [#1198](https://github.com/mokume-metal/mokume/issues/1198))。
    @Test("書いている途中に同じ名前への別の書き込みが割り込んでも、両方が置ける")
    func survivesAnotherWriterOnTheSameName() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("report.json")

        try AtomicFile.write(to: url) { temporary in
            try Data("mine".utf8).write(to: temporary)
            try AtomicFile.write(Data("theirs".utf8), to: url)
        }

        // 後から置いたほうが残る。読み手から見えるのは、どちらかの中身だけである
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
        #expect(try temporaries(in: facet).isEmpty)
    }

    /// **置けなかった書き込みの後始末は、書いた側がする。** 名前を書き込みごとに変えると、
    /// 誰も上書きしないので残った分がそのまま溜まる。
    @Test("置けなかった一時ファイルは残さない")
    func removesItsTemporaryWhenItFails() throws {
        struct Interrupted: Error {}
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("frame-000.png")

        #expect(throws: Interrupted.self) {
            try AtomicFile.write(to: url) { temporary in
                try Data("half".utf8).write(to: temporary)
                throw Interrupted()
            }
        }
        #expect(try temporaries(in: facet).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// 走らせた子のプロセスと、その終わりを待つ札。終わるまで待てば、その番号にはもう誰も居ない。
    ///
    /// **待つ間に実行ループを回さない** (``ExitWait``・#1937)。
    private func launch(_ path: String, _ arguments: [String] = []) throws -> (Process, ExitWait) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = ExitWait(for: process)
        try process.run()
        return (process, exited)
    }

    /// **書いている途中に落とされた書き手の分は、次に同じ名前を書くプロセスが片付ける。**
    ///
    /// スケッチは `SIGTERM` で即座に終わるので、見張りの差し替えのたびに一時ファイルが
    /// 残りうる。名前を書き込みごとに変えた以上、片付ける者が居ないと溜まり続ける。
    /// **重なっている別の世代が書いている途中のものは消さない** — 消すと、その世代の
    /// 置く段が「一時ファイルが無い」で投げる (#1198 の症状そのもの)。
    @Test("居なくなった書き手の一時ファイルは片付け、生きている書き手のものは残す")
    func sweepsTemporariesOfWritersThatAreGone() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("frame-000.png")

        let (gone, goneExit) = try launch("/usr/bin/true")
        goneExit.wait()
        let (alive, _) = try launch("/bin/sleep", ["30"])
        defer { alive.terminate() }

        let abandoned = AtomicFile.temporaryURL(for: url, writer: gone.processIdentifier, sequence: 7)
        let inFlight = AtomicFile.temporaryURL(for: url, writer: alive.processIdentifier, sequence: 3)
        // 別の名前の一時ファイルは、この名前を書いても触れない
        let otherName = AtomicFile.temporaryURL(
            for: facet.appendingPathComponent("frame-001.png"), writer: gone.processIdentifier,
            sequence: 8)
        for leftover in [abandoned, inFlight, otherName] {
            try Data("half".utf8).write(to: leftover)
        }

        try AtomicFile.write(Data("frame".utf8), to: url)

        #expect(try temporaries(in: facet).sorted()
            == [inFlight.lastPathComponent, otherName.lastPathComponent].sorted())
    }

    /// 置き場に残ったものの中身 (名前 → 中のファイルの中身)。
    private func folderContents(_ folders: [URL]) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: folders.map { folder in
            (folder.lastPathComponent,
             try? String(contentsOf: folder.appendingPathComponent("keep.txt"), encoding: .utf8))
        })
    }

    /// 書き手は、選ぶはずの一時ファイルの名前に既に何か在れば、別の連番を選ぶ ([#3943] の反証の指摘 2)。
    /// 片付けは同じ名前のフォルダを残すので、残ったフォルダは後から来た書き手 (pid と連番が一致した) に
    /// 中身ごと消されてはならない — 書くときも、書き損じた後の後始末でも。
    ///
    /// [#3943]: https://github.com/mokume-metal/mokume/issues/3943
    @Test("一時ファイルの名前にフォルダが在れば別の連番を選び、書いても書き損じてもフォルダは中身ごと残る")
    func writersSkipFoldersAtTheirTemporaryName() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("frame-000.png")
        // いまの連番を、1 度予約した一時ファイルの名前から読む
        let probe = try AtomicFile.reserve(url)
        let current = try #require(Int(probe.temporary.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? ""))
        // 次に選ばれうる連番の名前に、中身のあるフォルダを置く (並んで走る検査が連番を進めても届く数)
        let folders = try (current + 1...current + 200).map { sequence in
            let folder = AtomicFile.temporaryURL(for: url, writer: getpid(), sequence: sequence)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("mine \(sequence)".utf8).write(to: folder.appendingPathComponent("keep.txt"))
            return folder
        }
        let before = folderContents(folders)

        let chosen = try AtomicFile.reserve(url)
        #expect(!FileManager.default.fileExists(atPath: chosen.temporary.path), "在る名前を選んだ: \(chosen.temporary.lastPathComponent)")
        try AtomicFile.write(Data("frame".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("frame".utf8))
        struct Interrupted: Error {}
        #expect(throws: Interrupted.self) { try AtomicFile.write(to: url) { _ in throw Interrupted() } }
        #expect(throws: Interrupted.self) {
            try AtomicFile.reserve(url).place { written in
                try Data("half".utf8).write(to: written)
                throw Interrupted()
            }
        }
        #expect(folderContents(folders) == before, "残ったフォルダの中身が変わった")
    }

    @Test("書き損じた後の後始末は、一時ファイルの場所にフォルダが在っても消さない")
    func theCleanupAfterAFailureKeepsAFolder() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("frame-000.png")
        let folder = facet.appendingPathComponent(".taken.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        struct Interrupted: Error {}
        let placement = AtomicFile.Placement(url: url, temporary: folder)
        #expect(throws: Interrupted.self) { try placement.place { _ in throw Interrupted() } }
        #expect(folderContents([folder]) == [".taken.tmp": "mine"])
    }

    @Test("リンクの行き先へ置けなかった後始末も、一時ファイルの場所にフォルダが在れば消さず、リンクも残す")
    func theCleanupAfterAFailedPlacementOverALinkKeepsAFolder() throws {
        let facet = try makeFacet()
        let target = facet.appendingPathComponent("target.bin")
        try Data("previous".utf8).write(to: target)
        let url = facet.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let folder = facet.appendingPathComponent(".taken.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        // フォルダはリンク (通常ファイルを指す) の上へ `rename(2)` できない (`ENOTDIR`) ので、置く段が失敗する
        let placement = AtomicFile.Placement(url: url, temporary: folder)
        #expect(throws: (any Error).self) { try placement.placeWritten() }
        #expect(folderContents([folder]) == [".taken.tmp": "mine"])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == target.path)
        #expect(try Data(contentsOf: target) == Data("previous".utf8))
    }

    /// 消すのは `unlink(2)` 1 回 ([#3943] の 2 回目の反証の指摘 1・2)。見てから消すのではないので、見てから消すまでの
    /// 間にフォルダへ替わる窓が無い。ここでは種類ごとに、残るもの・外れるものと戻り値を固定する。
    ///
    /// [#3943]: https://github.com/mokume-metal/mokume/issues/3943
    @Test("remove はフォルダを中身ごと残して false、リンクはリンクだけを外して true、通常ファイルと無い名前は true")
    func removeUnlinksOnlyWhatIsNotAFolder() throws {
        let manager = FileManager.default
        let facet = try makeFacet()
        let folder = facet.appendingPathComponent("folder", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        let kept = folder.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: kept)
        let linkToFolder = facet.appendingPathComponent("link-to-folder")
        try manager.createSymbolicLink(at: linkToFolder, withDestinationURL: folder)
        let brokenLink = facet.appendingPathComponent("broken-link")
        try manager.createSymbolicLink(
            at: brokenLink, withDestinationURL: facet.appendingPathComponent("nowhere"))
        let file = facet.appendingPathComponent("file.tmp")
        try Data("half".utf8).write(to: file)
        let missing = facet.appendingPathComponent("missing.tmp")

        #expect(AtomicFile.remove(folder) == false, "フォルダは消えないので false")
        #expect((try? Data(contentsOf: kept)) == Data("mine".utf8), "フォルダの中身が残る")
        #expect(AtomicFile.remove(linkToFolder))
        #expect(!AtomicFile.exists(linkToFolder), "リンク自身は外れる")
        #expect((try? Data(contentsOf: kept)) == Data("mine".utf8), "リンクの指す先は残る")
        #expect(AtomicFile.remove(brokenLink))
        #expect(!AtomicFile.exists(brokenLink))
        #expect(AtomicFile.remove(file))
        #expect(!AtomicFile.exists(file))
        #expect(AtomicFile.remove(missing), "もともと無いなら true")
    }

    @Test("remove は消せなかった (書き込めないフォルダの中の) ファイルに false を返す")
    func removeReportsAFileItCouldNotRemove() throws {
        let facet = try makeFacet()
        let locked = facet.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        let file = locked.appendingPathComponent("file.tmp")
        try Data("half".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(AtomicFile.remove(file) == false)
        #expect(AtomicFile.exists(file))
    }

    @Test("GIF の書き手は、一時ファイルの場所にフォルダが在れば消さずに断る")
    func theGIFWriterKeepsAFolderAtItsTemporaryName() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("loop.gif")
        let folder = facet.appendingPathComponent(".taken.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        let placement = AtomicFile.Placement(url: url, temporary: folder)
        #expect(throws: MovieWriteFailure.self) { _ = try GIFFile(path: url.path, frameRate: 10, placement: placement) }
        #expect(folderContents([folder]) == [".taken.tmp": "mine"])
    }

    /// 片付けが消してよいのは、書き手が作る形 (通常ファイル) の一時ファイルだけ ([#3943] と同じ根)。
    ///
    /// [#3943]: https://github.com/mokume-metal/mokume/issues/3943
    @Test("居なくなった書き手の一時ファイルの名前でも、フォルダは中身ごと残す")
    func theSweepKeepsFoldersNamedLikeATemporary() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("frame-000.png")
        let (gone, goneExit) = try launch("/usr/bin/true")
        goneExit.wait()
        let file = AtomicFile.temporaryURL(for: url, writer: gone.processIdentifier, sequence: 1)
        try Data("half".utf8).write(to: file)
        let folder = AtomicFile.temporaryURL(for: url, writer: gone.processIdentifier, sequence: 2)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let kept = folder.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: kept)

        try AtomicFile.write(Data("frame".utf8), to: url)

        #expect(try temporaries(in: facet) == [folder.lastPathComponent])
        #expect((try? Data(contentsOf: kept)) == Data("mine".utf8))
    }

    // MARK: - 片付けの読みは、呼んだ糸で件数に上限を持つ (#3176)

    /// 終わって回収した子の番号 (= もう居ない書き手)。
    private func goneWriter() throws -> pid_t {
        let (gone, exited) = try launch("/usr/bin/true")
        exited.wait()
        return gone.processIdentifier
    }

    /// 置き場所の隣に、居ない書き手の一時ファイルを `count` 個と、関係のない物を `fillers` 個置く。
    private func crowd(_ facet: URL, for url: URL, writer: pid_t, abandoned count: Int, fillers: Int) throws {
        for sequence in 1...count {
            try Data("half".utf8).write(to: AtomicFile.temporaryURL(for: url, writer: writer, sequence: sequence))
        }
        for index in 0..<fillers {
            try Data().write(to: facet.appendingPathComponent("filler-\(index).dat"))
        }
    }

    /// **件数に依らず返るのは、呼んだ糸が読む件数に上限があるから。** 時間で見ると機械の混み具合に左右される
    /// ので、読んだ件数で見る (14 万件のディレクトリでは、全件を読む `contentsOfDirectory` が約 340 ms だった)。
    @Test("読みきれないディレクトリでは、呼んだ糸が読むのは予算までで、続きが残りを片付ける")
    func theCallingThreadReadsOnlyUpToTheBudget() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let url = facet.appendingPathComponent("frame-000.png")
        try crowd(facet, for: url, writer: try goneWriter(), abandoned: 40, fillers: 300)

        let rest = try #require(
            AtomicFile.beginSweep(of: url, budget: 16), "予算より多い件数があるのに、呼んだ糸で読みきった")
        #expect(rest.entriesRead <= 16, "呼んだ糸が予算を越えて読んだ: \(rest.entriesRead)")
        #expect(try temporaries(in: facet).count >= 40 - 16, "予算の外の分まで、呼んだ糸で片付けた")

        rest.finish()
        #expect(try temporaries(in: facet).isEmpty, "続きが居ない書き手の分を片付けていない")
        #expect(rest.entriesRead >= 340, "続きが読みきっていない: \(rest.entriesRead)")
    }

    @Test("予算に収まるディレクトリは、戻る前に片付け終わる (続きは無い)")
    func aSmallDirectoryIsSweptBeforeReturning() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let url = facet.appendingPathComponent("frame-000.png")
        try crowd(facet, for: url, writer: try goneWriter(), abandoned: 5, fillers: 10)

        #expect(AtomicFile.beginSweep(of: url, budget: 1024) == nil, "予算に収まるのに続きを残した")
        #expect(try temporaries(in: facet).isEmpty, "戻る前に片付け終わっていない")
    }

    /// 置く口から見て: 裏の列を止めておくと、置く口は続きを待たずに返り、続きが走れば片付く。
    @Test("置く口は、予算の外の片付けを待たずに返り、裏の列が走れば残りも片付く")
    func writingDoesNotWaitForTheRestOfTheSweep() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let url = facet.appendingPathComponent("frame-000.png")
        try crowd(facet, for: url, writer: try goneWriter(), abandoned: 100, fillers: 300)

        let saved = AtomicFile.syncSweepBudget
        AtomicFile.syncSweepBudget = 16
        defer { AtomicFile.syncSweepBudget = saved }
        // 裏の列を止める。置く口が続きを待つ形なら、ここで返らず検査が止まる (期限で殺される)
        let hold = DispatchSemaphore(value: 0)
        AtomicFile.sweepQueue.async { hold.wait() }
        defer { hold.signal() }

        try AtomicFile.write(Data("frame".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("frame".utf8))
        // 呼んだ糸が読んだのは予算まで。残りの居ない書き手の分は、続きが走るまで残る
        #expect(try temporaries(in: facet).count >= 100 - 16, "予算の外の分まで、置く口が片付けた")

        hold.signal()
        AtomicFile.settleSweeps()
        #expect(try temporaries(in: facet).isEmpty, "続きが片付けていない")
    }

    /// **続きの経路でも、生きている書き手の一時ファイルは消さない** (重なっている別の世代が書いている途中のもの)。
    @Test("続きの経路でも、生きている書き手の一時ファイルは残し、居ない書き手の分だけ消す")
    func theContinuationKeepsTemporariesOfLiveWriters() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let url = facet.appendingPathComponent("frame-000.png")
        let (alive, _) = try launch("/bin/sleep", ["30"])
        defer { alive.terminate() }
        let inFlight = AtomicFile.temporaryURL(for: url, writer: alive.processIdentifier, sequence: 3)
        try Data("half".utf8).write(to: inFlight)
        try crowd(facet, for: url, writer: try goneWriter(), abandoned: 40, fillers: 300)

        let rest = try #require(AtomicFile.beginSweep(of: url, budget: 16))
        rest.finish()
        #expect(try temporaries(in: facet) == [inFlight.lastPathComponent], "生きている書き手の分を消した")
    }

    /// **名前が増えても、続きはディレクトリごとに 1 本で、`DIR` を握る数も増えない** — 枚ごとに名前が変わる呼び手
    /// (観測の絵) が、撮る速さが片付けを上回ったときに fd を溜めない。片付けるのは頼まれた名前の分だけ。
    @Test("同じディレクトリで名前が増えても、続きは 1 本で、開いている fd は増えない")
    func oneContinuationPerDirectoryWhateverTheNames() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let gone = try goneWriter()
        let names = (0..<40).map { "frame-\($0).png" }
        for name in names {
            for sequence in 1...2 {
                try Data("half".utf8).write(
                    to: AtomicFile.temporaryURL(
                        for: facet.appendingPathComponent(name), writer: gone, sequence: sequence))
            }
        }
        // 頼まれない名前の分は、続きが走っても触れない
        let unasked = AtomicFile.temporaryURL(
            for: facet.appendingPathComponent("other.json"), writer: gone, sequence: 1)
        try Data("half".utf8).write(to: unasked)
        for index in 0..<300 { try Data().write(to: facet.appendingPathComponent("filler-\(index).dat")) }

        let saved = AtomicFile.syncSweepBudget
        AtomicFile.syncSweepBudget = 16
        defer { AtomicFile.syncSweepBudget = saved }
        let hold = DispatchSemaphore(value: 0)
        AtomicFile.sweepQueue.async { hold.wait() }
        defer { hold.signal() }

        for name in names { try AtomicFile.write(Data(), to: facet.appendingPathComponent(name)) }
        // 数えるのは、このディレクトリの鍵の行だけ (プロセスで共有する控えの全体は、並走する検査で揺れる)
        #expect(AtomicFile.Sweep.handles.counts(in: facet).held == 0, "続きが積まれている間に DIR を握っている")
        #expect(
            AtomicFile.continuations.names(in: facet) == names.count,
            "続きが 1 本にまとまっていない: \(AtomicFile.continuations.names(in: facet))")
        // 呼んだ糸が読んだのは最初の名前の予算まで。あとの名前は読まずに集合へ足しただけ
        #expect(try temporaries(in: facet).count >= 2 * names.count + 1 - 16, "続きの外で片付けた")

        hold.signal()
        AtomicFile.settleSweeps()
        #expect(try temporaries(in: facet) == [unasked.lastPathComponent], "頼まれた名前の分だけが消えるはず")
        #expect(AtomicFile.continuations.names(in: facet) == 0, "続きが片付いても控えが残る")
        // 名前が 40 でも、同時に開いた DIR は 1 本まで
        let handles = AtomicFile.Sweep.handles.counts(in: facet)
        #expect(handles.held == 0 && handles.peak <= 1, "\(handles)")
    }

    /// **1 周目を読んでいる間に来た名前は、2 周目で片付く。片付け終えた後に来た名前は、呼んだ糸が自分で読む。**
    @Test("続きが読んでいる間に足された名前は 2 周目で片付き、控えが空になった後の名前は新しい続きになる")
    func namesAddedDuringAPassAreSweptByTheNextPassAndLaterOnesStartOver() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let gone = try goneWriter()
        let first = facet.appendingPathComponent("frame-000.png")
        let second = facet.appendingPathComponent("frame-001.png")
        let third = facet.appendingPathComponent("frame-002.png")
        for url in [first, second, third] {
            for sequence in 1...20 {
                try Data("half".utf8).write(
                    to: AtomicFile.temporaryURL(for: url, writer: gone, sequence: sequence))
            }
        }
        for index in 0..<300 { try Data().write(to: facet.appendingPathComponent("filler-\(index).dat")) }

        let saved = AtomicFile.syncSweepBudget
        AtomicFile.syncSweepBudget = 16
        defer {
            AtomicFile.syncSweepBudget = saved
            AtomicFile.continuations.afterPass = nil
        }
        // 1 周目の後 (列の上) で 2 つ目の名前を足す。**1 周目の集合は 1 つ目だけ**なので、2 つ目は 2 周目でしか片付かない
        let key = AtomicFile.Continuations.key(of: facet)
        AtomicFile.continuations.afterPass = { passKey, pass in
            if passKey == key, pass == 0 { _ = AtomicFile.continuations.adopt(second) }
        }
        let hold = DispatchSemaphore(value: 0)
        AtomicFile.sweepQueue.async { hold.wait() }
        defer { hold.signal() }
        try AtomicFile.write(Data(), to: first)
        hold.signal()
        AtomicFile.settleSweeps()
        let left = try temporaries(in: facet)
        #expect(
            left.filter { $0.hasPrefix(".frame-000.png.") || $0.hasPrefix(".frame-001.png.") }.isEmpty,
            "2 周目が足された名前を片付けていない: \(left.count) 個残る")
        #expect(left.count == 20, "頼まれていない名前の分に触れた: \(left.count)")
        #expect(AtomicFile.continuations.names(in: facet) == 0)

        // 控えが空になった後に来た名前は、呼んだ糸が自分で読んで、新しい続きを積む (足すだけで終わらせない)
        AtomicFile.continuations.afterPass = nil
        let again = DispatchSemaphore(value: 0)
        AtomicFile.sweepQueue.async { again.wait() }
        defer { again.signal() }
        try AtomicFile.write(Data(), to: third)
        #expect(AtomicFile.continuations.names(in: facet) == 1, "控えが空の後なのに、新しい続きを積んでいない")
        again.signal()
        AtomicFile.settleSweeps()
        #expect(try temporaries(in: facet).isEmpty, "新しい続きが片付けていない")
    }

    /// **開けなかった回の名前は、片付けた名前に数えない** — 次に同じ名前を置くときに読み直す。
    @Test("続きがディレクトリを開けなかったときは、その名前を片付け済みにせず、次に置くときに読み直す")
    func aNameWhoseDirectoryCouldNotBeOpenedIsReadAgain() throws {
        let facet = try makeFacet()
        let moved = facet.deletingLastPathComponent()
            .appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: facet)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = facet.appendingPathComponent("frame-000.png")
        try crowd(facet, for: url, writer: try goneWriter(), abandoned: 40, fillers: 300)

        let saved = AtomicFile.syncSweepBudget
        AtomicFile.syncSweepBudget = 16
        defer { AtomicFile.syncSweepBudget = saved }
        let hold = DispatchSemaphore(value: 0)
        AtomicFile.sweepQueue.async { hold.wait() }
        defer { hold.signal() }
        try AtomicFile.write(Data(), to: url)
        // 続きが走る前にディレクトリを動かして、開けなくする
        try FileManager.default.moveItem(at: facet, to: moved)
        hold.signal()
        AtomicFile.settleSweeps()
        try FileManager.default.moveItem(at: moved, to: facet)
        #expect(try temporaries(in: facet).count >= 40 - 16, "前提: 開けなかった回は何も片付けない")

        try AtomicFile.write(Data(), to: url)
        AtomicFile.settleSweeps()
        #expect(try temporaries(in: facet).isEmpty, "開けなかった名前が、片付け済みのまま二度と読まれない")
    }

    @Test("ディレクトリの鍵は、/private の有無・.. ・同じ道の別の綴りで割れない")
    func theDirectoryKeyIsNormalised() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let key = AtomicFile.Continuations.key(of: facet)
        #expect(AtomicFile.Continuations.key(of: URL(fileURLWithPath: "/private" + facet.path)) == key)
        #expect(
            AtomicFile.Continuations.key(of: facet.appendingPathComponent("sub/..", isDirectory: true)) == key)
        #expect(AtomicFile.Continuations.key(of: URL(fileURLWithPath: facet.path + "//")) == key)
    }

    @Test("一時ファイルの名前から書き手を引くのは、その置き場所の形をしたものだけ")
    func readsTheWriterOnlyFromItsOwnTemporaries() {
        let url = URL(fileURLWithPath: "/facet/report.json")
        let own = AtomicFile.temporaryURL(for: url, writer: 4242, sequence: 1).lastPathComponent
        #expect(AtomicFile.writer(ofTemporary: own, for: url) == 4242)

        // 固定名だった頃の名前・別の置き場所・形の崩れたものは、誰のものとも言えない
        for name in [
            ".report.json.tmp", ".report.json.x.4242-1.tmp", ".report.json.0-1.tmp",
            ".report.json.4242-.tmp", ".report.json.4242.tmp", ".other.json.4242-1.tmp",
        ] {
            #expect(AtomicFile.writer(ofTemporary: name, for: url) == nil, "\(name)")
        }
    }

    /// 行き先の名前は 255 まで作れる。一時ファイルの名前は行き先より長いので、詰めないと 243〜255 の名前は
    /// 一時ファイルを作る段で `File name too long` になる ([#3426])。
    ///
    /// [#3426]: https://github.com/mokume-metal/mokume/issues/3426
    @Test("一時ファイルの名前は、255 まで作れる行き先の名前でも 255 に収まり、片付けが同じ形で読める")
    func temporaryNamesFitForTheLongestDestinationNames() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let gone = try goneWriter()
        for length in [200, 215, 216, 243, 250, 255] {
            let name = String(repeating: "a", count: length - 4) + ".mov"
            let url = facet.appendingPathComponent(name)
            let temporary = AtomicFile.temporaryURL(for: url, writer: 2_147_483_647, sequence: Int.max)
            let temporaryName = temporary.lastPathComponent
            #expect(FileNameLength.of(temporaryName) ?? .max <= FileNameLength.limit, "\(length): \(temporaryName.count)")
            // 実際に作れる (File name too long にならない)
            #expect(FileManager.default.createFile(atPath: temporary.path, contents: Data("x".utf8)), "\(length)")
            try? FileManager.default.removeItem(at: temporary)
            // 書いた側と読む側が同じ頭を引く
            #expect(AtomicFile.writer(ofTemporary: temporaryName, for: url) == 2_147_483_647, "\(length)")
            // 落とされた書き手の分は、同じ名前を置くときに片付く
            let stale = AtomicFile.temporaryURL(for: url, writer: gone, sequence: 1)
            try Data("half".utf8).write(to: stale)
            _ = try AtomicFile.reserve(url)
            AtomicFile.settleSweeps()
            #expect(!FileManager.default.fileExists(atPath: stale.path), "\(length): 落ちた書き手の一時ファイルが片付かない")
        }
        // 収まる名前は、今までどおり名前をそのまま入れる
        let short = facet.appendingPathComponent("report.json")
        #expect(AtomicFile.temporaryURL(for: short, writer: 4242, sequence: 1).lastPathComponent == ".report.json.4242-1.tmp")
    }

    // ---------------------------------------------------------- 書く先がディレクトリ (#2859)

    /// 中身のあるディレクトリ `<facet>/full.json/inner.txt` を作って返す。
    private func makeFullDirectory() throws -> (directory: URL, inner: URL) {
        let directory = try makeFacet().appendingPathComponent("full.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inner = directory.appendingPathComponent("inner.txt")
        try "keep me".write(to: inner, atomically: true, encoding: .utf8)
        return (directory, inner)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// 書く先がディレクトリだと、失敗せずに中身ごと消してファイルに置き換えていた
    /// (`replaceItemAt` は行き先の種類を見ない)。
    @Test("書く先が中身のあるディレクトリなら、置き換えずに失敗し、中身は残る")
    func refusesToReplaceADirectoryWithContents() throws {
        let (directory, inner) = try makeFullDirectory()
        #expect(throws: (any Error).self) {
            try AtomicFile.write(Data("x".utf8), to: directory)
        }
        #expect(isDirectory(directory), "ディレクトリが消えた")
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me", "中身が消えた")
        #expect(try temporaries(in: directory.deletingLastPathComponent()).isEmpty, "一時ファイルが残った")
    }

    @Test("書く先が空のディレクトリでも、置き換えずに失敗する")
    func refusesToReplaceAnEmptyDirectory() throws {
        let directory = try makeFacet().appendingPathComponent("empty.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try AtomicFile.writeJSON(sample, to: directory)
        }
        #expect(isDirectory(directory))
    }

    /// 理由は POSIX の文面 (`Is a directory`) で、呼び手の既存の警告の経路 (`Diagnostics.reason`) に乗る。
    @Test("失敗の理由は Is a directory で、publishJSON は偽を返して 1 度だけ名乗る")
    func namesTheDirectoryInTheUsualWarningPath() throws {
        let (directory, inner) = try makeFullDirectory()
        var thrown: (any Error)?
        do {
            try AtomicFile.write(Data("x".utf8), to: directory)
        } catch {
            thrown = error
        }
        let reason = try Diagnostics.reason(#require(thrown))
        #expect(reason.contains("Is a directory"), "理由が違う: \(reason)")

        // 言った警告が、並んで走る検査の溜め場 (観測の応答が読む) に混ざらないよう、自分の溜め場へ差す
        let landed = Diagnostics.$digest.withValue(WarningDigest()) {
            AtomicFile.publishJSON(sample, to: directory, "見本")
        }
        #expect(!landed)
        let warning = try #require(AtomicFile.warning(about: directory))
        #expect(warning.contains("Is a directory"), "警告が理由を言っていない: \(warning)")
        #expect(warning.contains(directory.path))
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me")
    }

    /// ディレクトリを指す symlink も、指す先のディレクトリを壊さない。**変更前から** `replaceItemAt` は
    /// symlink へは別の理由で失敗していて (実測)、これは退行を防ぐ札である — 辿った先がディレクトリな
    /// ら、どの経路でも置かない向きに倒してある。
    @Test("ディレクトリを指す symlink へも置かず、指す先のディレクトリは残る")
    func leavesTheTargetOfASymlinkToADirectory() throws {
        let (directory, inner) = try makeFullDirectory()
        let link = directory.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(throws: (any Error).self) {
            try AtomicFile.write(Data("x".utf8), to: link)
        }
        #expect(isDirectory(directory), "指す先のディレクトリが消えた")
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me")
    }

    @Test("書く先がファイルか無いときは、従来どおり原子的に置き換える")
    func stillReplacesFilesAndCreatesMissingOnes() throws {
        let url = try makeFacet().appendingPathComponent("new.json")
        try AtomicFile.write(Data("1".utf8), to: url)
        try AtomicFile.write(Data("2".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "2")
        #expect(try temporaries(in: url.deletingLastPathComponent()).isEmpty)
    }

    /// 本体を走らせている間に置かれたディレクトリも断る (本体の後の 2 回目の検め)。1 回目だけだと、
    /// 見てから本体が終わるまでの長い間 (画像の書き出しなど) に置かれたものを置き換えてしまう。
    @Test("本体を走らせている間にディレクトリが置かれても、置き換えずに失敗し、中身は残る")
    func refusesADirectoryThatAppearsWhileTheBodyRuns() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("late.json")
        var inner: URL?
        #expect(throws: (any Error).self) {
            try AtomicFile.write(to: url) { temporary in
                try Data("new".utf8).write(to: temporary)
                // 本体の最中に、別の主体が同じ場所へ中身のあるディレクトリを置く
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let file = url.appendingPathComponent("inner.txt")
                try "keep me".write(to: file, atomically: true, encoding: .utf8)
                inner = file
            }
        }
        #expect(isDirectory(url), "ディレクトリが消えた")
        #expect(try String(contentsOf: #require(inner), encoding: .utf8) == "keep me")
        #expect(try temporaries(in: facet).isEmpty, "一時ファイルが残った")
    }

    // ---------------------------------------------------------- 消す口も、ディレクトリは消さない (#2859)

    @Test("remove は、ディレクトリを中身ごと消さずに残し、ファイルは消す")
    func removeLeavesDirectoriesAlone() throws {
        let (directory, inner) = try makeFullDirectory()
        #expect(!AtomicFile.remove(directory), "ディレクトリを消した扱いにしている")
        #expect(isDirectory(directory))
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me")

        let file = directory.deletingLastPathComponent().appendingPathComponent("plain.json")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(AtomicFile.remove(file))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // 無いものを消すのは、これまでどおり何もしない
        #expect(AtomicFile.remove(file))
    }

    @Test("remove は、ディレクトリを指す symlink を外すだけで、指す先は残す")
    func removeUnlinksASymlinkWithoutFollowingIt() throws {
        let (directory, inner) = try makeFullDirectory()
        let link = directory.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(AtomicFile.remove(link))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(isDirectory(directory))
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me")
    }

    // ---------------------------------------------------------- 動画の書き出し先がディレクトリ (#2859)

    /// 書き出し先は利用者が指定するパス。`MovieFile.init` は「同じ名前が残っていると開けない」ので
    /// 無条件に消していたが、ディレクトリを指すと中身ごと消えた。符号化器が無い機械でも確かめられるよう、
    /// 断りは符号化器の問い合わせより前にある。
    @Test("動画の書き出し先がディレクトリなら、消さずに Is a directory で失敗する")
    func movieFileRefusesADirectoryDestination() throws {
        let (directory, inner) = try makeFullDirectory()
        let failure = #expect(throws: MovieWriteFailure.self) {
            _ = try MovieFile(path: directory.path, width: 32, height: 18, frameRate: 30)
        }
        #expect(failure == .writeFailed(path: directory.path, reason: "Is a directory"))
        #expect(isDirectory(directory))
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me")
    }

    /// 文字の書き出しは、置き換えて書く (`.atomic`) と下の失敗が ENOENT になるが、`Is a directory` と名乗る。
    @Test("TextFile.write は、書く先がディレクトリなら Is a directory と名乗り、中身は残る")
    func textFileNamesADirectoryDestination() throws {
        let (directory, inner) = try makeFullDirectory()
        let failure = #expect(throws: DataFailure.self) {
            try TextFile.write("x", to: directory.path)
        }
        #expect(failure == .unwritable(path: directory.path, reason: "Is a directory"))
        #expect(isDirectory(directory))
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me")
    }

    // MARK: - 区画の JSON は rename(2) で置き、保存・作品の出力は属性を引き継ぐ (#2382)

    /// 既存のファイルの権限が、置いた後どうなるか。`replaceItemAt` は引き継ぎ、`rename(2)` は
    /// 一時ファイルの既定のままにする。
    private func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test("区画の JSON (writeJSON・publishJSON) は rename(2) で置くので、既存のファイルの権限を引き継がない")
    func jsonReplacementDoesNotCarryAttributes() throws {
        let facet = try makeFacet()
        for (name, put) in [
            ("write.json", { (url: URL) in try AtomicFile.writeJSON(self.sample, to: url) }),
            ("publish.json", { (url: URL) in _ = AtomicFile.publishJSON(self.sample, to: url, "見本") }),
        ] {
            let url = facet.appendingPathComponent(name)
            try "old".write(to: url, atomically: true, encoding: .utf8)
            // 一時ファイルの権限は `0666 & ~umask` で、実行ビットは決して立たない。umask に頼らず「引き継がれた」と
            // 分かるよう、umask から生まれえない 0750 を行き先に付ける
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: url.path)
            try put(url)
            #expect(try permissions(of: url) != 0o750, "\(name): 属性を引き継いでいる (replaceItemAt のまま)")
            #expect(keys(in: try String(contentsOf: url, encoding: .utf8)) == ["apple", "middle", "zebra"])
        }
    }

    @Test("保存や作品の出力の口 (write) は、これまでどおり既存のファイルの権限を引き継ぐ (#2859 の完了条件 4)")
    func plainWriteStillCarriesAttributes() throws {
        let url = try makeFacet().appendingPathComponent("saved.json")
        try "old".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try AtomicFile.write(Data("new".utf8), to: url)
        #expect(try permissions(of: url) == 0o640)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }

    @Test("区画の JSON を何度書き直しても、読み手は前か新しい中身だけを見て、一時ファイルは残らない")
    func jsonRewritesLeaveNoTemporaries() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("loop.json")
        for round in 0..<50 {
            try AtomicFile.writeJSON(Sample(zebra: round, apple: "a", middle: true), to: url)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("\"zebra\" : \(round)"), "round \(round): \(text)")
        }
        #expect(try temporaries(in: facet).isEmpty)
    }

    @Test("区画の JSON は、書く先がディレクトリなら置かず、一時ファイルも残さない")
    func jsonRefusesADirectoryWithoutLeavingTemporaries() throws {
        let (directory, inner) = try makeFullDirectory()
        #expect(throws: (any Error).self) { try AtomicFile.writeJSON(sample, to: directory) }
        #expect(isDirectory(directory))
        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep me")
        #expect(try temporaries(in: directory.deletingLastPathComponent()).isEmpty)
    }

    @Test("行き先がファイルを指す symlink なら、リンク自身が普通のファイルに置き換わり、指す先は変わらない")
    func jsonReplacesASymlinkItself() throws {
        let facet = try makeFacet()
        let target = facet.appendingPathComponent("target.json")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        let link = facet.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try AtomicFile.writeJSON(sample, to: link)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil, "リンクのまま")
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(keys(in: try String(contentsOf: link, encoding: .utf8)) == ["apple", "middle", "zebra"])
    }
}
