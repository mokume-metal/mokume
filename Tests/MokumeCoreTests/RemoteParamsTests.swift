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

    /// 外枠が読めない応答は、いままでどおり確定させずに黙って次を待つ (飛ばす単位は宣言 1 件)。
    @Test("params が配列でない応答は、従来どおりつまみを並べない")
    func anUnreadableEnvelopeIsStillLeftAlone() throws {
        try withFacet { facet in
            try publishRaw(params: #"{"name":"a"}"#, at: facet)
            var said: [String] = []
            let params = RemoteParams(directory: facet, warn: { said.append($0) })
            #expect(!params.refresh())
            #expect(params.boxes.isEmpty)
            #expect(said.isEmpty)
        }
    }
}
