// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 名前が在るものに解けたのに開けないファイルを、画像・モデル・断片の読み手がどう断るか ([#2358])。
///
/// **開けない事情を、中身の形式・破損・資源宣言の問題と名乗らない。** ディレクトリや読む権利の
/// 無いファイルを「画像として読めない (形式を確かめよ)」「壊れていないか確かめよ」「見つからない
/// (資源の宣言を確かめよ)」で断ると、利用者は的外れな所を直しに行く。文字のファイル
/// (``DataFailure/unopenable(path:location:reason:)``・#2341) と同じ形の `unopenable` で、解けた
/// 場所と OS が名乗った事情を添えて断る。置き方は ``UnopenableFileTests/Scratch`` を共有する。
///
/// 音と動画の読み手は別の検査の束 (`MokumeAudioTests`・`MokumeCameraTests`) が同じことを見る。
///
/// [#2358]: https://github.com/mokume-metal/mokume/issues/2358
@Suite("見つかったが開けない資材")
struct UnopenableAssetTests {
    typealias Obstacle = UnopenableFileTests.Obstacle
    typealias Scratch = UnopenableFileTests.Scratch

    @Test("assetURL はディレクトリも今までどおり返す (読む口が開けないものとして名乗る)")
    func assetURLStillResolvesDirectories() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let placed = try scratch.place(.directory, as: "photo.png")
        #expect(try UnopenableFileTests.Bare().assetURL(placed).path == placed)
    }

    /// 画像・モデル・断片を読む口。読み手 (``ImageFile/decode(at:name:)``・``ModelFile/load(_:)``・
    /// ``ShaderSource/read(at:)``) を通る口すべてである。
    nonisolated enum Door: CaseIterable, Sendable {
        case loadImage, requestImage
        case loadModelOBJ, loadModelSTL, requestModel
        case loadShader, loadEffect, loadComputation

        /// 開けないものに付ける名前。読み手は拡張子で選ぶので、口が読む形式の拡張子にする。
        var fileName: String {
            switch self {
            case .loadImage, .requestImage: "photo.png"
            case .loadModelOBJ, .requestModel: "ship.obj"
            case .loadModelSTL: "ship.stl"
            case .loadShader, .loadEffect, .loadComputation: "fx.metal"
            }
        }

        /// 口を呼ぶ。読んだ値は捨てる。
        @MainActor
        func read(_ path: String, on canvas: Canvas) async throws {
            switch self {
            case .loadImage: _ = try canvas.loadImage(path)
            case .requestImage: _ = try await canvas.requestImage(path)
            case .loadModelOBJ, .loadModelSTL: _ = try canvas.loadModel(path)
            case .requestModel: _ = try await canvas.requestModel(path)
            case .loadShader: _ = try canvas.loadShader(path)
            case .loadEffect: _ = try canvas.loadEffect(path)
            case .loadComputation: _ = try canvas.loadComputation(path)
            }
        }
    }

    /// 投げた失敗の `unopenable` の中身と、説明の文面。
    struct Outcome {
        var unopenable: (path: String, location: String, reason: String)?
        var text: String
    }

    /// 口を呼んで、投げた失敗を ``Outcome`` にする。投げなければ `nil`。
    @MainActor
    static func outcome(of door: Door, reading path: String, on canvas: Canvas) async -> Outcome? {
        do {
            try await door.read(path, on: canvas)
            return nil
        } catch let failure as ImageFailure {
            guard case .unopenable(let path, let location, let reason) = failure else {
                return Outcome(text: failure.description)
            }
            return Outcome(unopenable: (path, location, reason), text: failure.description)
        } catch let failure as ModelFailure {
            guard case .unopenable(let path, let location, let reason) = failure else {
                return Outcome(text: failure.description)
            }
            return Outcome(unopenable: (path, location, reason), text: failure.description)
        } catch let failure as ShaderFailure {
            guard case .unopenable(let path, let location, let reason) = failure else {
                return Outcome(text: failure.description)
            }
            return Outcome(unopenable: (path, location, reason), text: failure.description)
        } catch {
            return Outcome(text: "\(type(of: error)): \(error)")
        }
    }

    /// 面は GPU が無いと作れない。どの口も面の上で読む。
    @Suite(
        "読み込む面の要る口",
        .enabled(if: RenderDevice.isAvailable, "読み込む面を作るので GPU が要る")
    )
    struct NeedingCanvas {
        /// 開けないものを口に渡すと、`unopenable` で、解けた場所と OS が名乗った事情を添え、
        /// 形式・破損・資源宣言の助言を出さずに断る。同じものを**絶対の名前と相対の名前**の
        /// 両方で渡す — 相対の名前は探して解くので、文面が解けた場所を名乗ることを見る。
        @Test(
            "ディレクトリと読む権利の無いファイルは、unopenable で開けない事情を名乗る",
            arguments: Door.allCases, Obstacle.allCases)
        @MainActor
        func unopenableNamesWhy(_ door: Door, _ obstacle: Obstacle) async throws {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            let scratch = Scratch()
            defer { scratch.cleanUp() }
            let placed = try scratch.place(obstacle, as: door.fileName)
            for name in [placed, Scratch.relativeName(of: placed)] {
                guard let outcome = await outcome(of: door, reading: name, on: canvas) else {
                    Issue.record("\(door) が \(name) (\(obstacle)) を読めてしまった")
                    continue
                }
                guard let unopenable = outcome.unopenable else {
                    Issue.record("\(door) が \(name) (\(obstacle)) を unopenable で断っていない: \(outcome.text)")
                    continue
                }
                #expect(unopenable.path == name)
                // 置いた場所そのもの。名前が相対でも、探して解けた先を `..` を畳んで名乗る
                #expect(unopenable.location == placed)
                #expect(unopenable.reason == obstacle.reason)
                #expect(outcome.text.contains(obstacle.reason), "\(outcome.text)")
                #expect(outcome.text.contains("\"\(placed)\""), "解けた場所を名乗っていない: \(outcome.text)")
                for advice in ["format", "damaged", "resources", "Looked in", "Cannot find"] {
                    #expect(!outcome.text.contains(advice), "開けないことと別の助言を出している: \(outcome.text)")
                }
            }
        }

        /// UTF-8 でない (Shift_JIS の「あ」) 断片。0x82 は UTF-8 の先頭に来ないバイト。
        static let shiftJIS = Data([0x2F, 0x2F, 0x20, 0x82, 0xA0, 0x0A])

        /// 開けたが UTF-8 の文字として読めない断片は、見つからない (資源の宣言を確かめよ) ではなく
        /// `unreadable` で断る。
        @Test(
            "開けたが UTF-8 でない断片は、notFound ではなく unreadable で断る",
            arguments: [Door.loadShader, .loadEffect, .loadComputation])
        @MainActor
        func unreadableFragmentSaysUTF8(_ door: Door) async throws {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            let scratch = Scratch()
            defer { scratch.cleanUp() }
            let placed = try scratch.file(door.fileName, Self.shiftJIS)
            do {
                try await door.read(placed, on: canvas)
                Issue.record("\(door) が UTF-8 でない断片を読めてしまった")
            } catch let failure as ShaderFailure {
                #expect(failure == .unreadable(path: placed))
                #expect(failure.description.contains("UTF-8"), "\(failure)")
                #expect(!failure.description.contains("resources"), "資源の宣言の助言を出している: \(failure)")
            }
        }

        /// 読み直しで読めなくなったもの。
        nonisolated enum Spoil: CaseIterable, Sendable {
            /// ファイルを消して、同じ名前のディレクトリを置く。
            case directory
            /// 読む権利を外す。
            case noPermission
            /// 中身を UTF-8 でないもの (Shift_JIS) にする。
            case notUTF8

            /// 理由に出るはずの句。
            var phrase: String {
                switch self {
                case .directory: String(cString: strerror(EISDIR))
                case .noPermission: String(cString: strerror(EACCES))
                case .notUTF8: "UTF-8"
                }
            }
        }

        /// 保存を拾って読み直す経路 (``ShaderBox``) も、読めなくなった事情を名乗る。場所だけを
        /// 言って、開けないのか UTF-8 でないのかを落とさない。
        @Test("読み直しで読めなくなった断片は、開けない事情か UTF-8 でないことを名乗る", arguments: Spoil.allCases)
        @MainActor
        func reloadNamesWhy(_ spoil: Spoil) throws {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            let scratch = Scratch()
            defer { scratch.cleanUp() }
            let placed = try scratch.file(
                "paint.metal",
                Data("float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }".utf8))
            let shader = try canvas.loadShader(placed)
            try #require(shader.failure == nil, "検査の前提: 読めた断片が失敗を名乗っている")
            switch spoil {
            case .directory:
                try FileManager.default.removeItem(atPath: placed)
                try FileManager.default.createDirectory(atPath: placed, withIntermediateDirectories: false)
            case .noPermission:
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: placed)
                try #require(!FileManager.default.isReadableFile(atPath: placed), "読む権利を外せていない")
            case .notUTF8:
                try Self.shiftJIS.write(to: URL(fileURLWithPath: placed))
            }
            shader.reload()
            let failure = try #require(shader.failure, "読めなくなったのに失敗を名乗らない")
            #expect(failure.contains(spoil.phrase), "\(failure)")
            #expect(failure.contains(placed), "場所を名乗っていない: \(failure)")
        }
    }
}
