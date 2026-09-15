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
/// **公開は 1 枚遅れる** ([#748])。焼く投入は待たずに出し、属性は**次の** ``write(_:using:numbers:)``
/// の先頭でその投入を名指しで待ってから載せる — 待つ間の CPU の仕事 (次のフレームの
/// `draw()`) が GPU と重なる。読み手は枚数がいちばん大きい面を選ぶので、遅れた公開と
/// そのまま噛み合う。
///
/// [#748]: https://github.com/mokume-metal/mokume/issues/748
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
    ///
    /// **公開を 1 枚遅らせたので 4 枚持つ** ([#748])。焼いている面は公開の手前にあるぶん
    /// 1 枚先を回っており、3 枚のままだと読み手が最新として掴んだ面が 2 回目の書き込みで
    /// 書き直される (遅らせる前は 3 回目)。読み手は掴んだ面を GPU の完了を待たずに差し出す
    /// ので、この猶予が途中の絵を読ませないことの実体である — 縮めずに保つほうへ倒し、
    /// 費用はキャンバス大の面 1 枚ぶんで払う。読み手は枚数を番号の並び (``Manifest``) から
    /// 取るので、版の違う道具ともそのまま噛み合う。
    ///
    /// [#748]: https://github.com/mokume-metal/mokume/issues/748
    static let slotCount = 4

    /// 書き終わった枚数を載せる属性の名前。
    static let frameAttribute = "mokume.frame"

    /// 走っている速さを載せる属性の名前。
    ///
    /// **数えるのは走らせている側である** ([ADR-0030] 決定 7)。道具は読み手であって、自分で
    /// 平均を取らない — 窓が同じプロセスに在るときは集計器 (``FrameTempo``) を直に読めるが、
    /// プロセスが分かれるとそれができないので、走らせている側が載せる側になる。
    ///
    /// ## なぜ絵と同じ面に載せるのか
    ///
    /// **通信路が 1 本も増えない** ([ADR-0032] 決定 3)。道具はどの面が新しいかを決めるために、
    /// 既に毎リフレッシュこの面の属性を引いている (``newest(among:)``) — そこへ数個足すだけ
    /// なので、読む側の往復は 0 回のままである。
    ///
    /// 観測の面 (`.mokume/observe`) にも同じ数字は在る (`load.frameRate`) が、そちらは要求と
    /// 応答の往復で、応答を組む手間 (メモリ・熱の問い合わせ) が毎フレームの描画に乗る。窓を
    /// ファイルの応答の読み手にしないのは [ADR-0030] 決定 7 が名指しで断っているところである。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    enum TempoAttribute {
        /// 進めた枚数。**面が名乗る枚数とは別物** — こちらはスケッチが数えたフレームの数で、
        /// ``frameAttribute`` は面へ書き終えた回数である。
        static let frameCount = "mokume.frameCount"
        /// スケッチの時刻 (秒)。
        static let time = "mokume.time"
        /// 直近で実際に出ている速さ。**測れていなければ載らない。**
        static let frameRate = "mokume.frameRate"
        /// 直近のフレーム時間の平均 (ミリ秒)。**測れていなければ載らない。**
        static let frameTimeMs = "mokume.frameTimeMs"
    }

    /// 面の番号を置くファイルの名前。
    static let manifestName = "surface.json"

    /// 面の番号と大きさ。**読み手が最初に読むもの。**
    ///
    /// 毎フレームは書かない — 中身が変わるのは大きさが変わったときだけである。
    /// **書く側と読む側で 1 つの型である。** かつては書くのが `Encodable`、読むのが
    /// `JSONSerialization` + 鍵の手打ちで、鍵の綴りが 2 か所に分かれていた — 読む側の doc は
    /// 「綴りが 2 か所へ分かれると片方だけ直したときに静かに食い違う」と危うさを名乗って
    /// いたが、**注意書きは分かれることを止めない**
    /// ([#960](https://github.com/mokume-metal/mokume/issues/960) の 4)。
    struct Manifest: Codable {
        /// この形の版。**先頭の格納プロパティである** — 合成の `encode` は宣言順に
        /// 書き出すので、置き場所が鍵の並びを決める。
        let schemaVersion = Manifest.readableVersion

        /// 書く版であり、読める版でもある。**``init(from:)`` が突き合わせる先。**
        ///
        /// 格納プロパティと分けてあるのは、読むときには**まだ組み立てていない**値と
        /// 比べる必要があるためである。
        static let readableVersion = 1

        /// 面の番号。並びが**書く順**である。
        let ids: [UInt32]
        let width: Int
        let height: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, ids, width, height
        }

        init(ids: [UInt32], width: Int, height: Int) {
            self.ids = ids
            self.width = width
            self.height = height
        }

        /// **版が違えば読まない。** 知らない形を推測で解くと、食い違いが絵の壊れ方として出る。
        ///
        /// 絵にならない値もここで止める — 面が 1 枚も無い、大きさが 0 以下。**持ち回ってから
        /// 気付くと、落ちる場所が読んだ所から遠ざかる。**
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .schemaVersion)
            guard version == Self.readableVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion, in: container,
                    debugDescription: "Unknown version: \(version) (readable: \(Self.readableVersion))")
            }
            ids = try container.decode([UInt32].self, forKey: .ids)
            width = try container.decode(Int.self, forKey: .width)
            height = try container.decode(Int.self, forKey: .height)
            guard !ids.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ids, in: container, debugDescription: "There are no surfaces")
            }
            guard width > 0, height > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .width, in: container,
                    debugDescription: "Not a drawable size: \(width)x\(height)")
            }
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
    /// 焼いた投入を名指しで待つために持つ。
    private let gpu: RenderDevice
    /// 焼いたがまだ名乗っていない 1 枚。**次の書き込みの先頭で公開する** ([#748])。
    ///
    /// [#748]: https://github.com/mokume-metal/mokume/issues/748
    private var pending: (slot: Int, submission: UInt64, numbers: FrameNumbers)?
    /// これまでに名乗った枚数。**1 から数える** — 0 は「まだ 1 枚も書いていない」を
    /// 表すので、読み手は属性が 0 の面を掴まずに済む。**焼いて控えている 1 枚は数えない。**
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
    /// 読む場所を 1 つに保つため、**viewport の区画を渡すのはここだけ**にする (一覧が
    /// 名指ししているのもこのファイルである)。判定そのものの綴りは
    /// ``WorkDirectory/directoryExists(at:)`` が持つ — 5 箇所が同じ 3 行を書いていた
    /// ([#988](https://github.com/mokume-metal/mokume/issues/988))。
    static func isEnabled(at directory: URL = WorkDirectory.facet(StartupReads.viewport.key))
        -> Bool
    {
        WorkDirectory.directoryExists(at: directory)
    }

    init(gpu: RenderDevice, width: Int, height: Int, at directory: URL) throws(RenderFailure) {
        guard width > 0, height > 0 else { throw .invalidSize(width: width, height: height) }
        self.width = width
        self.height = height
        self.gpu = gpu
        self.manifestURL = directory.appendingPathComponent(Self.manifestName)

        var slots: [Slot] = []
        for _ in 0..<Self.slotCount {
            slots.append(try Self.makeSlot(gpu: gpu, width: width, height: height))
        }
        self.slots = slots
        self.ids = slots.map { IOSurfaceGetID($0.surface) }
    }

    /// **面に被せたテクスチャを常駐から退かせる** ([#795])。
    ///
    /// 退かせるのはこのプロセスの常駐だけで、面そのもの (IOSurface) は参照計数なので、
    /// 読み手がまだ引いていれば読み手の側で生きている。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    isolated deinit {
        for slot in slots { gpu.retire(slot.texture) }
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
    /// **投げる。** 置けなかったときに窓を開く側へ倒す判断は呼び手 (``SketchApplication``)
    /// が持つので、ここは名乗らない — 判断が呼び手にある口だけが `throws` である (#989)。
    func publishManifest() throws {
        try AtomicFile.writeJSON(Manifest(ids: ids, width: width, height: height), to: manifestURL)
    }

    /// 描いた絵を次の面へ焼き、**前に焼いた 1 枚を差し出す。**
    ///
    /// 焼く投入は待たない。いま焼いた絵が名乗るのは次の書き込みのときである ([#748])。
    /// 走っているスケッチは止めている間も毎リフレッシュここを通るので、控えた 1 枚は
    /// 次のリフレッシュで必ず出る。
    ///
    /// [#748]: https://github.com/mokume-metal/mokume/issues/748
    /// - Parameter numbers: この絵を描いたときの速さ。絵と一緒に控え、絵と一緒に載せる。
    func write(
        _ source: RenderTarget, using presenter: FramePresenter, numbers: FrameNumbers
    ) throws(RenderFailure) {
        try publishPending()
        // **焼く面は、公開した枚数から決まる。** 控えを出した後なので、公開済みの最新面の
        // 次を踏む — 最新面そのものへは戻らない
        let index = frameNumber % slots.count
        let submission = try presenter.draw(source, into: slots[index].texture)
        pending = (index, submission, numbers)
    }

    /// 控えている 1 枚を名乗らせる。控えが無ければ何もしない。
    ///
    /// **書き終わってから名乗る。** 属性を先に載せると、読み手が書きかけの面を掴む。
    /// 焼いた投入を名指しで待ってから載せるので、名乗った時点で面の中身は揃っている。
    /// 待つのは 1 本だけで、1 枚遅らせているぶん普通は何もせずに返る。
    ///
    /// **待てなければ名乗らない。** 控えは先に手放すので、次の書き込みは同じ面を焼き直す。
    func publishPending() throws(RenderFailure) {
        guard let written = pending else { return }
        pending = nil
        try gpu.waitForSubmission(written.submission)
        let slot = slots[written.slot]
        frameNumber += 1
        // **速さを枚数より先に載せる。** 読み手は枚数がいちばん大きい面を選ぶので、枚数を
        // 最後にすれば、選ばれた面の速さは必ずその枚数のときのものになる。属性を 1 つずつ
        // 載せる以上まとめて差し替わることはないが、順序だけで「古い速さと新しい枚数」の
        // 組み合わせは起きなくなる
        Self.publish(written.numbers, to: slot.surface)
        IOSurfaceSetValue(
            slot.surface, Self.frameAttribute as CFString, NSNumber(value: frameNumber))
    }

    /// 焼いたがまだ名乗っていない面の番号。控えが無ければ `nil`。
    ///
    /// 検査が読む — 「焼いている面が、読み手の掴んでいる面ではない」を確かめる口。
    var pendingID: UInt32? { pending.map { ids[$0.slot] } }

    /// 速さを面へ載せる。
    ///
    /// **測れていない値は属性ごと消す。** 観測の応答が鍵ごと省くのと同じ形にする
    /// ([ADR-0030] 決定 7) — 0 を載せると「測ったら 0 だった」と読めてしまい、前のフレームの
    /// 値を残すと止まった瞬間の数字を名乗り続ける (面は使い回されるので、消さなければ残る)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private static func publish(_ numbers: FrameNumbers, to surface: IOSurfaceRef) {
        IOSurfaceSetValue(
            surface, TempoAttribute.frameCount as CFString, NSNumber(value: numbers.frameCount))
        IOSurfaceSetValue(surface, TempoAttribute.time as CFString, NSNumber(value: numbers.time))
        set(numbers.frameRate, as: TempoAttribute.frameRate, on: surface)
        set(numbers.frameTimeMs, as: TempoAttribute.frameTimeMs, on: surface)
    }

    /// 測れた数だけを載せる。測れていなければ**消す**。
    private static func set(_ value: Double?, as name: String, on surface: IOSurfaceRef) {
        guard let value else {
            IOSurfaceRemoveValue(surface, name as CFString)
            return
        }
        IOSurfaceSetValue(surface, name as CFString, NSNumber(value: value))
    }

    /// 置かれている面の番号を、その場で 1 回だけ読む。
    ///
    /// **綴りを持っているのは ``Manifest`` 1 つである。** 読み手は別のプロセスなので、鍵の
    /// 綴りが書く側と 2 か所へ分かれると片方だけ直したときに静かに食い違う — かつては
    /// ここが `JSONSerialization` で鍵を手打ちしており、その危うさを doc で注意していた。
    ///
    /// **見張る側はここを通らない。** 続けて読む読み手 (``SharedFrameStage``) は
    /// ``WatchedFile`` を持つ — 最終更新時刻をいつ控えるかという規律が要り、それを口ごとに
    /// 書き写すと落ちる ([#1048](https://github.com/mokume-metal/mokume/issues/1048))。
    /// ここに残るのは、**置いた中身がそのまま読めることを見る**ための口である。
    ///
    /// - Returns: 読めなければ `nil`。版・面の枚数・大きさの検めは ``Manifest/init(from:)``
    ///   が持つ。
    static func readManifest(at facet: URL) -> Manifest? {
        let url = facet.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
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

    /// 面が名乗っている速さ。読み手の側の規則。
    ///
    /// **書き手と同じ綴りをここで持つ** (``publish(_:to:)`` と対になっている)。読む側は別の
    /// プロセスなので、綴りが 2 か所に分かれると片方だけ直したときに静かに食い違う。
    ///
    /// - Returns: 面が引けない・まだ何も載っていなければ `nil`。**速さとフレーム時間は
    ///   載っていないことがある** — 起動直後と止めている間は測れていないので、書き手が
    ///   鍵ごと省く。
    static func numbers(of id: UInt32) -> FrameNumbers? {
        guard let surface = IOSurfaceLookup(id),
            let count = number(TempoAttribute.frameCount, on: surface)?.intValue,
            let time = number(TempoAttribute.time, on: surface)?.doubleValue
        else { return nil }
        return FrameNumbers(
            frameCount: count, time: time,
            frameRate: number(TempoAttribute.frameRate, on: surface)?.doubleValue,
            frameTimeMs: number(TempoAttribute.frameTimeMs, on: surface)?.doubleValue)
    }

    private static func number(_ name: String, on surface: IOSurfaceRef) -> NSNumber? {
        IOSurfaceCopyValue(surface, name as CFString) as? NSNumber
    }
}
