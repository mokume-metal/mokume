// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 親のフォルダに入れず、在るかを確かめられない資材を、資材を探す口がどう断るか ([#2838])。
///
/// **見つからないと言うのは、本当に無いときだけ。** 入れない親の下では、在るファイルも無いファイルも
/// `stat(2)` が `EACCES` で失敗して区別が付かない。以前は `fileExists` が偽を返して「見つからない
/// (資源の宣言を確かめよ)」になり、置いてあるファイルを探させる的外れな助言が出た。
///
/// GPU もスケッチの実行も要らない。`chmod 000` で作る入れない親は、後片付けで権利を戻して消す。
///
/// [#2838]: https://github.com/mokume-metal/mokume/issues/2838
@Suite("辿り着けない資材")
struct UnreachableAssetTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    /// 検査ごとに別の置き場。`assets` を入れない親にする。
    struct Scratch {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-unreachable-\(UUID().uuidString)")

        var assets: URL { folder.appendingPathComponent("assets") }

        /// `assets/<name>` に中身を置いてから、`assets` に入る権利を外す。**置いたファイル自体は在る。**
        /// 在るファイルと無いファイルの区別が付かないことを見るため、`name` を置かない選択もできる。
        func lock(placing name: String?) throws {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            if let name { try Data("a,b\n1,2\n".utf8).write(to: assets.appendingPathComponent(name)) }
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: assets.path)
            // root で走ると権利を外しても入れる。入れてしまうと、検査が見たいものを見ていない
            try #require(
                access(assets.appendingPathComponent("probe").path, F_OK) != 0 && errno == EACCES,
                "入れない親を作れていない")
        }

        /// 外した権利を戻してから、置き場を消す。
        func cleanUp() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: assets.path)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static var denied: String { String(cString: strerror(EACCES)) }

    /// 説明が言ってはならないこと。見つかったとも、無いとも、資源の宣言の助言も言わない。
    static let forbidden = ["was found", "Cannot find", "Looked in", "resources", "declares"]

    static func expectNoMisleadingAdvice(_ text: String) {
        for phrase in forbidden {
            #expect(!text.contains(phrase), "的外れな案内 (\(phrase)) を出している: \(text)")
        }
    }

    // MARK: - 探し方の判定 (AssetLookup)

    @Test("入れない親の下は、在るファイルも無いファイルも、在るかを確かめられないと言う", arguments: [true, false])
    func unreachableParentIsNotNotFound(present: Bool) throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: present ? "data.csv" : nil)
        let candidate = scratch.assets.appendingPathComponent("data.csv")
        #expect(AssetLookup.presence(of: candidate) == .unreachable(reason: Self.denied))
        #expect(throws: AssetFailure.unreachable(
            path: "assets/data.csv", location: candidate.standardizedFileURL.path, reason: Self.denied)
        ) {
            try AssetLookup.locate([candidate], path: "assets/data.csv")
        }
    }

    @Test("本当に無いときは、今までどおり探した場所の一覧つきで notFound")
    func trulyMissingIsStillNotFound() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        let candidates = [
            scratch.folder.appendingPathComponent("a.csv"),
            scratch.folder.appendingPathComponent("b.csv"),
        ]
        #expect(candidates.allSatisfy { AssetLookup.presence(of: $0) == .absent })
        #expect(throws: AssetFailure.notFound(path: "a.csv", searched: candidates.map(\.path))) {
            try AssetLookup.locate(candidates, path: "a.csv")
        }
    }

    /// 途中がディレクトリでない (`ENOTDIR`) 場所には、何も在り得ない。無いと数えて次へ進む。
    @Test("途中が普通のファイルの場所は、無いと数えて次の候補へ進む")
    func aFileInTheMiddleIsAbsent() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        let plain = scratch.folder.appendingPathComponent("assets")
        try Data("x".utf8).write(to: plain)
        let beyond = plain.appendingPathComponent("data.csv")
        #expect(AssetLookup.presence(of: beyond) == .absent)

        let real = scratch.folder.appendingPathComponent("real.csv")
        try Data("a".utf8).write(to: real)
        #expect(try AssetLookup.locate([beyond, real], path: "data.csv") == real)
    }

    @Test("先の候補が無くて後の候補が在れば、後を採る")
    func laterCandidateIsTakenWhenEarlierOnesAreAbsent() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        let real = scratch.folder.appendingPathComponent("real.csv")
        try Data("a".utf8).write(to: real)
        let missing = scratch.folder.appendingPathComponent("missing.csv")
        #expect(try AssetLookup.locate([missing, real], path: "real.csv") == real)
    }

    /// 入れない場所は在るかもしれない場所。後ろの候補に本物があっても、黙って採らずそこで止める。
    @Test("入れない候補に当たったら、後ろに本物があっても止めて名乗る")
    func stopsAtAnUnreachableCandidate() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: nil)
        let real = scratch.folder.appendingPathComponent("real.csv")
        try Data("a".utf8).write(to: real)
        let blocked = scratch.assets.appendingPathComponent("real.csv")
        #expect(throws: AssetFailure.unreachable(
            path: "real.csv", location: blocked.standardizedFileURL.path, reason: Self.denied)
        ) {
            try AssetLookup.locate([blocked, real], path: "real.csv")
        }
    }

    /// 宛先の無い symlink は、名前は在るので「無い」とは言わない (CLI の `Presence` と同じ)。
    @Test("宛先の無い symlink は、無いと言わず、辿り着けないと言う")
    func aDanglingSymlinkIsNotAbsent() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        let link = scratch.folder.appendingPathComponent("photo.png")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: scratch.folder.path + "/gone.png")
        guard case .unreachable(let reason) = AssetLookup.presence(of: link) else {
            Issue.record("宛先の無い symlink を辿り着けないと読んでいない")
            return
        }
        #expect(reason.contains("symbolic link"), "\(reason)")
    }

    /// 途中の段にある宛先の無い symlink (`assets` が外したドライブへの symlink など) は、最後の段の `stat` も
    /// `lstat` も `ENOENT` になる。そのまま「無い」と数えると、置いたはずのファイルを探させる助言が出る。
    @Test("途中の段の宛先の無い symlink は、無いと言わず、辿り着けないと言う")
    func aDanglingSymlinkInTheMiddleIsNotAbsent() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: scratch.assets.path, withDestinationPath: "/nonexistent-volume-\(UUID().uuidString)")
        let candidate = scratch.assets.appendingPathComponent("data.csv")
        guard case .unreachable(let reason) = AssetLookup.presence(of: candidate) else {
            Issue.record("途中の宛先の無い symlink を辿り着けないと読んでいない")
            return
        }
        #expect(reason.contains("symbolic link") && reason.contains(scratch.assets.path), "\(reason)")
        do {
            _ = try Bare().assetURL(candidate.path)
            Issue.record("解けてしまった")
        } catch {
            guard case .unreachable(_, let location, _) = error else {
                Issue.record("unreachable で断っていない: \(error)")
                return
            }
            #expect(location == candidate.standardizedFileURL.path)
            Self.expectNoMisleadingAdvice(error.description)
        }
    }

    /// 包みの置き場を数えられない (読む権利が無い) と、そこに在る包みの候補が丸ごと落ちる。落ちたまま
    /// 「見つからない」と言わない — どこにも無かったときに、数えられなかった置き場を名乗る。
    @Test("包みの置き場を数えられないとき、どこにも無ければ名乗り、先に在れば採る")
    func anUnlistableBundleRootIsNamedWhenNothingIsFound() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let neighbourhood = scratch.folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: neighbourhood, withIntermediateDirectories: true)
        let work = scratch.folder.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // 入れるが数えられない (x だけ)
        try FileManager.default.setAttributes([.posixPermissions: 0o311], ofItemAtPath: neighbourhood.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: neighbourhood.path) }
        try #require(
            (try? FileManager.default.contentsOfDirectory(atPath: neighbourhood.path)) == nil,
            "数えられない置き場を作れていない")

        let search = ImageFile.search(
            for: "data.csv", workingDirectory: work.path, neighbourhood: neighbourhood, resources: nil)
        #expect(search.unlistable.map(\.root) == [neighbourhood])
        #expect(search.unlistable.first?.reason == Self.denied)
        // どこにも無い: 包みの中に在るかもしれないので、無いとは言わない
        do {
            _ = try AssetLookup.locate(search, path: "data.csv")
            Issue.record("解けてしまった")
        } catch {
            guard case .unreachable(_, let location, let reason) = error else {
                Issue.record("unreachable で断っていない: \(error)")
                return
            }
            #expect(location == neighbourhood.standardizedFileURL.path)
            #expect(reason.contains(Self.denied), "\(reason)")
        }
        // 先に在るものは採る
        let real = work.appendingPathComponent("data.csv")
        try Data("a".utf8).write(to: real)
        #expect(try AssetLookup.locate(search, path: "data.csv") == real)
    }

    @Test("包みの置き場が無い (ENOENT) のは、数えられなかったとは言わない")
    func aMissingBundleRootIsNotUnlistable() {
        let search = ImageFile.search(
            for: "data.csv", workingDirectory: "/nonexistent-work",
            neighbourhood: URL(fileURLWithPath: "/nonexistent-bin-\(UUID().uuidString)"), resources: nil)
        #expect(search.unlistable.isEmpty)
    }

    /// 断片の置き場の元を差す判定も、他の口と同じ判定 (`AssetLookup`) を使う。確かめられない束の写しは在るとは数えない。
    @Test("置き場の元を差す判定は、確かめられない候補を在るとは数えない")
    func theOriginInsertionUsesTheSameJudgement() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: "paint.metal")
        let copy = scratch.assets.appendingPathComponent("paint.metal")
        let origin = scratch.folder.appendingPathComponent("origin/assets")
        let before = [scratch.folder.appendingPathComponent("work/assets/paint.metal"), copy]
        let arranged = ShaderOrigin.inserting(origin: origin, for: "assets/paint.metal", into: before)
        #expect(arranged == before, "確かめられない写しを在ると数えて、置き場の元を差している")
    }

    // MARK: - 口 (絶対の名前で、候補は 1 つ)

    @Test("assetURL は、入れない場所と OS の事情を名乗り、資源の宣言の助言を出さない", arguments: [true, false])
    func assetURLNamesTheUnreachablePlace(present: Bool) throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: present ? "notes.txt" : nil)
        let name = scratch.assets.appendingPathComponent("notes.txt").path
        do {
            _ = try Bare().assetURL(name)
            Issue.record("入れない場所の資材が解けてしまった")
        } catch {
            #expect(error == .unreachable(path: name, location: name, reason: Self.denied))
            let text = error.description
            #expect(text.contains(name) && text.contains(Self.denied), "\(text)")
            Self.expectNoMisleadingAdvice(text)
        }
    }

    @Test("文字のファイルを読む口 (dataURL) は、DataFailure.unopenable で名乗る")
    func dataURLNamesTheUnreachablePlace() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: "data.csv")
        let name = scratch.assets.appendingPathComponent("data.csv").path
        do {
            _ = try Bare().dataURL(name)
            Issue.record("入れない場所の資材が解けてしまった")
        } catch {
            guard case .unopenable(let path, let location, let reason) = error else {
                Issue.record("unopenable で断っていない: \(error)")
                return
            }
            #expect(path == name && location == name)
            #expect(reason == AssetOpening.unreachableReason(Self.denied))
            #expect(error.description.contains(Self.denied), "\(error)")
            Self.expectNoMisleadingAdvice(error.description)
        }
    }

    @Test("画像の探し方 (ImageFile.locate) は、ImageFailure.unopenable で名乗る")
    func imageLocateNamesTheUnreachablePlace() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: "photo.png")
        let name = scratch.assets.appendingPathComponent("photo.png").path
        do {
            _ = try ImageFile.locate(name)
            Issue.record("入れない場所の資材が解けてしまった")
        } catch {
            #expect(
                error == .unopenable(
                    path: name, location: name, reason: AssetOpening.unreachableReason(Self.denied)))
            Self.expectNoMisleadingAdvice(error.description)
        }
    }

    @Test("モデルの探し方 (ModelFile.load) は、ModelFailure.unopenable で名乗る")
    func modelLoadNamesTheUnreachablePlace() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: "ship.obj")
        let name = scratch.assets.appendingPathComponent("ship.obj").path
        do {
            _ = try ModelFile.load(name)
            Issue.record("入れない場所の資材が解けてしまった")
        } catch {
            #expect(
                error == .unopenable(
                    path: name, location: name, reason: AssetOpening.unreachableReason(Self.denied)))
            Self.expectNoMisleadingAdvice(error.description)
        }
    }

    @Test("断片の探し方 (ShaderSource.read) は、ShaderFailure.unopenable で名乗る")
    func shaderReadNamesTheUnreachablePlace() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try scratch.lock(placing: "fx.metal")
        let name = scratch.assets.appendingPathComponent("fx.metal").path
        do {
            _ = try ShaderSource.read(at: name, origin: nil)
            Issue.record("入れない場所の資材が解けてしまった")
        } catch {
            #expect(
                error == .unopenable(
                    path: name, location: name, reason: AssetOpening.unreachableReason(Self.denied)))
            Self.expectNoMisleadingAdvice(error.description)
        }
    }

    /// 同じ置き方が、4 か所で同じ結果になる。写しが割れると、口によって「無い」と「入れない」が分かれる。
    @Test("探す口 4 か所は、同じ置き方に同じ判定を返す", arguments: [true, false])
    func fourPlacesAgree(unreachable: Bool) throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        if unreachable { try scratch.lock(placing: "x.metal") }
        let name = scratch.assets.appendingPathComponent("x.metal").path

        var kinds: [String] = []
        func kind(_ unreachable: Bool, _ notFound: Bool) -> String {
            unreachable ? "unreachable" : notFound ? "notFound" : "found"
        }
        do { _ = try Bare().assetURL(name); kinds.append("found") } catch {
            kinds.append(kind(
                { if case .unreachable = error { true } else { false } }(),
                { if case .notFound = error { true } else { false } }()))
        }
        do { _ = try ImageFile.locate(name); kinds.append("found") } catch {
            kinds.append(kind(
                { if case .unopenable = error { true } else { false } }(),
                { if case .notFound = error { true } else { false } }()))
        }
        do { _ = try ModelFile.load(name.replacingOccurrences(of: ".metal", with: ".obj")); kinds.append("found") } catch {
            kinds.append(kind(
                { if case .unopenable = error { true } else { false } }(),
                { if case .notFound = error { true } else { false } }()))
        }
        do { _ = try ShaderSource.read(at: name, origin: nil); kinds.append("found") } catch {
            kinds.append(kind(
                { if case .unopenable = error { true } else { false } }(),
                { if case .notFound = error { true } else { false } }()))
        }
        let expected = unreachable ? "unreachable" : "notFound"
        #expect(kinds == Array(repeating: expected, count: 4), "\(kinds)")
    }

    @Test("無い資材は、どの口でも notFound のまま (入れない場所ではない)")
    func missingStaysNotFoundEverywhere() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        let name = scratch.folder.appendingPathComponent("none.metal").path
        #expect(throws: AssetFailure.notFound(path: name, searched: [name])) { try Bare().assetURL(name) }
        do { _ = try ShaderSource.read(at: name, origin: nil) } catch {
            #expect(error == .notFound(path: name, searched: [name]))
        }
    }

    // MARK: - 文面

    /// `unopenable` の文面は、在るかを確かめられない場合に「見つかった」と言わない。開こうとして断られた
    /// 場合は、今までどおり「見つかった」と言う。
    @Test("unopenable の文面は、辿り着けない場合にだけ「見つかった」と言わない")
    func noticeSaysFoundOnlyWhenItWasFound() {
        let found = AssetOpening.notice(path: "a/b.png", location: "/x/a/b.png", reason: "Is a directory")
        #expect(found.contains("was found"), "\(found)")
        let reached = AssetOpening.notice(
            path: "a/b.png", location: "/x/a/b.png", reason: AssetOpening.unreachableReason("Permission denied"))
        #expect(!reached.contains("was found"), "\(reached)")
        #expect(reached.contains("\"/x/a/b.png\"") && reached.contains("Permission denied"), "\(reached)")
        let same = AssetOpening.notice(
            path: "/x/b.png", location: "/x/b.png", reason: AssetOpening.unreachableReason("Permission denied"))
        #expect(same.hasPrefix("\"/x/b.png\" cannot be reached:"), "\(same)")
    }
}
