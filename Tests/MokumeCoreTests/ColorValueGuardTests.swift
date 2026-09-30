// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 色の値 (`LinearRGBA`) をそのまま受ける口が、数でない値・無限の成分を断る ([#1706])。
///
/// **同じ口の数の形と同じ倒し方をする** ([ADR-0020] 決定 5)。状態 (塗り・線・色合い・下地・光・
/// 素材・置き場所) は渡す前のまま残し、数の形と同じ鍵・同じ文面で 1 度だけ言う。
///
/// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
@Suite(
    "色の値の口が、数でない成分を断る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ColorValueGuardTests {
    private static let side = 16

    /// 色の値を受ける口。**口を足したら、ここへ 1 行と、下の 3 つの `switch` に 1 枝ずつ足す。**
    nonisolated enum Port: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case fill = "fill(_:)"
        case fillWithOpacity = "fill(_:_:)"
        case stroke = "stroke(_:)"
        case strokeWithOpacity = "stroke(_:_:)"
        case tint = "tint(_:)"
        case background = "background(_:)"
        case ambientLight = "ambientLight(_:)"
        case directionalLight = "directionalLight(_:_:_:_:)"
        case pointLight = "pointLight(_:_:_:_:)"
        case spotLight = "spotLight(_:…)"
        case ambient = "ambient(_:)"
        case emissive = "emissive(_:)"
        case placement = "shape(_:at:) の Placement.fill"

        var testDescription: String { rawValue }

        /// 不透明度を読まない口か。光と素材は乗算済みの赤・緑・青だけを使う (`Light`・
        /// `Material`) ので、不透明度は検めない ([#1706] の反証 3)。周囲 (`Surroundings`) と同じ。
        ///
        /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
        var ignoresOpacity: Bool {
            switch self {
            case .ambientLight, .directionalLight, .pointLight, .spotLight, .ambient, .emissive: true
            default: false
            }
        }

        /// 断ったときに言う鍵。数の形と同じもの。
        var key: Canvas.Warning {
            switch self {
            case .fill, .fillWithOpacity: .notANumberFill
            case .stroke, .strokeWithOpacity: .notANumberStroke
            case .tint: .notANumberTint
            case .background: .notANumberBackground
            case .ambientLight: .notANumberAmbientLight
            case .directionalLight: .notANumberDirectionalLight
            case .pointLight: .notANumberPointLight
            case .spotLight: .notANumberSpotLight
            case .ambient: .notANumberAmbient
            case .emissive: .notANumberEmissive
            case .placement: .badPlacement
            }
        }
    }

    /// 壊れた成分を 1 つ持つ色。
    nonisolated struct Broken: CustomTestStringConvertible, Sendable {
        let lane: Int
        let value: Float

        var testDescription: String {
            "\(["赤", "緑", "青", "不透明度"][lane]) が \(value)"
        }

        @MainActor var color: LinearRGBA {
            var lanes: [Float] = [0.2, 0.4, 0.6, 1]
            lanes[lane] = value
            return LinearRGBA(
                premultipliedRed: lanes[0], green: lanes[1], blue: lanes[2], alpha: lanes[3])
        }

        static let all: [Broken] = (0..<4).flatMap { lane in
            [Float.nan, .infinity, -.infinity].map { Broken(lane: lane, value: $0) }
        }

        /// 断るはずの組。不透明度を読まない口の、不透明度だけが壊れた色は除く。
        static let refused: [(Port, Broken)] = Port.allCases.flatMap { port in
            all.filter { !(port.ignoresOpacity && $0.lane == 3) }.map { (port, $0) }
        }

        /// 不透明度を読まない口へ渡す、不透明度だけが壊れた色。受け取られるはず。
        static let opacityOnly: [(Port, Broken)] = Port.allCases.filter(\.ignoresOpacity)
            .flatMap { port in all.filter { $0.lane == 3 }.map { (port, $0) } }
    }

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.side, height: Self.side)
    }

    /// 前もって置いておく有限の色。
    private let previous = LinearRGBA.linear(red: 0.1, green: 0.3, blue: 0.5)
    /// 有限のまま受け取られるはずの色。
    private let accepted = LinearRGBA.linear(red: 0.7, green: 0.2, blue: 0.9)

    /// 色 `color` を口 `port` へ渡し、口が持つ状態を読む。
    ///
    /// 状態は、渡す前に `previous` を置いた後の値と比べられる形で返す。下地と置き場所は面の
    /// 画素で読む (下地は描き切りまで溜め場にしか居ないため)。
    private func pass(_ color: LinearRGBA, to port: Port, on canvas: Canvas) throws -> [Float] {
        var state: [Float] = []
        let tile = canvas.createShape {
            canvas.noStroke()
            canvas.rect(0, 0, 4, 4)
        }
        try canvas.draw {
            switch port {
            case .fill:
                canvas.fill(previous)
                canvas.fill(color)
                state = components(canvas.style.fill)
            case .fillWithOpacity:
                canvas.fill(previous)
                canvas.fill(color, 255)
                state = components(canvas.style.fill)
            case .stroke:
                canvas.stroke(previous)
                canvas.stroke(color)
                state = components(canvas.style.stroke)
            case .strokeWithOpacity:
                canvas.stroke(previous)
                canvas.stroke(color, 255)
                state = components(canvas.style.stroke)
            case .tint:
                canvas.tint(previous)
                canvas.tint(color)
                state = components(canvas.style.tint)
            case .background:
                // 塗り直しを断ったなら、その前に置いた矩形も溜め場から捨てられない
                canvas.background(previous)
                canvas.noStroke()
                canvas.fill(accepted)
                canvas.rect(0, 0, 4, 4)
                canvas.background(color)
            case .ambientLight:
                canvas.ambientLight(color)
                state = [Float(canvas.activeLights.count)]
            case .directionalLight:
                canvas.directionalLight(color, 0, 0, -1)
                state = [Float(canvas.activeLights.count)]
            case .pointLight:
                canvas.pointLight(color, 0, 0, 10)
                state = [Float(canvas.activeLights.count)]
            case .spotLight:
                canvas.spotLight(color, 0, 0, 10, 0, 0, -1)
                state = [Float(canvas.activeLights.count)]
            case .ambient:
                canvas.ambient(previous)
                canvas.ambient(color)
                let value = canvas.style.material.ambient
                state = [value.x, value.y, value.z]
            case .emissive:
                canvas.emissive(previous)
                canvas.emissive(color)
                let value = canvas.style.material.emissive
                state = [value.x, value.y, value.z]
            case .placement:
                canvas.background(previous)
                canvas.fill(accepted)
                canvas.shape(tile, at: [Placement(x: 8, y: 8, fill: color)])
            }
        }
        switch port {
        case .background:
            let pixels = try canvas.target.readPixels()
            state = components(pixels[2, 2]) + components(pixels[10, 10])
        case .placement:
            state = components(try canvas.target.readPixels()[10, 10])
        default:
            break
        }
        return state
    }

    /// 渡す前の状態 (`previous` を置いた後・光は 0 個)。
    private func stateBefore(_ port: Port) -> [Float] {
        switch port {
        case .fill, .fillWithOpacity, .stroke, .strokeWithOpacity, .tint:
            components(previous)
        case .background:
            // 矩形は残り、その外は前の下地のまま
            components(accepted) + components(previous)
        case .ambientLight, .directionalLight, .pointLight, .spotLight:
            [0]
        case .ambient, .emissive:
            [previous.red, previous.green, previous.blue]
        case .placement:
            components(previous)
        }
    }

    /// 同じ口の数の形 (または同じ事情の別の入口) が言う文面。
    private func numericMessage(for port: Port) throws -> String? {
        let canvas = try makeCanvas()
        let nan = Float.nan
        let tile = canvas.createShape { canvas.rect(0, 0, 4, 4) }
        try canvas.draw {
            switch port {
            case .fill, .fillWithOpacity: canvas.fill(nan, 0, 0)
            case .stroke, .strokeWithOpacity: canvas.stroke(nan, 0, 0)
            case .tint: canvas.tint(nan, 0, 0)
            case .background: canvas.background(nan, 0, 0)
            case .ambientLight: canvas.ambientLight(nan, 0, 0)
            case .directionalLight: canvas.directionalLight(nan, 0, 0, 0, 0, -1)
            case .pointLight: canvas.pointLight(nan, 0, 0, 0, 0, 10)
            case .spotLight: canvas.spotLight(nan, 0, 0, 0, 0, 10, 0, 0, -1)
            case .ambient: canvas.ambient(nan, 0, 0)
            case .emissive: canvas.emissive(nan, 0, 0)
            case .placement: canvas.shape(tile, at: [Placement(x: nan)])
            }
        }
        return canvas.warnings.message(for: port.key)
    }

    /// 完了条件 1・2。
    ///
    /// 置き場所 (`Placement.fill`) には数の形が無い。置き場所の数が数でないときと同じ鍵で言い、
    /// 文面は原因の塗りを名指す (下の「置き場所の注意は、原因を名指す」)。
    @Test(
        "数でない成分・無限の成分を持つ色は、状態を変えずに、数の形と同じ鍵と文面で 1 度だけ言う",
        arguments: Broken.refused)
    func refusesNonFiniteComponents(_ port: Port, _ broken: Broken) throws {
        let canvas = try makeCanvas()
        let state = try pass(broken.color, to: port, on: canvas)
        let context = "\(port.rawValue) に \(broken.testDescription)"

        #expect(sameState(state, stateBefore(port)), "\(context): 状態が \(state) になった")
        let message = canvas.warnings.message(for: port.key)
        #expect(message != nil, "\(context): 注意が出ない")
        if port != .placement {
            #expect(message == (try numericMessage(for: port)), "\(context): 数の形と文面が違う")
        }
        // 断ったときに、ほかの鍵で言わない (素材は範囲の外の鍵を持つ)
        #expect(!canvas.warnings.hasWarned(.badMaterial), "\(context): 範囲の外の鍵で言った")
    }

    /// [#1706] の反証 3。光と素材は不透明度を使わないので、不透明度だけが数でない色も受け取る。
    /// 断ると、絵に効かない成分のために光が消える。周囲 (`Surroundings.isUsable`) と同じ扱い。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    @Test("光と素材は、不透明度だけが数でない色を受け取る", arguments: Broken.opacityOnly)
    func lightsAndMaterialsIgnoreTheOpacity(_ port: Port, _ broken: Broken) throws {
        let canvas = try makeCanvas()
        let state = try pass(broken.color, to: port, on: canvas)
        let context = "\(port.rawValue) に \(broken.testDescription)"
        #expect(!sameState(state, stateBefore(port)), "\(context): 受け取らなかった")
        #expect(!canvas.warnings.hasWarned(port.key), "\(context): 注意が出た")
    }

    /// 区間の外の断りと色の断りの順を見る口。
    nonisolated enum Ordered: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case background, ambientLight, directionalLight, pointLight, spotLight, ambient, emissive

        var testDescription: String { rawValue }

        var port: Port {
            switch self {
            case .background: .background
            case .ambientLight: .ambientLight
            case .directionalLight: .directionalLight
            case .pointLight: .pointLight
            case .spotLight: .spotLight
            case .ambient: .ambient
            case .emissive: .emissive
            }
        }

        @MainActor var outside: Canvas.Warning {
            switch self {
            case .background: Canvas.OutsideFrame.placing.warning
            case .ambientLight, .directionalLight, .pointLight, .spotLight:
                Canvas.OutsideFrame.light.warning
            case .ambient, .emissive: Canvas.OutsideFrame.material.warning
            }
        }
    }

    /// [#1706] の反証 2。**区間の外では、数の形も色の値の形も、区間の外の断りだけを言う。**
    /// 置かない呼び出しのために色の鍵を使い切らない — スポットの半頂角の丸め (#1698 の反証 10)・
    /// 置き場所の検め (`shape(_:at:)`) と同じ順である。直す前は、数の形と素材が色を先に断り、
    /// 値の形の光と下地は区間の外を先に断っていた。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    @Test("区間の外では、数の形も色の値の形も、色より先に区間の外を断る", arguments: Ordered.allCases)
    func refusesOutsideTheFrameBeforeTheColour(_ ordered: Ordered) throws {
        let nan = Float.nan
        let broken = LinearRGBA(premultipliedRed: nan, green: 0, blue: 0, alpha: 1)
        for numeric in [true, false] {
            let canvas = try makeCanvas()
            let form = numeric ? "数の形" : "色の値の形"
            switch ordered {
            case .background:
                if numeric { canvas.background(nan, 0, 0) } else { canvas.background(broken) }
            case .ambientLight:
                if numeric { canvas.ambientLight(nan, 0, 0) } else { canvas.ambientLight(broken) }
            case .directionalLight:
                if numeric {
                    canvas.directionalLight(nan, 0, 0, 0, 0, -1)
                } else {
                    canvas.directionalLight(broken, 0, 0, -1)
                }
            case .pointLight:
                if numeric {
                    canvas.pointLight(nan, 0, 0, 0, 0, 10)
                } else {
                    canvas.pointLight(broken, 0, 0, 10)
                }
            case .spotLight:
                if numeric {
                    canvas.spotLight(nan, 0, 0, 0, 0, 10, 0, 0, -1)
                } else {
                    canvas.spotLight(broken, 0, 0, 10, 0, 0, -1)
                }
            case .ambient:
                if numeric { canvas.ambient(nan, 0, 0) } else { canvas.ambient(broken) }
            case .emissive:
                if numeric { canvas.emissive(nan, 0, 0) } else { canvas.emissive(broken) }
            }
            #expect(canvas.warnings.hasWarned(ordered.outside), "\(ordered) の\(form): 区間の外を言わない")
            #expect(!canvas.warnings.hasWarned(ordered.port.key), "\(ordered) の\(form): 色を先に断った")
        }
    }

    /// 素材の範囲の外 (負の成分・範囲の外の量) も、区間の外より後に断る (反証 2 の兄弟)。
    @Test("区間の外では、素材の範囲の外より先に区間の外を断る")
    func refusesOutsideTheFrameBeforeTheMaterialRange() throws {
        let canvas = try makeCanvas()
        canvas.ambient(.linear(red: -1, green: 0, blue: 0))
        canvas.emissive(.linear(red: -1, green: 0, blue: 0))
        canvas.shininess(-1)
        canvas.metalness(2)
        #expect(canvas.warnings.hasWarned(Canvas.OutsideFrame.material.warning))
        #expect(!canvas.warnings.hasWarned(.badMaterial))
    }

    /// [#1706] の反証 4。**有限の大きな値は断らない。** 0–255 の目盛りで 3.05e18 を越える灰色は、
    /// 伝達関数の 2.4 乗が `Float` の最大を越える。#1691 がそこを `Float` の最大で止めたので、
    /// 色は有限のまま作られ、受け口は「数でない値か無限が渡された」とは言わない。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    @Test(
        "数の形に有限の大きな値を渡しても断らず、有限の色として受け取る",
        arguments: [Float(4e18), .greatestFiniteMagnitude])
    func acceptsHugeFiniteValues(_ huge: Float) throws {
        let canvas = try makeCanvas()
        var fills: [LinearRGBA] = []
        var lights: [SIMD4<Float>] = []
        try canvas.draw {
            canvas.fill(huge, huge, huge)
            fills.append(canvas.style.fill)
            canvas.fill(huge, 0, 0)
            fills.append(canvas.style.fill)
            canvas.stroke(huge)
            fills.append(canvas.style.stroke)
            canvas.tint(huge, huge, huge)
            fills.append(canvas.style.tint)
            canvas.pointLight(huge, huge, huge, 0, 0, 10)
            canvas.ambientLight(0, huge, 0)
            lights = canvas.activeLights.map(\.colorAndKind)
            canvas.ambient(huge, huge, huge)
            let ambient = canvas.style.material.ambient
            fills.append(.linear(red: ambient.x, green: ambient.y, blue: ambient.z))
            canvas.background(huge)
        }
        for color in fills { #expect(color.isFinite, "\(color)") }
        #expect(lights.count == 2, "光が置かれなかった")
        for light in lights {
            #expect(light.x.isFinite && light.y.isFinite && light.z.isFinite, "光の色 \(light)")
        }
        #expect(
            try canvas.target.readPixels()[8, 8].isFinite, "下地が有限でない")
        for key in Port.allCases.map(\.key) where key != .badPlacement {
            #expect(!canvas.warnings.hasWarned(key), "\(key) で断った")
        }
    }

    /// [#1706] の反証 7。置き場所の注意は、原因が塗りなら塗りを、置き場所の数なら位置を名指す。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    @Test("置き場所の注意は、原因を名指す")
    func placementNoticeNamesTheCause() throws {
        func message(_ placement: Placement) throws -> String {
            let canvas = try makeCanvas()
            let tile = canvas.createShape { canvas.rect(0, 0, 4, 4) }
            try canvas.draw { canvas.shape(tile, at: [placement]) }
            return try #require(canvas.warnings.message(for: .badPlacement))
        }
        let broken = LinearRGBA(premultipliedRed: .nan, green: 0, blue: 0, alpha: 1)
        let fill = try message(Placement(x: 8, y: 8, fill: broken))
        #expect(fill.contains("fill"), "\(fill)")
        #expect(!fill.contains("position"), "\(fill)")
        let position = try message(Placement(x: .nan))
        #expect(position.contains("position"), "\(position)")
        #expect(!position.contains("fill"), "\(position)")
    }

    /// 完了条件 3。有限の色は今までどおり受け取り、何も言わない。
    @Test("有限の色は今までどおり受け取る", arguments: Port.allCases)
    func acceptsFiniteColors(_ port: Port) throws {
        let canvas = try makeCanvas()
        let state = try pass(accepted, to: port, on: canvas)
        #expect(!sameState(state, stateBefore(port)), "\(port.rawValue): 有限の色を受け取らなかった")
        #expect(!canvas.warnings.hasWarned(port.key), "\(port.rawValue): 有限の色で注意が出た")
    }

    private func components(_ color: LinearRGBA) -> [Float] {
        [color.red, color.green, color.blue, color.alpha]
    }

    /// 同じ状態か。**数でない値が混じったら同じとみなさない。**
    ///
    /// 面の画素は、半精度の隣り合う目盛りまでを同じとみなす。GPU が面へ書くときの丸めは
    /// 最寄りとは限らない (#911 — 0.7 は最寄りの 0.7002 ではなく 0.6997 として書かれた)。
    private func sameState(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count
            && zip(a, b).allSatisfy { x, y in
                guard x.isFinite, y.isFinite else { return false }
                let half = Float16(y)
                return [y, Float(half), Float(half.nextUp), Float(half.nextDown)].contains(x)
            }
    }
}
