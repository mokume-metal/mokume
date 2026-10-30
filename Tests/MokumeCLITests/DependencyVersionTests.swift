// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCLI

/// 依存として解決されている版 (#684)。
///
/// **持たないと言うなら、いくつなのかも言う。** 面を持たない理由に当たった人が、
/// どこまで上げればよいかを知るために要る。
@Suite("依存している版")
struct DependencyVersionTests {
    private func makePackage(_ resolved: String?) throws -> URL {
        let root = try TestScratch.directory("mokume-version")
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

    // MARK: - 版が引けない理由 (#3419)

    private func makeSketch(resolved: String?, manifest: Bool = true) throws -> URL {
        let root = try makePackage(resolved)
        if manifest {
            try "// swift-tools-version: 6.2\n".write(
                to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("版が引けない理由を、置かれているファイルから分ける")
    func tellsWhyTheVersionIsUnknown() throws {
        // 作ったばかり: Package.swift があって Package.resolved が無い
        #expect(DependencyVersion.state(forPackageAt: try makeSketch(resolved: nil)) == .unresolved)
        // 解決済みだが mokume の pin が無い (パス依存。swift-syntax だけが載る)
        #expect(
            DependencyVersion.state(
                forPackageAt: try makeSketch(
                    resolved:
                        #"{"pins":[{"identity":"swift-syntax","state":{"version":"603.0.2"}}],"version":3}"#))
                == .notPinned)
        // 版で固定 / 改訂で固定
        #expect(
            DependencyVersion.state(
                forPackageAt: try makeSketch(
                    resolved: #"{"pins":[{"identity":"mokume","state":{"version":"0.5.0"}}],"version":3}"#))
                == .version("0.5.0"))
        #expect(
            DependencyVersion.state(
                forPackageAt: try makeSketch(
                    resolved:
                        #"{"pins":[{"identity":"mokume","state":{"branch":"main","revision":"abcdef0123456789"}}],"version":3}"#))
                == .revision("abcdef0123456789"))
        // スケッチの場所でない
        #expect(
            DependencyVersion.state(forPackageAt: try makeSketch(resolved: nil, manifest: false))
                == .noPackage)
        // 読めない (壊れている): pin が無いのではなく、読めない
        #expect(
            DependencyVersion.state(forPackageAt: try makeSketch(resolved: "{ not json"))
                == .unreadable)
    }

    /// **版・改訂は名前に使う前に検める** (#3535)。先頭が数字で、数字・`.`・`-`・`+`・英字だけを版とみなす。
    @Test(
        "版の形 (先頭が数字で、数字・.・-・+・英字だけ) の判定",
        arguments: [
            ("0.5.0", true), ("1.0.0-beta.1", true), ("0.5.0+build5", true), ("2", true), ("1..2", true),
            ("../../x", false), ("1/../../x", false), ("1/2", false), ("", false), ("..", false),
            ("v1.0.0", false), ("-1", false), ("1.0.0 ", false), ("1.0\n0", false), ("1.0。", false),
            ("１.０", false),
        ])
    func recognisesAVersion(text: String, isVersion: Bool) {
        #expect(DependencyVersion.isVersion(text) == isVersion)
    }

    @Test(
        "改訂の形 (16 進数の字だけ) の判定",
        arguments: [
            ("abcdef0123456789", true), ("0000", true), ("ABCDEF", true), ("", false), ("../../x", false),
            ("abc/def", false), ("xyz", false), ("abc ", false),
        ])
    func recognisesARevision(text: String, isRevision: Bool) {
        #expect(DependencyVersion.isRevision(text) == isRevision)
    }

    /// 形が違う pin は、版へも改訂へも寄せず、壊れた `Package.resolved` として扱う。名前に使う口 (`pin`・`resolved`) は何も返さない。
    @Test("版・改訂の形でない pin は、壊れているものとして読み、鍵にも版にもならない")
    func aMalformedPinIsReadAsDamaged() throws {
        for state in [
            #"{"version":"../../x"}"#, #"{"version":"1/../../x"}"#, #"{"version":""}"#,
            // 版で固定した pin は改訂も持つ。版が壊れているなら、改訂へ落とさない
            #"{"version":"../x","revision":"abcdef0123"}"#, #"{"revision":"../../x"}"#, #"{"branch":"main","revision":""}"#,
        ] {
            let sketch = try makeSketch(
                resolved: #"{"pins":[{"identity":"mokume","state":\#(state)}],"version":3}"#)
            #expect(DependencyVersion.state(forPackageAt: sketch) == .unreadable, "\(state)")
            #expect(DependencyVersion.pin(forPackageAt: sketch) == nil, "\(state)")
            #expect(DependencyVersion.resolved(forPackageAt: sketch) == nil, "\(state)")
        }
    }

    /// 作ったばかりのスケッチの `doctor` が、パスで指していると決めつけない。
    @Test("まだ解決していないスケッチには、パスで指しているとは言わず、解決の手を言う")
    func doesNotBlameAPathWhenNotResolvedYet() {
        let line = DoctorCommand.dependencyLine(nil, state: .unresolved)
        #expect(line.contains("not resolved yet"))
        #expect(!line.contains("pointing at a path"))
        // 道具の既定と同じ置き場で解決する `run` を勧める。裸の `swift package resolve` は
        // スケッチ直下に `.build/` を作る (#3419)
        #expect(line.contains("\(Command.name) run"))
        #expect(!line.contains("swift package resolve"))
        // 解決してあるのに pin が無い回は、今までの文言のまま
        #expect(DoctorCommand.dependencyLine(nil, state: .notPinned).contains("pointing at a path does this"))
    }

    /// 読めない `Package.resolved` や枝・改訂の固定も、「パスで指している」とは言わない (#3419)。
    @Test("読めない Package.resolved や改訂の固定を、パスで指しているとは言わない")
    func doesNotBlameAPathWhenTheVersionIsUnknownForOtherReasons() {
        let unreadable = DoctorCommand.dependencyLine(nil, state: .unreadable)
        #expect(unreadable.contains("could not be read"))
        #expect(!unreadable.contains("pointing at a path"))
        let revision = DoctorCommand.dependencyLine(nil, state: .revision("0123456789abcdef"))
        #expect(revision.contains("0123456789ab"))
        #expect(!revision.contains("pointing at a path"))
        #expect(!DoctorCommand.dependencyLine(nil, state: .noPackage).contains("pointing at a path"))
    }

    /// 状態を読む配線 (`state(for:)` が `dependencyState` を埋める) を、実物の置き場から固定する。
    @Test("doctor の状態は、壊れた Package.resolved を unreadable として読む")
    func doctorReadsAnUnreadablePackageResolved() throws {
        let sketch = try makeSketch(resolved: "{ not json")
        let state = DoctorCommand.probeState(
            in: sketch, facetBase: sketch, environment: [BuildDirectory.environmentKey: sketch.path],
            home: sketch)
        #expect(state.dependencyState == .unreadable)
        #expect(state.dependency == nil)
    }
}
