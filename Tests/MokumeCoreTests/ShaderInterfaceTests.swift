// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing
import simd

@testable import MokumeCore

/// Swift と Metal が手で揃えている取り決め — 構造体の並びと、束ね先の番号 — を、
/// **Metal 自身の反射**と突き合わせる ([#735])。
///
/// ## なぜ要るか
///
/// どちらがずれても例外は出ない。GPU は伸びた間隔で読み、CPU は元の間隔で書くので、
/// **絵が乱れるか、黙って違う値を読む**だけになる。台帳が絵の変化を捕まえても原因は
/// 言わず、台帳のどのシーンも通らない欄 (spot の光の向き) もある。
///
/// 以前は Swift 側に大きさの定数 (`expectedStride`) を持ち、`MemoryLayout` と突き合わせて
/// いた。それは **Swift の宣言と Swift の定数の突き合わせ**なので、Metal 側にだけ欄を
/// 足しても、同じ大きさの欄を入れ替えても緑のままだった。ここはそれを置き換えた。
///
/// ## 何を見るか
///
/// ライブラリは**本番と同じ口で組む** (`gpu.shaders`)。入口の関数ごとに
/// `MTLLibrary.reflection(functionName:)` を読み、次を比べる:
///
/// - **構造体の並び** — 欄の名前・オフセット・型と、全体の大きさ。Swift 側は
///   `MemoryLayout` の `offset(of:)` と `stride` から出すので、手で書いた数は無い。
///   表に書いた欄の名前は、Swift の型の格納プロパティ (`Mirror`) とも順に突き合わせる
/// - **束ね先の番号** — 入口が宣言する buffer / texture / sampler の**すべて**が、Swift 側の
///   番号の定数と名前で対応し、番号が一致すること。対応の無い口がどちらかにあれば赤
/// - **束ねる数** — 引数のテーブルの上限が、宣言された番号をすべて収めること
/// - **function constant の番号**と、計算の値の口 (`MOKUME_VALUES`)
///
/// ## 見ないもの
///
/// - **定数の値の意味** — 種別の番号は `KindLayoutTests` が、GPU 自身に書き出させて見る。
///   反射には値が現れない
/// - **利用者の値 (`Values`) の詰め方** — Swift が原稿を生成する側で、鏡の構造体ではない
///   (番号だけを見る)
/// - **組み込みの計算 (粒) の束ね先** — 番号は `compute(_:over:reads:writes:)` に渡す並びで
///   決まり、名前の付いた定数が無い。並びを入れ替えると `ParticleTests` が赤くなる
///   (#735 で測った)。ここが見るのは、粒の組み立てに入る `SolidInstance` の写しの並びだけ
/// - **GPU の無い機械**。そこでは suite ごと飛ぶ。`Sources/MokumeCore/` に触る PR は手元の
///   `make ci-check` (`local-render`) を通らないと merge できないので、触った PR では走る
///
/// [#735]: https://github.com/mokume-metal/mokume/issues/735
@Suite(
    "Swift と Metal の取り決め (構造体の並び・束ね先の番号)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ShaderInterfaceTests {
    // MARK: - 図形

    @Test("図形の入口が、Swift 側と同じ番号・同じ並びで受け取る")
    func shapesAgreeWithSwift() throws {
        let shaders = try RenderDevice().shaders
        let library = try shaders.makeShapeLibrary(
            named: "Shapes", body: shaders.bundledShaderSource(named: "Shapes"))

        check(
            library, entries: Self.shapeEntries(surfaces: false),
            limits: [
                .buffer: ShapePipeline.bufferBindCount,
                .texture: ShapePipeline.textureBindCount,
            ])
    }

    @Test("面を宣言した断片は、面の口を上限の数だけ、Swift 側と同じ番号で受け取る")
    func surfacesAgreeWithSwift() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let canvas = try Canvas(target: target, gpu: gpu)
        // 面の宣言の原稿を組むのに要るのは名前だけで、中身は読まない
        let image = try canvas.createImage(1, 1)
        let library = try gpu.shaders.makeShapeLibrary(
            named: "surfaces",
            body: """
                float4 paint(Fragment in, Values values, Surfaces surfaces) {
                    return mokume_sample(surfaces.probe, in.place);
                }
                """,
            surfaces: ["probe": .image(image)])

        check(
            library, entries: Self.shapeFragmentEntries(surfaces: true),
            limits: [
                .buffer: ShapePipeline.bufferBindCount,
                .texture: ShapePipeline.textureBindCount,
            ])
    }

    @Test("基本図形の特化の番号が、Swift 側と一致する")
    func formConstantsAgreeWithSwift() throws {
        let shaders = try RenderDevice().shaders
        let library = try shaders.makeShapeLibrary(
            named: "Shapes", body: shaders.bundledShaderSource(named: "Shapes"))

        var constants: [String: Int] = [:]
        for name in library.functionNames {
            for (key, constant) in library.makeFunction(name: name)?.functionConstantsDictionary
                ?? [:]
            {
                constants[key] = constant.index
            }
        }
        #expect(
            constants == [
                "kFormHasFill": ShapePipeline.formHasFillConstantIndex,
                "kFormHasStroke": ShapePipeline.formHasStrokeConstantIndex,
            ])
    }

    // MARK: - 効果・表示・出口・計算

    @Test("効果の入口が、Swift 側と同じ番号で受け取る")
    func effectsAgreeWithSwift() throws {
        let shaders = try RenderDevice().shaders
        let library = try shaders.makeEffectLibrary(
            named: "builtin", body: shaders.bundledShaderSource(named: "Builtin"))

        check(
            library,
            entries: [
                Entry(EffectPipeline.vertexFunctionName, []),
                Entry(
                    EffectPipeline.fragmentFunctionName,
                    [
                        .buffer("values", EffectPipeline.valuesBufferIndex, .indexOnly),
                        .buffer(
                            "control", EffectPipeline.controlBufferIndex,
                            .scalar(SIMD4<Float>.self)),
                        .buffer(
                            "frame", EffectPipeline.frameBufferIndex, .scalar(SIMD4<Float>.self)),
                        .texture("source", EffectPipeline.sourceTextureIndex),
                        .texture("paired", EffectPipeline.pairedTextureIndex),
                    ]),
            ],
            limits: [
                .buffer: EffectPipeline.bufferBindCount,
                .texture: EffectPipeline.textureBindCount,
            ])
    }

    @Test("画面へ差し出す入口と取り出す入口が、それぞれの Swift 側と同じ番号・並びで受け取る")
    func presentAndOutputAgreeWithSwift() throws {
        let library = try RenderDevice().shaders.makeLibrary(named: "Present")
        #expect(
            Set(library.functionNames)
                == ["presentVertexMain", "presentFragmentMain", "presentEncodeFragmentMain"],
            "表の入口とライブラリの入口が食い違う")
        let brightness = Self.layout(
            of: PackedBrightness.self,
            [
                ("exposure", \.exposure), ("knee", \.knee), ("toneMapping", \.toneMapping),
            ])

        // 2 本の断片は別のパイプライン (別の引数のテーブル) に載るので、上限も別に見る
        check(
            library,
            entries: [
                Entry("presentVertexMain", []),
                Entry(
                    "presentFragmentMain",
                    [
                        .texture("source", PresentPipeline.sourceTextureIndex),
                        .sampler("linearSampler", PresentPipeline.samplerIndex),
                        .buffer(
                            "brightness", PresentPipeline.brightnessBufferIndex,
                            .layout(brightness)),
                    ]),
            ],
            covering: ["presentVertexMain", "presentFragmentMain"],
            limits: [
                .buffer: PresentPipeline.bufferBindCount,
                .texture: PresentPipeline.textureBindCount,
                .sampler: PresentPipeline.samplerBindCount,
            ])
        check(
            library,
            entries: [
                Entry(
                    "presentEncodeFragmentMain",
                    [
                        .texture("source", OutputPass.sourceTextureIndex),
                        .buffer(
                            "brightness", OutputPass.brightnessBufferIndex, .layout(brightness)),
                    ])
            ],
            covering: ["presentEncodeFragmentMain"],
            limits: [
                .buffer: OutputPass.bufferBindCount,
                .texture: OutputPass.textureBindCount,
            ])
    }

    @Test("計算の値の口 (MOKUME_VALUES) が、Swift 側と同じ番号である")
    func computeValuesAgreeWithSwift() throws {
        let library = try RenderDevice().shaders.makeComputeLibrary(
            named: "probe",
            body: """
                kernel void mokume_valuesProbe(
                    constant Values &values [[buffer(MOKUME_VALUES)]],
                    uint id [[thread_position_in_grid]])
                {
                    (void)values;
                }
                """)

        check(
            library,
            entries: [
                Entry(
                    "mokume_valuesProbe",
                    [.buffer("values", ComputePipeline.valuesBufferIndex, .indexOnly)])
            ],
            covering: ["mokume_valuesProbe"],
            limits: [.buffer: ComputePipeline.valuesBufferIndex + 1])
    }

    @Test("粒の組み立てにある置き場所の写しも、Swift 側と同じ並びである")
    func particlePlacesAgreeWithSwift() throws {
        let shaders = try RenderDevice().shaders
        let library = try shaders.makeComputeLibrary(
            named: Canvas.particleShaderName,
            body: shaders.bundledShaderSource(named: Canvas.particleShaderName))

        let instances = try #require(
            buffer(named: "instances", in: Canvas.particleKernelName, of: library))
        compare(instances, with: .layout(Self.solidInstance), at: Canvas.particleKernelName)
    }

    // MARK: - 表

    /// 図形のライブラリの入口すべて。
    static func shapeEntries(surfaces: Bool) -> [Entry] {
        [
            Entry(
                ShapePipeline.flatVertexFunctionName,
                [
                    .buffer(
                        "vertices", ShapePipeline.vertexBufferIndex, .layout(Self.shapeVertex)),
                    .buffer("frame", ShapePipeline.projectionBufferIndex, .layout(Self.flatFrame)),
                    .buffer(
                        "instances", ShapePipeline.instanceBufferIndex,
                        .layout(Self.flatInstance)),
                ]),
            Entry(
                ShapePipeline.solidVertexFunctionName,
                [
                    .buffer(
                        "vertices", ShapePipeline.vertexBufferIndex, .layout(Self.solidVertex)),
                    // 立体は区画の**先頭の行列だけ**を読む (`FlatFrame` の先頭と同じ位置)
                    .buffer(
                        "viewProjection", ShapePipeline.projectionBufferIndex,
                        .scalar(simd_float4x4.self)),
                    .buffer(
                        "instances", ShapePipeline.instanceBufferIndex,
                        .layout(Self.solidInstance)),
                ]),
            Entry(
                ShapePipeline.formVertexFunctionName,
                [
                    .buffer("frame", ShapePipeline.projectionBufferIndex, .layout(Self.flatFrame)),
                    .buffer(
                        "instances", ShapePipeline.instanceBufferIndex,
                        .layout(Self.formInstance)),
                ]),
            Entry(
                ShapePipeline.formFragmentFunctionName,
                [
                    .buffer("mode", ShapePipeline.blendModeBufferIndex, .scalar(UInt32.self)),
                    .buffer(
                        "instances", ShapePipeline.instanceBufferIndex,
                        .layout(Self.formInstance)),
                ]),
            Entry(
                ShapePipeline.formBlendFragmentFunctionName,
                [
                    .buffer(
                        "instances", ShapePipeline.instanceBufferIndex,
                        .layout(Self.formInstance))
                ]),
            Entry(
                ShapePipeline.formReplaceFragmentFunctionName,
                [
                    .buffer(
                        "instances", ShapePipeline.instanceBufferIndex,
                        .layout(Self.formInstance))
                ]),
        ] + shapeFragmentEntries(surfaces: surfaces)
    }

    /// 三角形の経路の断片 2 本。**利用者の断片のライブラリにも入る**入口である。
    static func shapeFragmentEntries(surfaces: Bool) -> [Entry] {
        var common: [Port] = [
            .buffer("uniforms", ShapePipeline.uniformsBufferIndex, .layout(Self.uniforms)),
            .buffer("values", ShapePipeline.valuesBufferIndex, .indexOnly),
            .buffer("lighting", ShapePipeline.lightingBufferIndex, .layout(Self.lighting)),
            .buffer("lights", ShapePipeline.lightsBufferIndex, .layout(Self.light)),
            .buffer("material", ShapePipeline.materialBufferIndex, .layout(Self.material)),
            .buffer(
                "surroundings", ShapePipeline.surroundingsBufferIndex, .layout(Self.surroundings)),
            .buffer("numbers", ShapePipeline.numbersBufferIndex, .scalar(Float.self)),
            .texture("source_texture", ShapePipeline.textureIndex),
            .texture("shadow_texture", ShapePipeline.shadowTextureIndex),
        ]
        if surfaces {
            // 口の数は宣言した枚数によらず上限ぶん。**数が食い違えば名前の集合が食い違う**
            common += (0..<ShapePipeline.surfaceCapacity).map {
                .texture("user_surface_\($0)", ShapePipeline.surfaceTextureIndex + $0)
            }
        }
        return [
            Entry(
                ShapePipeline.flatFragmentFunctionName,
                common + [
                    .buffer("mode", ShapePipeline.blendModeBufferIndex, .scalar(UInt32.self))
                ]),
            Entry(ShapePipeline.flatDirectFragmentFunctionName, common),
        ]
    }

    // MARK: - Swift 側の並び

    static let shapeVertex = layout(
        of: ShapeVertex.self,
        [("position", \.position), ("uv", \.uv), ("color", \.color)])

    static let solidVertex = layout(
        of: SolidVertex.self,
        [
            ("position", \.position), ("shapePosition", \.shapePosition), ("normal", \.normal),
            ("shapeNormal", \.shapeNormal), ("uv", \.uv), ("color", \.color),
        ])

    static let flatFrame = layout(
        of: FlatFrame.self, [("projection", \.projection), ("strokeStart", \.strokeStart)])

    static let flatInstance = layout(
        of: FlatInstance.self,
        [("linear", \.linear), ("offset", \.offset), ("fill", \.fill), ("stroke", \.stroke)])

    static let formInstance = layout(
        of: FormInstance.self,
        [
            ("linear", \.linear), ("offset", \.offset), ("size", \.size), ("fill", \.fill),
            ("stroke", \.stroke), ("meta", \.meta),
        ])

    static let solidInstance = layout(
        of: SolidInstance.self,
        [
            ("matrix", \.matrix), ("normal0", \.normal0), ("normal1", \.normal1),
            ("normal2", \.normal2), ("color", \.color),
        ])

    static let uniforms = layout(
        of: Uniforms.self,
        [
            ("time", \.time), ("resolution", \.resolution), ("shadowBias", \.shadowBias),
            ("shadowMatrix", \.shadowMatrix), ("shadowParams", \.shadowParams),
            ("noiseSeed", \.noiseSeed), ("noiseOctaves", \.noiseOctaves),
            ("noiseFalloff", \.noiseFalloff), ("noisePadding", \.noisePadding),
        ])

    static let lighting = layout(
        of: Lighting.self,
        [("offset", \.offset), ("count", \.count), ("padding", \.padding), ("viewer", \.viewer)])

    static let light = layout(
        of: Light.self,
        [
            ("colorAndKind", \.colorAndKind), ("position", \.position),
            ("directionAndCone", \.directionAndCone),
        ])

    static let material = layout(
        of: PackedMaterial.self,
        [
            ("ambientAndShininess", \.ambientAndShininess),
            ("emissiveAndMetalness", \.emissiveAndMetalness), ("flags", \.flags),
        ])

    static let surroundings = layout(
        of: PackedSurroundings.self,
        [
            ("topAndPresence", \.topAndPresence), ("horizonAndBackdrop", \.horizonAndBackdrop),
            ("bottom", \.bottom),
        ])

    // MARK: - 突き合わせ

    /// 1 つの欄。Metal の反射と同じ形に揃えて比べる。
    struct Field: Equatable, CustomStringConvertible {
        let name: String
        let offset: Int
        let type: MTLDataType

        var description: String { "\(name)@\(offset) (型 \(type.rawValue))" }
    }

    /// Swift の型の並び。
    struct Layout {
        let typeName: String
        let size: Int
        let fields: [Field]
        /// その型の格納プロパティの名前 (宣言の順)。表の書き漏れを見るために持つ。
        let storedNames: [String]
    }

    /// 口が受け取るものの期待。
    enum Expectation {
        /// 鏡の構造体。欄と大きさを比べる。
        case layout(Layout)
        /// 構造体でない値 (数・行列)。型を比べる。
        case scalar(Any.Type)
        /// 番号だけを見る。面と読み取り方の口、利用者の宣言から原稿を生成する `Values`。
        case indexOnly
    }

    struct Port {
        let name: String
        let kind: MTLBindingType
        let index: Int
        let expectation: Expectation

        static func buffer(_ name: String, _ index: Int, _ expectation: Expectation) -> Port {
            Port(name: name, kind: .buffer, index: index, expectation: expectation)
        }
        static func texture(_ name: String, _ index: Int) -> Port {
            Port(name: name, kind: .texture, index: index, expectation: .indexOnly)
        }
        static func sampler(_ name: String, _ index: Int) -> Port {
            Port(name: name, kind: .sampler, index: index, expectation: .indexOnly)
        }
    }

    /// 入口の関数 1 つと、それが受け取る口のすべて。
    struct Entry {
        let function: String
        let ports: [Port]

        init(_ function: String, _ ports: [Port]) {
            self.function = function
            self.ports = ports
        }
    }

    /// 検査だけが呼ぶ入口。束ねる番号は `compute(_:over:reads:writes:)` に渡す並びで決まる
    /// ので、名前の付いた定数と突き合わせる対象が無い。
    static let probeFunctions: Set<String> = ["mokume_kindLayout"]

    /// Swift の型の並びを、`MemoryLayout` から組む。**数は 1 つも手で書かない。**
    static func layout<T>(of type: T.Type, _ fields: [(String, PartialKeyPath<T>)]) -> Layout {
        let storedNames = withUnsafeTemporaryAllocation(
            byteCount: MemoryLayout<T>.stride, alignment: MemoryLayout<T>.alignment
        ) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            let value = raw.baseAddress!.load(as: T.self)
            return Mirror(reflecting: value).children.compactMap(\.label)
        }
        return Layout(
            typeName: "\(T.self)",
            size: MemoryLayout<T>.stride,
            fields: fields.map { name, keyPath in
                Field(
                    name: name,
                    offset: MemoryLayout<T>.offset(of: keyPath) ?? -1,
                    type: dataType(of: Swift.type(of: keyPath).valueType))
            },
            storedNames: storedNames)
    }

    /// Swift の型が、Metal のどの型に当たるか。**表に無い型は `.none`** になり、比べると赤になる。
    static func dataType(of type: Any.Type) -> MTLDataType {
        if type == Float.self { return .float }
        if type == UInt32.self { return .uint }
        if type == SIMD2<Float>.self { return .float2 }
        if type == SIMD3<Float>.self { return .float3 }
        if type == SIMD4<Float>.self { return .float4 }
        if type == SIMD4<UInt32>.self { return .uint4 }
        if type == simd_float4x4.self { return .float4x4 }
        return .none
    }

    /// 入口の関数を反射で読み、表と突き合わせる。
    ///
    /// - Parameters:
    ///   - covering: この表が**すべて**を覆うべき入口の名前。省略するとライブラリの入口すべて
    ///     (検査だけが呼ぶものを除く) — 表に無い入口が Metal に増えたら赤になる。
    ///   - limits: 引数のテーブルの上限。宣言された番号はこれより小さくなければならない。
    func check(
        _ library: any MTLLibrary, entries: [Entry], covering: Set<String>? = nil,
        limits: [MTLBindingType: Int], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected = covering ?? Set(library.functionNames).subtracting(Self.probeFunctions)
        #expect(
            Set(entries.map(\.function)) == expected,
            "表の入口とライブラリの入口が食い違う", sourceLocation: sourceLocation)

        for entry in entries {
            guard let reflection = library.reflection(functionName: entry.function) else {
                Issue.record("\(entry.function) の反射が取れない", sourceLocation: sourceLocation)
                continue
            }
            let bindings = reflection.bindings.filter {
                $0.type == .buffer || $0.type == .texture || $0.type == .sampler
            }
            let metalNames = Set(bindings.map(\.name))
            let swiftNames = Set(entry.ports.map(\.name))
            #expect(
                metalNames == swiftNames,
                """
                \(entry.function): 口の名前が食い違う — Metal にだけある \
                \(metalNames.subtracting(swiftNames).sorted()) / Swift の表にだけある \
                \(swiftNames.subtracting(metalNames).sorted())
                """, sourceLocation: sourceLocation)

            for binding in bindings {
                guard let port = entry.ports.first(where: { $0.name == binding.name }) else {
                    continue
                }
                let place = "\(entry.function) の \(binding.name)"
                #expect(binding.type == port.kind, "\(place): 口の種類が違う", sourceLocation: sourceLocation)
                #expect(
                    binding.index == port.index,
                    "\(place): Metal は \(binding.index) 番、Swift は \(port.index) 番",
                    sourceLocation: sourceLocation)
                if let limit = limits[binding.type] {
                    #expect(
                        binding.index < limit,
                        "\(place): \(binding.index) 番は引数のテーブルの上限 \(limit) に収まらない",
                        sourceLocation: sourceLocation)
                } else {
                    Issue.record(
                        "\(place): この種類の口の上限が表に無い", sourceLocation: sourceLocation)
                }
                if let buffer = binding as? any MTLBufferBinding {
                    compare(
                        buffer, with: port.expectation, at: entry.function,
                        sourceLocation: sourceLocation)
                }
            }
        }
    }

    /// 1 つの置き場の口を、Swift 側の期待と比べる。
    func compare(
        _ buffer: any MTLBufferBinding, with expectation: Expectation, at function: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let place = "\(function) の \(buffer.name)"
        switch expectation {
        case .layout(let layout):
            #expect(
                layout.fields.map(\.name) == layout.storedNames,
                "\(layout.typeName): 表の欄 \(layout.fields.map(\.name)) が、Swift の型の格納プロパティ \(layout.storedNames) と揃っていない",
                sourceLocation: sourceLocation)
            #expect(
                buffer.bufferDataSize == layout.size,
                "\(place): Metal は \(buffer.bufferDataSize) バイト、Swift の \(layout.typeName) は \(layout.size) バイト",
                sourceLocation: sourceLocation)
            let members = (buffer.bufferStructType?.members ?? []).map {
                Field(name: $0.name, offset: $0.offset, type: $0.dataType)
            }
            #expect(
                members == layout.fields,
                "\(place): 並びが Swift の \(layout.typeName) と違う — Metal \(members) / Swift \(layout.fields)",
                sourceLocation: sourceLocation)
        case .scalar(let type):
            #expect(
                buffer.bufferDataType == Self.dataType(of: type),
                "\(place): Metal の型 \(buffer.bufferDataType.rawValue) が Swift の \(type) と違う",
                sourceLocation: sourceLocation)
        case .indexOnly:
            break
        }
    }

    /// 入口の関数が受け取る、名前の付いた置き場の口。
    func buffer(named name: String, in function: String, of library: any MTLLibrary)
        -> (any MTLBufferBinding)?
    {
        library.reflection(functionName: function)?.bindings
            .first { $0.name == name && $0.type == .buffer } as? any MTLBufferBinding
    }
}
