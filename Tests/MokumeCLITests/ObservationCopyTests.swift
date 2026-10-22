// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 窓口が返した絵の場所は、別の書き手の次の撮影で書き換わらないこと
/// ([#2992](https://github.com/mokume-metal/mokume/issues/2992))。
///
/// 観測の区画は応答 1 枚・要求 1 枚で、書き手を調停しない。窓口が区画の中の場所をそのまま返すと、
/// 別の書き手の撮り始めが応答と絵を消して同じ名前で書き直した後に、呼び手は別の書き手の絵を自分の絵として
/// 読みうる。窓口は絵を自分の置き場へ写し、**写し終えた後に応答がまだ自分の識別子を echo している**
/// ことを確かめてから渡す。掃除は応答を先に消す (`FrameObserver.clearProducts()`) ので、確かめられれば
/// 写している間に掃除は始まっていない。確かめられなければ #2857 の取り合いとして答える。
///
/// 検査は `FacetsContestedTests` と同じ形で、区画のファイルを置くだけで GPU は要らない。
/// **別の書き手が割り込む瞬間は、写し方 (`ObservationCopies.copyItem`) を差し替えて作る。**
@Suite("返した絵は別の書き手の撮影で変わらない")
struct ObservationCopyTests {
    private nonisolated func put(_ text: String, at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private nonisolated func reportJSON(id: String, names: [String]) -> String {
        let frames = names.enumerated().map {
            #"{"image":"\#($1)","frame":\#($0 + 1),"time":0.5}"#
        }.joined(separator: ",")
        return #"{"id":"\#(id)","schemaVersion":1,"frame":1,"time":0.5,"image":"\#(names.last ?? "")","frames":[\#(frames)],"warnings":[]}"#
    }

    /// 道具立て。区画は応答の置いてある状態にして、置き場は検査の一時の場所へ向ける。
    private struct Place {
        let directory: URL
        let facets: Facets
        var tools: Tools
        var facet: URL { facets.observeFacet }
        var report: URL { WorkDirectory.reportURL(under: facet) }
        var copies: ObservationCopies { tools.copies }
    }

    private func makePlace(id: String = "H", keep: Int = 4) -> Place {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-copy-\(UUID().uuidString)", isDirectory: true)
        let facets = Facets(directory: directory)
        var tools = Tools(facets: facets, makeID: { id })
        tools.copies = ObservationCopies(
            root: directory.appendingPathComponent("copies", isDirectory: true), keep: keep)
        return Place(directory: directory, facets: facets, tools: tools)
    }

    /// 自分の要求に応えた後の区画を置く。絵の中身は名前ごとに指す。
    private func stage(_ place: Place, id: String = "H", pictures: [(String, String)]) {
        for (name, content) in pictures { put(content, at: place.facet.appendingPathComponent(name)) }
        put(reportJSON(id: id, names: pictures.map(\.0)), at: place.report)
    }

    /// 別の書き手の撮り始めを真似る: 応答を消し、同じ名前の絵を別の中身で置き直し、自分の応答を置く。
    private func sweep(_ place: Place, pictures: [(String, String)], writer: String = "A") {
        try? FileManager.default.removeItem(at: place.report)
        for (name, content) in pictures { put(content, at: place.facet.appendingPathComponent(name)) }
        put(reportJSON(id: writer, names: pictures.map(\.0)), at: place.report)
    }

    private func imagePath(_ text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix("Image: ") }.map { String($0.dropFirst("Image: ".count)) }
    }

    // MARK: - 1: 返した絵は書き換わらない

    @Test("答えが指す絵は、別の書き手が撮り直しても元の中身のままである")
    func theReturnedPictureSurvivesTheNextWriter() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        let finished = DispatchSemaphore(value: 0)
        // 窓口が待っている間に、子の代わりに絵と応答を置く
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            put("X", at: place.facet.appendingPathComponent("frame-000.png"))
            put(reportJSON(id: "H", names: ["frame-000.png"]), at: place.report)
            finished.signal()
        }
        let outcome = place.tools.call("observe", arguments: [:])
        _ = finished.wait(timeout: .now() + 5)
        #expect(!outcome.isError)
        let path = try #require(imagePath(outcome.text))

        sweep(place, pictures: [("frame-000.png", "Y")])

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "X")
        #expect(!path.hasPrefix(place.facet.path), "区画の中を指している: \(path)")
    }

    @Test("写しは目録の名前のまま、区画の外の置き場に置かれる")
    func theCopyKeepsTheCataloguedName() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("frame-0001.png", "one")])
        let path = try #require(imagePath(place.tools.call("observe", arguments: [:]).text))
        #expect(URL(fileURLWithPath: path).lastPathComponent == "frame-0001.png")
        #expect(path.hasPrefix(place.copies.root.path))
    }

    // MARK: - 2: 写している間に掃除が始まったら絵を返さない

    @Test("写している間に応答が消えたら、取り合いとして答え、絵の場所を返さない")
    func aSweepWhileCopyingIsContested() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("frame-000.png", "X")])
        place.copies.copyItem = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            sweep(place, pictures: [("frame-000.png", "Y")])
        }
        let outcome = place.tools.call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("Another writer"), "取り合ったと言わない: \(outcome.text)")
        #expect(outcome.text.contains("again"), "撮り直してよいと言わない: \(outcome.text)")
        #expect(!outcome.text.contains("Image"), "絵の場所を返した: \(outcome.text)")
        #expect(!outcome.text.contains(place.copies.root.path), "写しの場所を返した: \(outcome.text)")
        #expect(!outcome.text.contains("did not answer"), "応えなかったと偽った: \(outcome.text)")
        #expect(!FileManager.default.fileExists(atPath: place.copies.root.appendingPathComponent("H").path),
            "渡さなかった写しが残っている")
    }

    @Test("応答が別の識別子に変わった回も、同じく取り合いとして答える")
    func anotherIdentifierWhileCopyingIsContested() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("frame-000.png", "X")])
        place.copies.copyItem = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            put(reportJSON(id: "theirs", names: ["frame-000.png"]), at: place.report)
        }
        let outcome = place.tools.call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("Another writer"))
        #expect(imagePath(outcome.text) == nil)
    }

    @Test("time 付きの観測は、撮り直してよいと言わず、確かめてからと言う")
    func aTimedObservationIsNotSaidToBeSafeToRepeat() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        let time = Double(Float(0.5))
        put(
            #"{"id":"H","schemaVersion":2,"appliedTime":\#(time),"frame":1,"time":\#(time),"image":"frame-000.png","frames":[{"image":"frame-000.png","frame":1,"time":\#(time)}],"warnings":[]}"#,
            at: place.report)
        put("X", at: place.facet.appendingPathComponent("frame-000.png"))
        place.copies.copyItem = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            sweep(place, pictures: [("frame-000.png", "Y")])
        }
        let outcome = place.tools.call("observe", arguments: ["time": 0.5])
        #expect(outcome.isError)
        #expect(outcome.text.contains("Another writer"))
        #expect(!outcome.text.contains("is safe"), "撮り直してよいと言った: \(outcome.text)")
        #expect(outcome.text.contains("without time"), "確かめてからと言わない: \(outcome.text)")
    }

    // MARK: - 3: 列も同じ

    @Test("列は全枚を写してから確かめる。全枚が自分の撮影のものなら、置き場と名前の一覧を返す")
    func aSeriesIsCopiedWhole() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("a.png", "1"), ("b.png", "2"), ("c.png", "3")])
        let outcome = place.tools.call("observe", arguments: ["count": 3])
        #expect(!outcome.isError)
        #expect(outcome.text.contains("Images (3)"))
        #expect(outcome.text.contains("a.png b.png c.png"))
        let directory = place.copies.root.appendingPathComponent("H")
        #expect(outcome.text.contains("\(directory.path)/"))
        sweep(place, pictures: [("a.png", "x"), ("b.png", "y"), ("c.png", "z")])
        for (name, content) in [("a.png", "1"), ("b.png", "2"), ("c.png", "3")] {
            #expect(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) == content)
        }
    }

    @Test("列の途中で掃除が始まったら、1 枚も渡さない")
    func aSweepInTheMiddleOfASeriesIsContested() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("a.png", "1"), ("b.png", "2"), ("c.png", "3")])
        var copied = 0
        place.copies.copyItem = { source, destination in
            if copied == 1 { sweep(place, pictures: [("a.png", "x"), ("b.png", "y"), ("c.png", "z")]) }
            copied += 1
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let outcome = place.tools.call("observe", arguments: ["count": 3])
        #expect(outcome.isError)
        #expect(outcome.text.contains("Another writer"))
        #expect(!outcome.text.contains("Images"), "写しの場所を返した: \(outcome.text)")
        #expect(!FileManager.default.fileExists(atPath: place.copies.root.appendingPathComponent("H").path))
    }

    @Test("写せなかった枚があり応答が消えていたら、掃除の後と読んで取り合いとして答える")
    func aMissingSourceAfterASweepIsContested() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("a.png", "1"), ("b.png", "2")])
        // 掃除は応答を先に、絵を後に消す。2 枚目を写す前に絵が消えた
        place.copies.copyItem = { source, destination in
            if source.lastPathComponent == "b.png" {
                try? FileManager.default.removeItem(at: place.report)
                try? FileManager.default.removeItem(at: source)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let outcome = place.tools.call("observe", arguments: ["count": 2])
        #expect(outcome.isError)
        #expect(outcome.text.contains("Another writer"), "取り合ったと言わない: \(outcome.text)")
    }

    // MARK: - 写せなかったが応答が自分のまま (取り合いではない)

    @Test("応答が自分のままで写せなかった回は、取り合ったとは言わず、区画の場所と次の要求までと返す")
    func aFailedCopyWithMyAnswerStandingIsNotAContest() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("frame-000.png", "X")])
        place.copies.copyItem = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let outcome = place.tools.call("observe", arguments: [:])
        #expect(!outcome.isError)
        #expect(!outcome.text.contains("Another writer"), "取り合ったと偽った: \(outcome.text)")
        let path = try #require(imagePath(outcome.text))
        #expect(path == place.facet.appendingPathComponent("frame-000.png").path)
        #expect(outcome.text.contains("until the next request"), "次の要求までと言わない: \(outcome.text)")
    }

    @Test("区画の外へ抜ける絵の名前は写さず、区画の場所と次の要求までと返す")
    func aNameThatLeavesTheFacetIsNotCopied() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        put(reportJSON(id: "H", names: ["../escape.png"]), at: place.report)
        let outcome = place.tools.call("observe", arguments: [:])
        #expect(!outcome.isError)
        #expect(outcome.text.contains("until the next request"))
        #expect(!FileManager.default.fileExists(atPath: place.copies.root.appendingPathComponent("escape.png").path))
    }

    // MARK: - 目録を書かない版 (#408 より前)

    /// その版は応答を消さずに絵を先に上書きする (v0.1.0 の `respond`)。**応答が自分の識別子のままでも
    /// 他人の絵でありうる**ので、写した後の確かめは何も言えない。写さず、確かめられないことを名乗る。
    @Test("目録の無い版は、写さず、区画の場所と確かめられないことを名乗る")
    func aReplyWithoutACatalogueIsNotCopiedAndSaysSo() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        put("X", at: place.facet.appendingPathComponent("frame.png"))
        put(#"{"id":"H","schemaVersion":1,"frame":1,"time":0.5,"image":"frame.png","warnings":[]}"#, at: place.report)
        let outcome = place.tools.call("observe", arguments: [:])
        #expect(!outcome.isError)
        let path = try #require(imagePath(outcome.text))
        #expect(path == place.facet.appendingPathComponent("frame.png").path)
        #expect(outcome.text.contains("until the next request"), "次の要求までと言わない: \(outcome.text)")
        #expect(outcome.text.contains("cannot be checked"), "確かめられないと言わない: \(outcome.text)")
        #expect(outcome.text.contains("has no catalogue (frames)"))
        #expect(!FileManager.default.fileExists(atPath: place.copies.root.path), "確かめられないものを写した")
    }

    // MARK: - 本文の JSON

    @Test("本文の JSON の絵の名前も、返す場所の絶対の綴りになっている")
    func theJSONNamesTheReturnedPlace() throws {
        let place = makePlace()
        defer { try? FileManager.default.removeItem(at: place.directory) }
        stage(place, pictures: [("a.png", "1"), ("b.png", "2")])
        let outcome = place.tools.call("observe", arguments: ["count": 2])
        let directory = place.copies.root.appendingPathComponent("H").path
        let json = try #require(outcome.text.range(of: "{"))
        let body = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.text[json.lowerBound...].utf8)) as? [String: Any])
        #expect(body["image"] as? String == "\(directory)/b.png")
        let frames = try #require(body["frames"] as? [[String: Any]])
        #expect(frames.compactMap { $0["image"] as? String } == ["\(directory)/a.png", "\(directory)/b.png"])
        for case let path as String in frames.map({ $0["image"] as Any }) {
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    // MARK: - 4: 写しは溜め続けない

    @Test("直近の観測の分だけ残し、古い写しは次の写しで消える。読むまでは消えない")
    func copiesAreBoundedAndOutliveTheNextCall() throws {
        let place = makePlace(keep: 2)
        defer { try? FileManager.default.removeItem(at: place.directory) }
        var paths: [String] = []
        for number in 1...4 {
            var tools = place.tools
            tools.makeID = { "id\(number)" }
            stage(place, id: "id\(number)", pictures: [("frame-000.png", "picture \(number)")])
            paths.append(try #require(imagePath(tools.call("observe", arguments: [:]).text)))
            // 呼び手が読むのは、返った直後 (次の observe の前) — 消えていない
            #expect(try String(contentsOfFile: paths[number - 1], encoding: .utf8) == "picture \(number)")
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: place.copies.root.path).sorted()
        #expect(remaining == ["id3", "id4"], "上限 2 件を超えて残っている: \(remaining)")
        #expect(!FileManager.default.fileExists(atPath: paths[0]))
        #expect(try String(contentsOfFile: paths[2], encoding: .utf8) == "picture 3")
    }

    @Test("同じ識別子で続けて観測しても、写しの数は増えない")
    func theSameIdentifierDoesNotAddCopies() throws {
        let place = makePlace(keep: 2)
        defer { try? FileManager.default.removeItem(at: place.directory) }
        for number in 1...5 {
            stage(place, pictures: [("frame-000.png", "picture \(number)")])
            let path = try #require(imagePath(place.tools.call("observe", arguments: [:]).text))
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "picture \(number)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.copies.root.path) == ["H"])
    }

    @Test("窓口が終われば、置き場ごと消える")
    func theRootGoesWithTheWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("copies", isDirectory: true)
        var copies: ObservationCopies? = ObservationCopies(root: root)
        _ = copies?.copy(names: [], from: directory, id: "H")
        #expect(FileManager.default.fileExists(atPath: root.path))
        copies = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("既定の置き場は、窓口ごとに違う一時の場所で、区画の中ではない")
    func theDefaultRootIsPerWindowAndOutsideTheFacet() {
        let first = ObservationCopies()
        let second = ObservationCopies()
        #expect(first.root != second.root)
        #expect(first.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!first.root.path.contains("/.mokume/"))
    }

    // MARK: - 信号で終わった窓口の置き場

    @Test("持ち主のプロセスが居ない古い置き場は、次の窓口が掃く。生きている持ち主と自分のは残す")
    func staleRootsOfDeadOwnersAreSwept() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = ObservationCopies.prefix
        let dead = directory.appendingPathComponent("\(prefix)4000001-aaaa")
        let alive = directory.appendingPathComponent("\(prefix)4000002-bbbb")
        let mine = directory.appendingPathComponent("\(prefix)\(getpid())-cccc")
        let others = [
            directory.appendingPathComponent("mokume-observe-4000001-aaaa"),
            directory.appendingPathComponent("\(prefix)notapid-dddd"),
        ]
        for url in [dead, alive, mine] + others {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        ObservationCopies.sweepStale(in: directory, isAlive: { $0 != 4_000_001 })
        #expect(!FileManager.default.fileExists(atPath: dead.path), "持ち主が居ない置き場が残った")
        for url in [alive, mine] + others {
            #expect(FileManager.default.fileExists(atPath: url.path), "消してはいけない: \(url.lastPathComponent)")
        }
        // 既定の判定でも、自分の pid は生きている
        ObservationCopies.sweepStale(in: directory)
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    @Test("既定の置き場の名前は持ち主の pid を持つ")
    func theDefaultRootNamesItsOwner() {
        let root = ObservationCopies().root
        #expect(root.lastPathComponent.hasPrefix("\(ObservationCopies.prefix)\(getpid())-"))
    }

    // MARK: - 枚数の上限

    @Test("残す絵の枚数の合計が上限を越えたら、古い観測から消す。最新の 1 件は越えても残す")
    func picturesAreBoundedByTheirTotalCount() throws {
        let place = makePlace(keep: 10)
        defer { try? FileManager.default.removeItem(at: place.directory) }
        let copies = ObservationCopies(root: place.copies.root, keep: 10, maxPictures: 5)
        func observe(_ id: String, _ count: Int) throws {
            var tools = place.tools
            tools.copies = copies
            tools.makeID = { id }
            let names = (1...count).map { "\(id)-\($0).png" }
            stage(place, id: id, pictures: names.map { ($0, "x") })
            _ = tools.call("observe", arguments: ["count": count])
        }
        try observe("one", 2)
        try observe("two", 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.copies.root.path).sorted() == ["one", "two"])
        try observe("three", 2)  // 合計 6 枚 > 5: 最も古い 1 件を消す
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.copies.root.path).sorted() == ["three", "two"])
        try observe("big", 8)  // 1 件で 8 枚 > 5: 古いものはすべて消え、最新の 1 件だけ残る
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.copies.root.path) == ["big"])
    }
}
