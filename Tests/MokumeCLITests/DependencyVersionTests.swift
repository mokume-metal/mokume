// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 依存として解決されている版 (#684)。
///
/// **持たないと言うなら、いくつなのかも言う。** 面を持たない理由に当たった人が、
/// どこまで上げればよいかを知るために要る。
@Suite("依存している版")
struct DependencyVersionTests {
    private func makePackage(_ resolved: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let resolved {
            try Data(resolved.utf8).write(to: root.appendingPathComponent("Package.resolved"))
        }
        return root
    }

    @Test("pin から版を読む")
    func readsTheVersionFromThePin() throws {
        let root = try makePackage(
            #"{"pins":[{"identity":"mokume","state":{"version":"0.5.0"}}],"version":3}"#)
        #expect(DependencyVersion.resolved(forPackageAt: root) == "0.5.0")
    }

    /// **完全一致で選ぶ。** 前方一致にすると、別の依存を取り違える。
    @Test("名前の似た別の依存を取り違えない")
    func doesNotConfuseANeighbouringDependency() throws {
        let root = try makePackage(
            #"{"pins":[{"identity":"mokume-syphon","state":{"version":"0.2.0"}}],"version":3}"#)
        #expect(DependencyVersion.resolved(forPackageAt: root) == nil)
    }

    /// **断定できないときは断定しない。** パスで指した依存には pin が無い (開発中の形)。
    @Test("読めなければ、版を名乗らない")
    func staysSilentWhenItCannotTell() throws {
        #expect(DependencyVersion.resolved(forPackageAt: try makePackage(nil)) == nil)
        #expect(DependencyVersion.resolved(forPackageAt: try makePackage("こわれている")) == nil)
    }

    /// **持たないと言うなら、いくつなのかも言う。**
    @Test("面を持たないと名乗る行に、いまの版が出る")
    func namesTheVersionBesideTheMissingFacet() throws {
        let consumer = try ConsumerFixture.make(facets: ["observe"])
        try Data(#"{"pins":[{"identity":"mokume","state":{"version":"0.1.0"}}],"version":3}"#.utf8)
            .write(to: consumer.work.appendingPathComponent("Package.resolved"))

        let document = StartupReadsReport.document(
            base: consumer.work, given: false, package: consumer.work)
        #expect(document.contains("mokume 0.1.0 does not have this facet"))
    }

    /// **版が読めなくても、持たないことは言える。** 断定できないのは版のほうだけである。
    @Test("版が読めなければ、版を名乗らずに持たないとだけ言う")
    func stillNamesTheMissingFacetWithoutAVersion() throws {
        let consumer = try ConsumerFixture.make(facets: ["observe"])
        let document = StartupReadsReport.document(
            base: consumer.work, given: false, package: consumer.work)
        #expect(document.contains("the mokume you depend on does not have this facet"))
    }

    /// 切り分けの口は、読めた版をそのまま出し、読めなければ「判定できず」と言う。
    @Test("切り分けの口が、依存している版を並べる")
    func theDoctorListsTheDependencyVersion() {
        let place = URL(fileURLWithPath: "/tmp/sketch", isDirectory: true)
        let known = DoctorCommand.stateLines(
            .init(place: place, hasPackage: true, buildDirectory: place.appendingPathComponent(".build"), dependency: "0.5.0"))
        #expect(known.contains { $0.contains("mokume dependency: 0.5.0") })

        let unknown = DoctorCommand.stateLines(
            .init(place: place, hasPackage: true, buildDirectory: place.appendingPathComponent(".build"), dependency: nil))
        #expect(
            unknown.contains {
                $0.contains("mokume dependency") && $0.contains(DoctorCommand.unknown)
            })
    }

    // MARK: - 道具の版との突き合わせ (#1230)

    private static let place = URL(fileURLWithPath: "/tmp/sketch", isDirectory: true)

    private func lines(dependency: String?, tool: String?) -> [String] {
        DoctorCommand.stateLines(
            .init(
                place: Self.place, hasPackage: true, buildDirectory: nil,
                dependency: dependency, tool: tool))
    }

    /// Homebrew の 0.5.0 で作ったスケッチが 0.6.0 を解決し、観測面が黙った (#969)。
    /// **エラー文が「doctor が名乗る」と案内している以上、機械が名指しする。**
    @Test("道具の版と食い違うと、依存の行がそれを名指しする")
    func namesAMismatchBetweenToolAndDependency() {
        let mismatched = lines(dependency: "0.6.0", tool: "0.5.0")
        let line = mismatched.first { $0.hasPrefix("mokume dependency:") }
        #expect(
            line
                == "mokume dependency: 0.6.0 — does not match this tool (0.5.0); "
                + "a sketch and a tool from different versions can leave facets silent")
        // **行を増やさずに言う。** 別の行にすると、揃っているときとの差が行数に出る
        #expect(mismatched.count == lines(dependency: "0.6.0", tool: "0.6.0").count)
    }

    @Test("揃っているときは、食い違いを言わない")
    func staysSilentWhenTheyMatch() {
        #expect(lines(dependency: "0.6.0", tool: "0.6.0").contains("mokume dependency: 0.6.0"))
    }

    /// formula を作り直しただけの revision (`_1`) は、中身の版を変えない。
    @Test("Homebrew の revision が付いていても、同じ版なら食い違いを言わない")
    func ignoresTheHomebrewRevision() {
        #expect(lines(dependency: "0.7.1", tool: "0.7.1_1").contains("mokume dependency: 0.7.1"))
        #expect(!DoctorCommand.sameRelease("0.7.1", "0.7.2_1"))
    }

    /// **断定できないときは断定しない。** 手元ビルドの道具は版を持たない。
    @Test("道具の版が読めなければ、食い違いを言わない")
    func staysSilentWhenTheToolVersionIsUnknown() {
        #expect(lines(dependency: "0.6.0", tool: nil).contains("mokume dependency: 0.6.0"))
    }

    @Test("pin が無ければ、道具の版が読めても今までの文言のまま")
    func keepsTheNoPinWordingWhenTheDependencyIsUnknown() {
        #expect(
            lines(dependency: nil, tool: "0.5.0").contains(
                "mokume dependency: \(DoctorCommand.unknown) — no pin in Package.resolved "
                    + "(pointing at a path does this)"))
    }
}
