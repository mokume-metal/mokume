// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import Metal

/// 焼いた絵を、別のプロセスから読める面へ差し出す口。
///
/// 見張り (`watch`) は保存のたびに子を入れ替えるので、**子が窓を持つ限り窓は死ぬ** —
/// 全画面も、どの画面に置いたかも、窓の寿命に紐づいているので一緒に失われる。窓の寿命を
/// 子から切り離すには、絵をプロセスの外へ出す必要がある ([ADR-0032] 決定 1)。
///
/// ## 運ぶのは「焼いた後の絵」で、8 bit には落とさない
///
/// 出力段を走らせるのは**子**である ([ADR-0032] 決定 2)。出力段の実装はスケッチが固定して
/// いる版のもので、道具は自分の版を持っている — 焼く側を道具へ移すと、版が食い違った日に
/// 制作中の絵だけが変わる。
///
/// 形式は作業空間と同じ半精度 (``RenderTarget/pixelFormat``) のままにする。8 bit へ落とすと
/// [ADR-0011] 決定 5 の EDR 出力が構造的に通れなくなるためで、**画面へ差し出す断片は既定の
/// 設定では画素に 1 ビットも触らない**ので、1.0 を超える明るさはそのままここへ届く
/// (`Present.metal` の `presentFragmentMain`)。`clamp(0,1)` と伝達関数を掛けるのは 8 bit へ
/// 書く別の断片 `presentEncodeFragmentMain` のほうで、**この 2 本を取り違えない**ことが
/// 決定 2 の実体である。
///
/// ## 帯は焼き込まない
///
/// 面はキャンバスと同じ大きさで持つので、``FramePresenter/draw(_:into:)`` の収まり計算は
/// 恒等になり、帯 (レターボックス) は 1 画素も入らない。帯は**窓の大きさ**の話なので、
/// 付けるのは読む側 (道具) である。
///
/// ## 途中の絵を掴ませない
///
/// 面を複数持ち、順に書く。書き終わった枚数を**面の属性**として載せるので、読み手は
/// 「いちばん大きい枚数を名乗っている面」を選べばよい — 壁時計で待たない
/// ([ADR-0018] 決定 3 と同じ規律)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class SharedFrameSurface {
    /// 面の画素形式 (`'RGhA'` = 4 成分・半精度浮動小数)。
    ///
    /// **``RenderTarget/pixelFormat`` と対になっている。** IOSurface 側は Metal の
    /// `MTLPixelFormat` を知らないので、同じ形式を別の綴りで 2 度言うしかない。
    /// 食い違えばテクスチャを被せられないので、破れは起動の瞬間に出る。
    static let surfaceFormat: OSType = 0x5247_6841

    /// 1 画素あたりのバイト数。``RenderTarget/bytesPerPixel`` と同じ。
    static let bytesPerPixel = RenderTarget.bytesPerPixel

    /// 持つ面の枚数。
    ///
    /// **2 枚では足りない。** 読み手が 1 枚を掴んでいる間に書き手が次を書き、その次で
    /// 掴まれている面へ戻ってくる。3 枚あれば、読み手が 1 枚遅れていても書き手は
    /// 空いている面を選べる。
    static let slotCount = 3

    /// 書き終わった枚数を載せる属性の名前。
    static let frameAttribute = "mokume.frame"

    /// 面の番号を置くファイルの名前。
    static let manifestName = "surface.json"

    /// 面の番号と大きさ。**読み手が最初に読むもの。**
    ///
    /// 毎フレームは書かない — 中身が変わるのは大きさが変わったときだけである。
    struct Manifest: Encodable, Equatable {
        static let schemaVersion = 1

        /// 面の番号。並びが**書く順**である。
        let ids: [UInt32]
        let width: Int
        let height: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, ids, width, height
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.schemaVersion, forKey: .schemaVersion)
            try container.encode(ids, forKey: .ids)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        }
    }

    /// 1 枚ぶん。
    private struct Slot {
        let surface: IOSurfaceRef
        let texture: any MTLTexture
    }

    let width: Int
    let height: Int
    /// 面の番号 (書く順)。
    let ids: [UInt32]

    private let slots: [Slot]
    private let manifestURL: URL
    /// これまでに書き終わった枚数。**1 から数える** — 0 は「まだ 1 枚も書いていない」を
    /// 表すので、読み手は属性が 0 の面を掴まずに済む。
    private(set) var frameNumber = 0

    /// 区画があるときだけ作る。**区画の名前は ``StartupReads`` が正典** (#380)。
    ///
    /// **作れなかったときは `nil` を返す。** 呼ぶ側は窓を開く側へ倒す — 面も窓も無い
    /// 実行は、何が起きたのか外から見て「動いていない」としか見えない。
    static func makeIfEnabled(
        gpu: RenderDevice, width: Int, height: Int,
        at directory: URL = WorkDirectory.facet(StartupReads.viewport.key)
    ) -> SharedFrameSurface? {
        guard isEnabled(at: directory) else { return nil }
        return try? SharedFrameSurface(gpu: gpu, width: width, height: height, at: directory)
    }

    /// 画面の出口が共有する面になっているか。
    ///
    /// **合図はこれ 1 つである** ([ADR-0032] 決定 1)。窓を開かないことも、道具から来る
    /// 出来事を標準入力から受けることも ([ADR-0032] 決定 4)、同じ合図から従う — 経路
    /// ごとに合図を持つと、片方だけが効いている状態が作れてしまう。
    ///
    /// 読む場所を 1 つに保つため、区画を見るのは**ここだけ**にする (一覧が名指しして
    /// いるのもこのファイルである)。
    static func isEnabled(at directory: URL = WorkDirectory.facet(StartupReads.viewport.key))
        -> Bool
    {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    init(gpu: RenderDevice, width: Int, height: Int, at directory: URL) throws(RenderFailure) {
        guard width > 0, height > 0 else { throw .invalidSize(width: width, height: height) }
        self.width = width
        self.height = height
        self.manifestURL = directory.appendingPathComponent(Self.manifestName)

        var slots: [Slot] = []
        for _ in 0..<Self.slotCount {
            slots.append(try Self.makeSlot(gpu: gpu, width: width, height: height))
        }
        self.slots = slots
        self.ids = slots.map { IOSurfaceGetID($0.surface) }
    }

    /// 番号だけで引けるようにする印。
    ///
    /// **これが無いと `IOSurfaceLookup` は同じプロセスからしか通らない。** 外から引くと
    /// 黙って `nil` が返るので、症状は「窓は出ているのに真っ白」としてしか現れない —
    /// 実際にそう踏んだ ([#704](https://github.com/mokume-metal/mokume/issues/704))。
    /// 番号を渡すやり方 ([ADR-0032] 決定 3) は、これが在って初めて成り立つ。
    ///
    /// **綴りを直に書いてある。** 対応する定数 `kIOSurfaceIsGlobal` は macOS 10.11 で
    /// 非推奨になり (`Global surfaces are insecure`)、参照すると警告が出る。代わりの道は
    /// 「番号ではなく mach port を渡す」ことで、それは**通信路を 1 本増やす**ことに等しく、
    /// 決定 3 が避けたものそのものである。隠すためではなく、**選んだことをここに書き切って
    /// 建物の警告を静かに保つ**ために綴りで持つ。同じ機械の上で Syphon も同じ道を通る。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static let globalKey = "IOSurfaceIsGlobal" as CFString

    /// 面に与える性質。**検査から読めるように切り出してある** — 番号で引けるかどうかは
    /// 別のプロセスからしか確かめられないので、せめて印が載っていることは見ておく。
    static func properties(width: Int, height: Int) -> CFDictionary {
        [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfacePixelFormat: Self.surfaceFormat,
            kIOSurfaceBytesPerElement: Self.bytesPerPixel,
            globalKey: true,
        ] as [CFString: Any] as CFDictionary
    }

    /// 面を 1 枚作り、テクスチャを被せる。
    private static func makeSlot(
        gpu: RenderDevice, width: Int, height: Int
    ) throws(RenderFailure) -> Slot {
        guard let surface = IOSurfaceCreate(properties(width: width, height: height)) else {
            throw .textureUnavailable(width: width, height: height)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: width, height: height, mipmapped: false)
        // 書く側 (差し出しのパス) と、読む側 (同じプロセスから確かめる検査) の両方。
        // `storageMode` は面が決めるので触らない
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        else {
            throw .textureUnavailable(width: width, height: height)
        }
        // **確保したリソースは必ず常駐を通す。** 通し忘れると検証層が咎め、実装や OS の
        // 版が変われば黙って壊れうる (#357)。面は起動時に作り切るので 1 回で済む
        gpu.makeResident(texture)
        return Slot(surface: surface, texture: texture)
    }

    /// 面の番号を区画へ置く。**新しい通信路を作らない** ([ADR-0032] 決定 3)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    func publishManifest() throws {
        let manifest = Manifest(ids: ids, width: width, height: height)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(try encoder.encode(manifest), to: manifestURL)
    }

    /// 描いた絵を、次の面へ焼いて差し出す。
    ///
    /// **書き終わってから名乗る。** 属性を先に載せると、読み手が書きかけの面を掴む。
    /// ``FramePresenter/draw(_:into:)`` は GPU の完了まで待つので、返った時点で面の
    /// 中身は揃っている。
    func write(_ source: RenderTarget, using presenter: FramePresenter) throws(RenderFailure) {
        let slot = slots[frameNumber % slots.count]
        try presenter.draw(source, into: slot.texture)
        frameNumber += 1
        IOSurfaceSetValue(
            slot.surface, Self.frameAttribute as CFString, NSNumber(value: frameNumber))
    }

    /// 置かれている面の番号を読む。読み手の側の規則。
    ///
    /// **書く側と同じ綴りをここで持つ。** 読み手は別のプロセスなので、綴りが 2 か所へ
    /// 分かれると片方だけ直したときに静かに食い違う。
    ///
    /// - Returns: 読めなければ `nil`。**版が違えば読まない** — 知らない形を推測で解くと、
    ///   食い違いが絵の壊れ方として出る。
    static func readManifest(at facet: URL) -> (ids: [UInt32], width: Int, height: Int)? {
        let url = facet.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["schemaVersion"] as? Int == Manifest.schemaVersion,
            let ids = object["ids"] as? [UInt32], !ids.isEmpty,
            let width = object["width"] as? Int, width > 0,
            let height = object["height"] as? Int, height > 0
        else { return nil }
        return (ids, width, height)
    }

    /// いま読むべき面の番号と、その面が名乗っている枚数。読み手の側の規則。
    ///
    /// **書き手と同じ規則をここに置く。** 読む側 (道具) は別のプロセスなので、規則が
    /// 2 か所に分かれると片方だけ直したときに静かに食い違う。
    ///
    /// - Returns: 掴むべき面の番号と枚数。まだ 1 枚も書かれていなければ `nil`。
    static func newest(among ids: [UInt32]) -> (id: UInt32, frame: Int)? {
        var best: (id: UInt32, frame: Int)?
        for id in ids {
            guard let surface = IOSurfaceLookup(id) else { continue }
            let value = IOSurfaceCopyValue(surface, frameAttribute as CFString) as? NSNumber
            let frame = value?.intValue ?? 0
            // **まだ 1 枚も書かれていない面は掴まない。** 属性が無ければ 0 が返るので、
            // 起動した直後に読みに来た読み手は「まだ無い」を受け取る
            guard frame > 0 else { continue }
            // **新しいかどうかは、既に選んだものとだけ比べる。** 「無ければ 0」と畳むと
            // 上の判定が二重になり、片方を壊しても検査が赤くならない
            guard let chosen = best else {
                best = (id, frame)
                continue
            }
            if frame > chosen.frame { best = (id, frame) }
        }
        return best
    }
}
