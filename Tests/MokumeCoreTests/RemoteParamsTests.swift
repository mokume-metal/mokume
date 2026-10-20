// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 面越しのつまみ。
///
/// 見張りが出すプレビューはスケッチを持たないので、宣言も値も `.mokume/params` の応答から
/// 引く ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 5)。
@Suite("面越しのつまみ")
@MainActor
struct RemoteParamsTests {
    /// 区画を 1 つ作って渡す。
    private func withFacet<T>(_ body: (URL) throws -> T) rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-params-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// 走っている側が書く応答を、そのまま置く。
    private func publish(
        _ declarations: [ParamDeclaration], revision: Int = 1, id: String? = nil, at facet: URL
    ) throws {
        let report = ParamReport(
            revision: revision, id: id, params: declarations, rejected: [], clamped: [],
            discarded: [])
        try AtomicFile.write(
            try JSONEncoder().encode(report),
            to: facet.appendingPathComponent("report.json"))
    }

    /// 更新時刻を据える。**同じ改訂を掴み直せるか**を見るには、置き直しても更新時刻が
    /// 動かない状況が要る。
    private func stamp(_ url: URL, _ moment: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: moment], ofItemAtPath: url.path)
    }

    private func request(at facet: URL) throws -> [String: Any]? {
        let url = facet.appendingPathComponent("request.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 応答には名前・型・値・幅・候補が**まとめて**載っているので、読み手はこれだけで
    /// つまみを組める (ADR-0030 決定 2)。
    @Test("応答を読むと、宣言のとおりの箱が並ぶ")
    func buildsBoxesFromTheReport() throws {
        try withFacet { facet in
            try publish(
                [
                    ParamDeclaration(name: "size", value: .float(12), range: ParamRange(0...100)),
                    ParamDeclaration(
                        name: "mode", value: .string("a"), choices: ["a", "b"]),
                ], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["size", "mode"])
            #expect(params.boxes[0].range?.upperBound == 100)
            #expect(params.boxes[1].choices == ["a", "b"])
        }
    }

    /// **区画の書き方は外から書くときと同じ** (ADR-0030 決定 2)。道具だからといって
    /// 近道を作ると、面から書いたときにだけ起きる不具合が生まれる。
    @Test("動かすと、外から書くのと同じ形の要求が置かれる")
    func writesTheSameRequestShape() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            _ = params.boxes[0].write(.float(40))

            let placed = try #require(try request(at: facet))
            #expect(placed["id"] is String)
            let values = try #require(placed["values"] as? [[String: Any]])
            #expect(values.count == 1)
            #expect(values[0]["name"] as? String == "size")
            #expect(values[0]["type"] as? String == "float")
            #expect(values[0]["value"] as? Double == 40)
        }
    }

    /// **動かした直後は、まだ動かす前の応答しか無い。** そのまま採るとつまみが戻る。
    @Test("自分の要求が届く前の応答では、つまみが戻らない")
    func doesNotSnapBackBeforeTheChildAnswers() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            _ = params.boxes[0].write(.float(40))

            // 動かす前の値を運ぶ応答 (まだこちらの要求に応えていない)
            try publish(
                [ParamDeclaration(name: "size", value: .float(12))], revision: 2, at: facet)
            params.refresh()
            #expect(params.boxes[0].value == .float(40))
        }
    }

    /// 子が応えたら、**子の言うほうへ合わせる** — 収めるのも弾くのも子の仕事なので、
    /// 端で収められた値はここで見えるようになる。
    @Test("要求に応えた応答が来たら、子の値へ合わせる")
    func adoptsTheChildsValue() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            _ = params.boxes[0].write(.float(400))
            let id = try #require(try request(at: facet)?["id"] as? String)

            // 子は範囲へ収めて応えた
            try publish(
                [ParamDeclaration(name: "size", value: .float(100), range: ParamRange(0...100))],
                revision: 2, id: id, at: facet)
            params.refresh()
            #expect(params.boxes[0].value == .float(100))
        }
    }

    /// 見張りは作り直しのたびに別のスケッチを起こしうる。宣言を足した・消した・名前を
    /// 変えたときに、面が古いままにならないようにする。
    @Test("宣言の顔ぶれが変われば、箱も入れ替わる")
    func rebuildsWhenDeclarationsChange() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())

            try publish(
                [
                    ParamDeclaration(name: "size", value: .float(12)),
                    ParamDeclaration(name: "speed", value: .float(1)),
                ], revision: 2, at: facet)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["size", "speed"])
        }
    }

    /// **値が変わっただけでは組み直さない。** 組み直すと、触っている手からつまみが消える。
    @Test("値だけが変わったときは、箱を組み直さない")
    func keepsBoxesWhenOnlyValuesChange() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            let first = params.boxes[0]

            try publish(
                [ParamDeclaration(name: "size", value: .float(30))], revision: 2, at: facet)
            #expect(!params.refresh())
            #expect(params.boxes[0] === first)
            #expect(params.boxes[0].value == .float(30))
        }
    }

    /// **読む前に「読んだ」と記録しない。** 書きかけを 1 回掴んだだけでその改訂が永久に
    /// 読み飛ばされると、症状は「つまみが古い値のまま止まる」だけになり、次の書き込みが
    /// 来るまで直らない ([#987](https://github.com/mokume-metal/mokume/issues/987))。
    ///
    /// **mokume の書き手 (`AtomicFile`) は原子的に置くので、書きかけは実際には見えない。** ここは、原子的に
    /// 置かない書き手 (手で置いたファイル・ほかの道具) に備えた性質を、書きかけを作って固定している
    /// (``WatchedFile`` の説明)。
    @Test("書きかけを掴んでも、その改訂を読み飛ばさない")
    func rereadsARevisionItCouldNotDecode() throws {
        try withFacet { facet in
            let url = facet.appendingPathComponent("report.json")
            let moment = Date(timeIntervalSince1970: 1_000_000)
            // 置いている途中を掴んだ = 解けない
            try Data(#"{"revision":1,"params":[{"nam"#.utf8).write(to: url)
            try stamp(url, moment)

            let params = RemoteParams(directory: facet)
            #expect(!params.refresh())
            #expect(params.boxes.isEmpty)

            // 書き手が置き終わった。**更新時刻は動かさない** — 同じ改訂を掴み直せるかを見る
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            try stamp(url, moment)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["size"])
        }
    }

    /// **箱があった後に宣言が全部消える場面を通す。** 作ったばかりの箱は最初から空なので、
    /// 空の応答を読ませるだけでは、宣言が 0 件になっても組み直さない退行を見逃す (#2288)。
    @Test("宣言が 1 つも無ければ、箱も無い")
    func staysEmptyWithoutDeclarations() throws {
        try withFacet { facet in
            try publish([], at: facet)
            let params = RemoteParams(directory: facet)
            params.refresh()
            #expect(params.boxes.isEmpty)

            try publish([ParamDeclaration(name: "size", value: .float(12))], revision: 2, at: facet)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["size"])

            // 宣言を持たないスケッチに替わった
            try publish([], revision: 3, at: facet)
            #expect(params.refresh())
            #expect(params.boxes.isEmpty)
        }
    }

    // MARK: - 別の書き手と同じ区画を使う (#2795)

    /// 1 つの区画に、走っている側の面 (``ParamSurface``) と道具のつまみ (``RemoteParams``) を並べる。
    /// 書き手が 2 人 (人のプレビューと外の書き手) いる場面を、実物の応答の書き方で通す。
    final class Shared: Sketch {
        @Param(0...100) var radius: Double = 12
        @Param(0...10) var count: Int = 3
    }

    /// 外の書き手 (AI など) の要求を置く。
    private func placeForeign(_ id: String, _ name: String, _ wire: String, at facet: URL) throws {
        try #"{"id":"\#(id)","values":[{"name":"\#(name)",\#(wire)}]}"#.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
    }

    private func box(_ name: String, of params: RemoteParams) throws -> RemoteParam {
        try #require(params.boxes.first { $0.name == name })
    }

    /// 本文の具体例そのまま: 自分の要求 H に応えた応答を読む前に、別の書き手の要求 A に応えた
    /// 応答で置き換わる。H の echo はもう来ないので、A の応答で子の値へ合わせる。
    @Test("自分の応答を読む前に別の書き手の応答が届いても、子の値へ追い付く")
    func catchesUpWhenAnotherWritersReplyArrivesFirst() throws {
        try withFacet { facet in
            let sketch = Shared()
            let surface = ParamSurface(directory: facet, sketch: sketch)
            surface.start()
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())

            _ = try box("radius", of: params).write(.float(40))  // H
            #expect(surface.drain() != nil)  // H に応える
            try placeForeign("A", "radius", #""type":"float","value":80"#, at: facet)
            #expect(surface.drain() != nil)  // A に応える (H の応答は上書きされる)
            #expect(sketch.radius == 80)

            params.refresh()
            #expect(try box("radius", of: params).value == .float(80))
        }
    }

    /// H が読まれる前に A が要求を置き換えた。H は応えられずに消え、echo は来ない。
    @Test("自分の要求が読まれる前に別の書き手が置き換えても、子の値へ追い付く")
    func catchesUpWhenAnotherWriterReplacesTheRequest() throws {
        try withFacet { facet in
            let sketch = Shared()
            let surface = ParamSurface(directory: facet, sketch: sketch)
            surface.start()
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())

            _ = try box("radius", of: params).write(.float(40))  // H
            try placeForeign("A", "radius", #""type":"float","value":80"#, at: facet)
            #expect(surface.drain() != nil)  // A にだけ応える
            #expect(sketch.radius == 80)

            params.refresh()
            #expect(try box("radius", of: params).value == .float(80))
        }
    }

    /// 1 件の未決着が、別の名前のつまみの追従まで止め続けない。
    @Test(
        "別の書き手が別の名前だけを変えても、どのつまみも子の値へ合う",
        arguments: [true, false])
    func catchesUpOnEveryKnobWhenAnotherWriterTouchesAnotherName(myRequestWasAnswered: Bool) throws {
        try withFacet { facet in
            let sketch = Shared()
            let surface = ParamSurface(directory: facet, sketch: sketch)
            surface.start()
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())

            _ = try box("radius", of: params).write(.float(40))  // H
            if myRequestWasAnswered { surface.drain() }
            try placeForeign("A", "count", #""type":"int","value":5"#, at: facet)
            #expect(surface.drain() != nil)

            params.refresh()
            // H に応えていれば 40、置き換えで消えていれば子の 12 — どちらでも子の値
            #expect(try box("radius", of: params).value == .float(sketch.radius))
            #expect(sketch.radius == (myRequestWasAnswered ? 40 : 12))
            #expect(try box("count", of: params).value == .int(5))
        }
    }

    /// つまみを引いている間は要求が続く。前の自分の要求に応えた応答は、引いている途中の値へ戻さない。
    @Test("引いている途中に自分の前の要求の応答が届いても、つまみは戻らない")
    func doesNotSnapBackToAnEarlierRequestOfItsOwn() throws {
        try withFacet { facet in
            let sketch = Shared()
            let surface = ParamSurface(directory: facet, sketch: sketch)
            surface.start()
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            let radius = try box("radius", of: params)

            _ = radius.write(.float(40))  // H1
            #expect(surface.drain() != nil)  // H1 に応える
            _ = radius.write(.float(50))  // H2 (H1 の応答はまだ読んでいない)
            params.refresh()
            #expect(radius.value == .float(50), "前の自分の要求の応答で戻った")

            #expect(surface.drain() != nil)  // H2 に応える
            params.refresh()
            #expect(radius.value == .float(50))
            #expect(sketch.radius == 50)
        }
    }

    /// 別の書き手の要求に応えた応答が、**自分の要求より前に**書かれていた (読み手はまだ読んでいない)。
    /// それは自分の要求を含まない姿なので、読んでも戻らない。置く直前に応答を読み直していないと、
    /// 最後に読んだ応答 (1 フレーム古い) と比べて「自分の要求の後」と取り違える。
    @Test("自分の要求より前に書かれた別の書き手の応答では、まだ読んでいなくても戻らない")
    func doesNotSnapBackOnAnotherWritersEarlierReply() throws {
        try withFacet { facet in
            let sketch = Shared()
            let surface = ParamSurface(directory: facet, sketch: sketch)
            surface.start()
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())

            try placeForeign("A", "radius", #""type":"float","value":80"#, at: facet)
            #expect(surface.drain() != nil)  // A に応える (プレビューはまだ読んでいない)
            _ = try box("radius", of: params).write(.float(40))  // H
            params.refresh()
            #expect(try box("radius", of: params).value == .float(40), "自分の要求より前の応答で戻った")

            #expect(surface.drain() != nil)  // H に応える
            params.refresh()
            #expect(try box("radius", of: params).value == .float(40))
            #expect(sketch.radius == 40)
        }
    }

    /// 待っている間に続けて置いた 2 つ目の要求でも、置く前から区画にあった応答 (別の書き手の A) は
    /// 「自分の後」と読まない。待ち始めの 1 回だけ読み直していると、A で 80 へ跳んでから H2 の応えで
    /// 50 へ戻る (#2795 の反証)。
    @Test("待っている間に置いた 2 つ目の要求より前に書かれた別の書き手の応答でも、つまみは戻らない")
    func doesNotFlickerOnAnotherWritersReplyBeforeALaterRequest() throws {
        try withFacet { facet in
            let sketch = Shared()
            let surface = ParamSurface(directory: facet, sketch: sketch)
            surface.start()
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            let radius = try box("radius", of: params)

            _ = radius.write(.float(40))  // H1
            #expect(surface.drain() != nil)  // H1 に応える
            try placeForeign("A", "radius", #""type":"float","value":80"#, at: facet)
            #expect(surface.drain() != nil)  // A に応える (プレビューはまだ読んでいない)
            _ = radius.write(.float(50))  // H2 (A の応答の後に置く)
            params.refresh()
            #expect(radius.value == .float(50), "H2 より前の A の応答で跳んだ")

            #expect(surface.drain() != nil)  // H2 に応える
            params.refresh()
            #expect(radius.value == .float(50))
            #expect(sketch.radius == 50)
        }
    }

    /// 次の世代の最初の応答は、作った時点の記録の識別子 (前の世代が最後に応えた X) を載せる。
    /// それは自分の要求より前の応答なので、待ち続け、次の世代が H に応えた応答で合う。
    @Test("世代の切り替えでも、自分の要求の後に一時的に戻らず、次の世代の応えで合う")
    func waitsThroughAGenerationSwitch() throws {
        try withFacet { facet in
            // 前の世代が外の要求 X に応え、その応答が区画に残る
            let previous = ParamSurface(directory: facet, sketch: Shared())
            previous.start()
            try placeForeign("X", "count", #""type":"int","value":4"#, at: facet)
            #expect(previous.drain()?.id == "X")
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())

            // 次の世代を作る (作った時点の記録は X)
            let sketch = Shared()
            let next = ParamSurface(directory: facet, sketch: sketch)
            _ = try box("radius", of: params).write(.float(40))  // H
            next.start()  // 応答の id は X
            params.refresh()
            #expect(try box("radius", of: params).value == .float(40), "次の世代の最初の応答で戻った")

            #expect(next.drain() != nil)  // H に応える
            #expect(sketch.radius == 40)
            params.refresh()
            #expect(try box("radius", of: params).value == .float(40))
            _ = previous
        }
    }

    // ---------------------------------------------------------- 読めない宣言 (#2856)

    /// 応答を、JSON の文字列のまま置く。**知らない `type` は `ParamDeclaration` からは書けない**
    /// (新しい版のライブラリが名乗るもの) ので、手で書く。
    private func publishRaw(
        params: String, revision: Int = 1, at facet: URL
    ) throws {
        let json = #"{"schemaVersion":2,"revision":\#(revision),"params":\#(params),"rejected":[],"clamped":[],"discarded":[]}"#
        try AtomicFile.write(
            Data(json.utf8), to: WorkDirectory.reportURL(under: facet))
    }

    private static let threeWithAnUnknownType =
        #"[{"name":"a","type":"float","value":1.5},"#
        + #"{"name":"b","type":"quantum","value":1},"#
        + #"{"name":"c","type":"int","value":3}]"#

    /// 宣言 1 件が読めないだけで、応答全体を黙って捨てていた: 子が新しい版のライブラリで
    /// 知らない `type` を名乗ると、つまみが 1 つも並ばなかった。
    @Test("宣言が 1 件読めなくても、読めた宣言のつまみは並び、飛ばしたことを 1 度名乗る")
    func skipsOnlyTheUnreadableDeclaration() throws {
        try withFacet { facet in
            try publishRaw(params: Self.threeWithAnUnknownType, at: facet)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["a", "c"])
            #expect(params.boxes.map(\.value) == [.float(1.5), .int(3)])
            #expect(said.count == 1, "飛ばしたことを 1 度だけ名乗る: \(said)")
            #expect(said.first?.contains("\"b\"") == true, "読めた名前で名指す: \(said)")
            #expect(said.first?.contains("quantum") == true, "読めなかった理由を言う: \(said)")
        }
    }

    /// 応答は値が動くたびに書き直され、飛ばした宣言は読み直しのたびに同じ姿で居続ける。
    /// **読み直すたびに名乗ると、つまみを掴んでいる間ずっと標準エラーが流れる。**
    @Test("読み直しても、同じ宣言を飛ばしたことは繰り返さない。値の追従は続く")
    func saysTheSkipOnceAcrossRereads() throws {
        try withFacet { facet in
            try publishRaw(params: Self.threeWithAnUnknownType, at: facet)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            #expect(params.refresh())

            let moved =
                #"[{"name":"a","type":"float","value":9},"#
                + #"{"name":"b","type":"quantum","value":1},"#
                + #"{"name":"c","type":"int","value":4}]"#
            try publishRaw(params: moved, revision: 2, at: facet)
            try stamp(WorkDirectory.reportURL(under: facet), Date().addingTimeInterval(5))
            #expect(!params.refresh(), "顔ぶれは同じ")
            #expect(params.boxes.map(\.value) == [.float(9), .int(4)], "値は飛ばした宣言の分だけずれずに追う")
            #expect(said.count == 1, "繰り返している: \(said)")
        }
    }

    /// 名前が読めない 1 件 (オブジェクトでない・`name` が文字列でない) も、その 1 件だけ飛ばす。
    @Test("名前の読めない宣言も、その 1 件だけ飛ばす")
    func skipsANamelessDeclaration() throws {
        try withFacet { facet in
            try publishRaw(
                params: #"[{"name":"a","type":"float","value":1},42,{"name":"c","type":"int","value":3}]"#,
                at: facet)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["a", "c"])
            #expect(said.count == 1)
        }
    }

    /// **外枠が読めない応答は、つまみを並べないまま、改訂ごとに 1 度だけ名乗る** ([#2889])。
    /// 黙って捨てると、つまみが 1 つも並ばない理由がどこにも残らない (ADR-0018 決定 6)。
    /// 文面は (i) どのファイルか (ii) 読めなかった理由 (iii) 候補 (版のずれ・`mokume doctor`) を言い、
    /// 版のずれを断定しない。
    ///
    /// [#2889]: https://github.com/mokume-metal/mokume/issues/2889
    @Test("params が配列でない応答は、つまみを並べず、読み直しても 1 度だけ名乗る")
    func anUnreadableEnvelopeIsSaidOnce() throws {
        try withFacet { facet in
            try publishRaw(params: #"{"name":"a"}"#, at: facet)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            for _ in 0..<3 { #expect(!params.refresh()) }
            #expect(params.boxes.isEmpty)
            let message = try #require(said.first)
            #expect(said.count == 1, "読み直すたびに繰り返している: \(said)")
            #expect(message.contains(WorkDirectory.reportURL(under: facet).path), "どのファイルか: \(message)")
            #expect(message.contains("params"), "読めなかった理由: \(message)")
            #expect(message.contains("mokume doctor"), "候補: \(message)")
            #expect(message.contains("may"), "版のずれを断定していない: \(message)")
        }
    }

    /// **ファイルとして読めない応答 (置き場がディレクトリ・権限) は、理由だけを名乗り、版の案内を付けない。**
    /// 版の形とは関係が無い失敗に、版のずれと `mokume doctor` を案内すると的外れになる ([#2889])。
    ///
    /// [#2889]: https://github.com/mokume-metal/mokume/issues/2889
    @Test("ファイルとして読めない応答は、版の案内を付けずに 1 度だけ名乗る")
    func anUnreadableFileIsSaidWithoutAVersionHint() throws {
        try withFacet { facet in
            try FileManager.default.createDirectory(
                at: WorkDirectory.reportURL(under: facet), withIntermediateDirectories: true)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            for _ in 0..<3 { #expect(!params.refresh()) }
            #expect(said.count == 1, "\(said)")
            let message = said.first ?? ""
            #expect(message.contains(WorkDirectory.reportURL(under: facet).path), "\(message)")
            #expect(!message.contains("mokume doctor"), "\(message)")
        }
    }

    /// **名乗っても確定させない** (#987・#1048)。更新時刻が動かないまま読める中身へ差し替わっても
    /// 取り込み、取り込んだ後は何も言わない。
    @Test("名乗った後、更新時刻が動かないまま読める応答に変わっても取り込む")
    func anUnreadableEnvelopeIsStillReadAgain() throws {
        try withFacet { facet in
            let url = WorkDirectory.reportURL(under: facet)
            let moment = Date(timeIntervalSince1970: 1_000_000)
            try publishRaw(params: #"{"name":"a"}"#, at: facet)
            try stamp(url, moment)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            #expect(!params.refresh())
            #expect(said.count == 1)

            try publishRaw(params: #"[{"name":"a","type":"float","value":1}]"#, at: facet)
            try stamp(url, moment)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["a"])
            #expect(said.count == 1, "読めた改訂で名乗っている: \(said)")
        }
    }

    /// **名乗るのは改訂ごと。** 別の読めない応答に置き直されたら (更新時刻が動く)、もう 1 度。
    @Test("別の読めない応答に置き直されたら、もう 1 度だけ名乗る")
    func aNewUnreadableRevisionIsSaidAgain() throws {
        try withFacet { facet in
            let url = WorkDirectory.reportURL(under: facet)
            try publishRaw(params: #"{"name":"a"}"#, at: facet)
            try stamp(url, Date(timeIntervalSince1970: 1_000_000))
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            params.refresh()
            params.refresh()
            #expect(said.count == 1)

            try publishRaw(params: #"{"name":"b"}"#, at: facet)
            try stamp(url, Date(timeIntervalSince1970: 1_000_001))
            params.refresh()
            params.refresh()
            #expect(said.count == 2, "\(said)")
        }
    }

    /// 取り込みに使わない `revision` と、型の外れた `id` で、読めた宣言まで捨てない。
    @Test(
        "使わない revision や型の外れた id では、応答を捨てずにつまみを並べる",
        arguments: [
            #""revision":"x","id":"r1""#,
            #""id":7"#,
            #""revision":1.5,"id":null"#,
            #""revision":null"#,
        ])
    func looseEnvelopeFieldsDoNotDropTheReport(fields: String) throws {
        try withFacet { facet in
            let json = #"{"schemaVersion":2,\#(fields),"params":[{"name":"a","type":"float","value":1}],"rejected":[],"clamped":[],"discarded":[]}"#
            try AtomicFile.write(Data(json.utf8), to: WorkDirectory.reportURL(under: facet))
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["a"])
        }
    }

    /// 前の応答でも飛ばしていた宣言は繰り返さないが、**読めるようになってから再び壊れた**宣言や、
    /// 別の理由で読めなくなった宣言は、新しく飛ばしたものとして言い直す。
    @Test("読めるようになってから再び壊れた宣言・別の理由で壊れた宣言は、言い直す")
    func saysAgainWhenADeclarationBreaksAgainOrDifferently() throws {
        try withFacet { facet in
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            @MainActor func publishAndRead(_ declarations: String, revision: Int) throws {
                try publishRaw(params: declarations, revision: revision, at: facet)
                try stamp(
                    WorkDirectory.reportURL(under: facet), Date().addingTimeInterval(Double(revision) * 5))
                params.refresh()
            }
            let broken = #"[{"name":"b","type":"quantum","value":1}]"#
            try publishAndRead(broken, revision: 1)
            #expect(said.count == 1)
            try publishAndRead(broken, revision: 2)
            #expect(said.count == 1, "続いて飛ばしているものは繰り返さない")
            try publishAndRead(#"[{"name":"b","type":"float","value":1}]"#, revision: 3)
            #expect(params.boxes.map(\.name) == ["b"], "読めるようになったらつまみが並ぶ")
            try publishAndRead(broken, revision: 4)
            #expect(said.count == 2, "直ってから再び壊れたら言い直す: \(said)")
            try publishAndRead(#"[{"name":"b","type":"float","value":"not a number"}]"#, revision: 5)
            #expect(said.count == 3, "別の理由で壊れたら言い直す: \(said)")
        }
    }

    /// 名前の無い宣言は位置で指す。別々の宣言が同じ位置の鍵に畳まれて黙らされない。
    @Test("名前の無い宣言は、位置と理由で別々に名乗る")
    func namelessDeclarationsAreToldApartByPosition() throws {
        try withFacet { facet in
            try publishRaw(params: #"[42,{"name":"a","type":"float","value":1},"x"]"#, at: facet)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["a"])
            #expect(said.count == 2, "2 件とも名乗る: \(said)")
        }
    }
}
