// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 依存している版が持たない面を、読み手が名乗るところ ([#647])。GPU は要らない。
///
/// **無応答は「相手が死んでいる」と区別が付かない** ([ADR-0018] 決定 3)。面は版によって
/// 増えるので、古い版を固定したスケッチでは「その面が無い」ことが無応答としてしか現れない。
/// 書き手が古ければ自分では名乗れないため、突き合わせるのは読み手の仕事になる (同 決定 6)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#647]: https://github.com/mokume-metal/mokume/issues/647
@Suite("依存が持たない面")
struct DependencyFacetsTests {
    /// 面の区画の名前。
    static let allFacets = StartupReads.all.filter { $0.origin == .facet }.map(\.key)

    // MARK: - 判定

    @Test("古い版を模した依存では、後から足された面が挙がる")
    func namesTheFacetsAddedLater() throws {
        // v0.1.0 の形 — 観測しか無い
        let consumer = try ConsumerFixture.make(facets: ["observe"])
        let absent = try #require(DependencyFacets.absent(forPackageAt: consumer.work))
        #expect(absent.contains(StartupReads.params))
        #expect(absent.contains(StartupReads.input))
        #expect(!absent.contains(StartupReads.observe))
    }

    @Test("面が揃っていれば、何も挙がらない")
    func namesNothingWhenEveryFacetIsPresent() throws {
        let consumer = try ConsumerFixture.make(facets: Self.allFacets)
        #expect(DependencyFacets.absent(forPackageAt: consumer.work)?.isEmpty == true)
    }

    /// **「持たない」と「判定できず」を分ける。** 誤った断定は、正しい原因から人を
    /// 遠ざけるので沈黙より悪い (`DoctorCommand` の規律 3)。
    @Test("依存を解決できなければ、判定しない")
    func doesNotJudgeWithoutAResolvedDependency() throws {
        let bare = try ConsumerFixture.makeDirectory()
        #expect(DependencyFacets.absent(forPackageAt: bare) == nil)
    }

    /// 錨が居ない在処を仕様の置き場と見なすと、**面を 1 つも持たないと誤って答える**。
    @Test("錨が居ない在処では、判定しない")
    func doesNotJudgeWithoutTheAnchor() throws {
        let consumer = try ConsumerFixture.make(facets: ["params"])
        #expect(DependencyFacets.absent(forPackageAt: consumer.work) == nil)
    }

    /// **消費側の直下に在る `Schemas/` を、依存のものと見なさない。** そこに在るのは
    /// (mokume 自身のツリーで走らせたときの) 道具側の仕様で、依存として引かれた版のもの
    /// ではない。``SchemasLocator/directory(workDirectory:executable:)`` は仕様を配る用途
    /// なので道具側へ落ちてよいが、**面の有無をそれで見ると「依存が何であれ全部持って
    /// いる」になる。**
    @Test("パッケージ直下の仕様を、依存のものと見なさない")
    func doesNotTreatTheOwnTreeSchemasAsTheDependency() throws {
        let bare = try ConsumerFixture.makeDirectory()
        let schemas = bare.appendingPathComponent("Schemas", isDirectory: true)
        try FileManager.default.createDirectory(at: schemas, withIntermediateDirectories: true)
        for facet in Self.allFacets {
            try Data(#"{}"#.utf8)
                .write(to: schemas.appendingPathComponent("\(facet)-report.schema.json"))
        }
        // 依存が解決できない以上、そこに何が在っても判定しない
        #expect(DependencyFacets.absent(forPackageAt: bare) == nil)
    }

    @Test("パスで指した依存でも判定できる")
    func judgesAPathDependency() throws {
        let consumer = try ConsumerFixture.make(local: true, facets: ["observe", "input"])
        let absent = try #require(DependencyFacets.absent(forPackageAt: consumer.work))
        #expect(absent.map(\.key) == ["params"])
    }

    @Test("面ごとの問いにも答え、判定できなければ nil を返す")
    func answersPerFacet() throws {
        let consumer = try ConsumerFixture.make(facets: ["observe"])
        #expect(DependencyFacets.lacks(StartupReads.params, forPackageAt: consumer.work) == true)
        #expect(DependencyFacets.lacks(StartupReads.observe, forPackageAt: consumer.work) == false)

        let bare = try ConsumerFixture.makeDirectory()
        #expect(DependencyFacets.lacks(StartupReads.params, forPackageAt: bare) == nil)
    }

    // MARK: - 窓口の案内

    /// **無応答の原因は 3 つある。** 2 つしか挙げないと、古い版に無い面を「まだ起動して
    /// いない」と読ませ、起動し直しても直らない道へ人を送る。
    @Test("応えないときの案内が、依存の版も原因に挙げる")
    func namesTheDependencyVersionAmongTheCauses() throws {
        let bare = try ConsumerFixture.makeDirectory()
        let tools = Tools(facets: Facets(directory: bare, waitLimit: 0.2), makeID: { "fixed" })

        let outcome = tools.call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("考えられるのは 3 つ"))
        #expect(outcome.text.contains("持たない版"))
        // 切り分けの口へ辿れること
        #expect(outcome.text.contains("doctor"))
    }

    /// **読めたなら候補を並べない。** 原因が確定しているのに 3 つ並べると、読み手は
    /// 総当たりすることになる。
    @Test("依存が面を持たないと読めたら、そう言い切る")
    func assertsWhenTheDependencyLacksTheFacet() throws {
        // 入力の面を持たない版を模す
        let consumer = try ConsumerFixture.make(facets: ["observe", "params"])
        let tools = Tools(
            facets: Facets(directory: consumer.work, waitLimit: 0.2),
            packageDirectory: consumer.work, makeID: { "fixed" })

        let outcome = tools.call("input", arguments: ["events": [["type": "mouseDown"]]])
        #expect(outcome.isError)
        #expect(outcome.text.contains("持ちません"))
        #expect(outcome.text.contains("起動し直しても直りません"))
        // 候補を並べる形になっていない
        #expect(!outcome.text.contains("考えられるのは"))
    }

    /// 持っている面では、いままでの案内のまま (断定を挟まない)。
    @Test("持っている面では、案内が候補を並べる")
    func stillListsCausesForAFacetTheDependencyHas() throws {
        let consumer = try ConsumerFixture.make(facets: Self.allFacets)
        let tools = Tools(
            facets: Facets(directory: consumer.work, waitLimit: 0.2),
            packageDirectory: consumer.work, makeID: { "fixed" })

        let outcome = tools.call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("考えられるのは 3 つ"))
        #expect(!outcome.text.contains("持ちません"))
    }

    // MARK: - 切り分けの口

    /// **在る / 無いだけでは足りない。** 区画が在っても、依存がその面を持たなければ
    /// 応答は来ない。
    @Test("依存が持たない面を、起動の一覧が名乗る")
    func namesFacetsTheDependencyLacksInTheStartupList() throws {
        let consumer = try ConsumerFixture.make(facets: ["observe", "input"])
        let document = StartupReadsReport.document(
            base: consumer.work, given: false, package: consumer.work)

        #expect(document.contains("依存している mokume はこの面を持たない"))
        // 持っている面には添えない
        for line in document.split(separator: "\n")
        where line.contains(StartupReads.observe.name) {
            #expect(!line.contains("持たない"))
        }
    }

    @Test("判定できないときは、一覧に何も添えない")
    func addsNothingToTheListWhenItCannotJudge() throws {
        let bare = try ConsumerFixture.makeDirectory()
        let document = StartupReadsReport.document(base: bare, given: false, package: bare)
        #expect(!document.contains("この面を持たない"))
    }

    @Test("切り分けの口の出力にも現れる")
    func appearsInTheDoctorReport() throws {
        let consumer = try ConsumerFixture.make(facets: ["observe"])
        let report = DoctorCommand.report(
            environment: DoctorCommandTests.sound,
            state: DoctorCommand.State(
                place: consumer.work, hasPackage: true, hasBuild: true, lastBuild: nil),
            base: consumer.work, given: false)
        #expect(report.contains("依存している mokume はこの面を持たない"))
    }
}
