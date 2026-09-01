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
        #expect(document.contains("mokume 0.1.0 はこの面を持たない"))
    }

    /// **版が読めなくても、持たないことは言える。** 断定できないのは版のほうだけである。
    @Test("版が読めなければ、版を名乗らずに持たないとだけ言う")
    func stillNamesTheMissingFacetWithoutAVersion() throws {
        let consumer = try ConsumerFixture.make(facets: ["observe"])
        let document = StartupReadsReport.document(
            base: consumer.work, given: false, package: consumer.work)
        #expect(document.contains("依存している mokume はこの面を持たない"))
    }

    /// 切り分けの口は、読めた版をそのまま出し、読めなければ「判定できず」と言う。
    @Test("切り分けの口が、依存している版を並べる")
    func theDoctorListsTheDependencyVersion() {
        let place = URL(fileURLWithPath: "/tmp/sketch", isDirectory: true)
        let known = DoctorCommand.stateLines(
            .init(place: place, hasPackage: true, hasBuild: true, dependency: "0.5.0"))
        #expect(known.contains { $0.contains("依存している mokume: 0.5.0") })

        let unknown = DoctorCommand.stateLines(
            .init(place: place, hasPackage: true, hasBuild: true, dependency: nil))
        #expect(
            unknown.contains {
                $0.contains("依存している mokume") && $0.contains(DoctorCommand.unknown)
            })
    }
}
