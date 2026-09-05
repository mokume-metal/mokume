// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

// `@MainActor` はターゲットの既定隔離 (`Package.swift` の `.defaultIsolation`) と同じ意味で、
// 付けなくても隔離は変わらない。**明示しているのは release のテストビルドのため**である —
// `swift test -c release` では、この型を外から読むターゲット (`frame-rate-probe` や
// `@testable import` する検査) が module を deserialize する際に暗黙の既定隔離を見失い、
// `isolated deinit` が「隔離されていないクラスに付いている」として compile を止める
// (#761)。debug と製品の release では出ない。明示すれば取り込み側にも隔離が伝わる。

/// GPU 側の一式を束ねる — デバイス・コマンドの発行口・コマンドの置き場・リソースの常駐。
///
/// ## なぜ常駐をここに集めるのか
///
/// この世代の Metal では、コマンドが触るリソースを常駐させるのは呼び出し側の責務で、
/// 常駐していないリソースを読むと結果が未定義になる。**常駐の管理を各所に散らすと
/// 「バインドしたのに描かれない」形の、症状からは原因の見えない失敗になる。**
/// そこで確保したリソースは必ずここを通し、常駐の集合をこの型が持つ。
///
/// 集合は**寿命で 2 つに分けてある** — 確保したものが全部入る `residencySet` と、
/// 表示に差し出す面だけが入る `drawableResidency` である。差し出す面の環は Metal
/// 側が持っていて、面の大きさが変わると環ごと作り直される。混ぜると、古い面だけを
/// 畳む手が無い ([#357](https://github.com/mokume-metal/mokume/issues/357))。
///
/// ## 使い方
///
/// <!-- example: 組めない beginCommands / commitAndWait が internal で、外からは書けない (#563) -->
/// ```swift
/// let gpu = try RenderDevice()
/// let commands = try gpu.beginCommands()
/// // …commands へ書き込む…
/// try gpu.commitAndWait(commands)
/// ```
///
/// `commitAndWait(_:)` は GPU の完了まで呼び出し元を止める。1 枚だけ描く経路と検証で
/// 使う形で、フレームを回す経路は待たない `commit(_:retaining:)` を使う
/// ([#727](https://github.com/mokume-metal/mokume/issues/727))。
///
/// ## 待たない投入が守る 2 つのこと
///
/// 1. **CPU が GPU 可視メモリに触る (書く・GPU の結果を読む) 直前には、投入済みの
///    コマンドがすべて終わっている。** 触る側が直前に `settle()` を呼ぶ。投入済みの
///    ものが全部終わっていれば何もせずに返るので、触らないフレームは 1 度も待たない
/// 2. **GPU 上でも、投入したコマンドは投入順に実行される。** この世代は別々に投入した
///    コマンドの間の順序を自動では保証しない (encoder の間と同じ・#341)。投入のたびに
///    「直前の番号を GPU 側で待つ」を積んで、順序を明示する
///
/// 投入したコマンドが読むリソースは、**投入した側が参照を手放しても**終わるまで生きて
/// いなければならない (この世代のコマンドはリソースを保持しない)。手放す予定のものは
/// `commit(_:retaining:)` に渡し、この型が完了まで抱える。
@MainActor public final class RenderDevice {
    /// GPU が完了するのを待つ上限 (秒)。
    ///
    /// 待ちが返らないときに永久に止まらないための上限で、**検証がこの値そのものを
    /// 物差しにできるよう**定数で持つ (壁時計の絶対値をテストに書かない)。
    public static let waitLimitSeconds = 5

    /// この実行環境で描画の土台を組み立てられるか。
    ///
    /// **GPU があるかだけでは足りない。** 仮想化された実行環境には、GPU としては
    /// 見えるのにこの世代のコマンド構造に対応していないものがあり、そこでは
    /// コマンドの発行口が作れない。[ADR-0009] 決定 2 により旧世代へのフォールバック
    /// 経路は持たないので、そういう環境では描画そのものが成立しない。
    ///
    /// 判定を「実際に必要なところまで試す」形にしてあるのは、GPU の有無だけを見て
    /// 「使える」と答えると、GPU を要する検証がスキップされずに失敗するため。
    ///
    /// 隔離の外から呼べる形にしてあるのは、検査の実行可否を決める前提条件として
    /// 隔離の外で評価されるため。問い合わせは GPU を持ち出さないので状態を跨がない。
    ///
    /// [ADR-0009]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0009-platform-floor-and-toolchain.md
    public nonisolated static var isAvailable: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.makeMTL4CommandQueue() != nil
    }

    let device: any MTLDevice
    let queue: any MTL4CommandQueue

    /// コマンドの置き場ひとつぶん。
    ///
    /// 置き場は巻き戻して使い回すが、**巻き戻してよいのは、そこへ積んだコマンドを
    /// GPU が終えてから**である。だから「最後にここから投入した番号」を憶えておく。
    private struct Slot {
        let allocator: any MTL4CommandAllocator
        /// この置き場から最後に投入したコマンドの番号。まだ無ければ 0。
        var submission: UInt64 = 0
    }

    /// 置き場の環。
    ///
    /// 1 本を毎回巻き戻す形は、**待たない経路が 1 つでもあると壊れる** — 表示の経路
    /// (``commit(_:signalling:)``) は GPU の完了を待たないので、次の
    /// ``beginCommands()`` がまだ実行中のコマンドの載った置き場を巻き戻していた
    /// ([#222](https://github.com/mokume-metal/mokume/issues/222))。環にして 1 周ぶん
    /// 遅らせ、それでも終わっていなければ待つ。
    private var slots: [Slot]
    /// 次に使う置き場。
    private var nextSlot = 0
    /// 組み立て中のコマンドが、どの置き場に載っているか。
    ///
    /// 投入のときに番号を書き戻す先を引くために持つ。同時に複数本を組み立てても
    /// 取り違えないよう、コマンドそのものを鍵にする。
    private var slotOfOpenCommands: [ObjectIdentifier: Int] = [:]

    /// 環の既定の本数。
    ///
    /// 描画・読み戻し・表示で 1 フレームあたり 2〜3 本使うので、3 本あれば
    /// 巻き戻す番が回ってくる頃には 1 フレームぶん前の仕事になっている。**正しさは
    /// 本数に依らない** (足りなければ待つ) ので、ここは速さのための値である。
    static let defaultSlotCount = 3

    /// この土台が持つ置き場の本数。
    ///
    /// **フレームごとに書く置き場の環 (``FrameRing``) も同じ本数にする。** 置き場を
    /// 1 本にした土台 (検査用) ではコマンドの環が既に全部を直列にするので、データ側
    /// だけ深くしても意味がない。1 つの値から引けば、どちらの環も同じ深さを名乗る。
    var slotCount: Int { slots.count }

    /// 診断: 置き場が空くのを待った回数。
    ///
    /// **「実行中の置き場を巻き戻さなかった回数」は数えない。** かつてそういう診断
    /// (`resetsWhileInFlight`) を ``beginCommands()`` の待ちの**あと**に置いていたが、
    /// 判定は ``waitForSlot(_:)`` と同じ合図を 1 行あとで読むので、`waitForSlot` の
    /// 事後条件の自己申告以上にはならなかった — 0 が「待ちが守った」と「そもそも
    /// 危なくなかった」を分けないので、それを `== 0` で読んでいた 6 本の検査のうち
    /// 3 本は、待ちを丸ごと外しても緑のままだった ([#790])。数えるのは**実際に待った
    /// 回数**だけにして、事後条件のほうは検査が外から見る (`CommandAllocatorTests`)。
    ///
    /// [#790]: https://github.com/mokume-metal/mokume/issues/790
    private(set) var slotWaits = 0
    /// 診断: ``settle()`` を頼まれた回数。GPU 可視メモリに触る経路が待ちを要求した数。
    private(set) var settleCalls = 0
    /// 診断: ``settle()`` が実際に止まった回数 (頼まれた時点で GPU が終わっていなかった)。
    private(set) var blockingWaits = 0
    /// 診断: フレームごとに書く置き場の環が、スロットの空きを実際に待った回数。
    ///
    /// ``blockingWaits`` と分けてある。**あちらは「投入済みの全部」を待った回数**で、
    /// 環が効いているフレームでは 0 のままでなければならない ([#754])。こちらは
    /// 「そのスロットを読む投入 1 本」を待った回数で、環が浅い (置き場が 1 本の土台・
    /// CPU が GPU を追い越した) ときに増える。
    ///
    /// [#754]: https://github.com/mokume-metal/mokume/issues/754
    private(set) var ringWaits = 0

    /// 投入したコマンドが読むリソースを、終わるまで抱えておく列。
    ///
    /// **番号の順に並ぶ。** 番号 n までが終わったと分かったら、先頭から n 以下のものを
    /// 落とす。投入した側が参照を手放しても、ここが抱えている間は解放されない。
    private var held: [(submission: UInt64, resources: [AnyObject])] = []

    /// 診断: 完了を待って抱えているリソースの数。
    var heldResourceCount: Int { held.reduce(0) { $0 + $1.resources.count } }

    /// 持ち主が死んだリソースを、常駐から外す番が来るまで並べておく列。
    ///
    /// **上の列と同じ形で番号順に並ぶ。** あちらが「終わるまで抱える」なら、こちらは
    /// 「終わったら外す」で、契機は同じ ``releaseFinished(through:)`` である。
    private var retired: [(submission: UInt64, allocation: any MTLAllocation)] = []

    /// 診断: 常駐から外す番を待っているリソースの数。
    var retiredResourceCount: Int { retired.count }

    /// 投入したコマンドがすべて終わっているか。**問い合わせるだけで待たない。**
    var isIdle: Bool { completion.signaledValue >= submissionCount }

    /// 常駐させるリソースの集合。この型を通して確保したものがすべて入る。
    let residencySet: any MTLResidencySet

    /// 表示に差し出す面だけを入れる集合。
    ///
    /// **畳めるように分けてある。** 面の環は Metal 側が持ち、面の大きさが変わると
    /// 環ごと作り直されるので、古い面は集合から外さないと残り続ける — 実測では 60 回
    /// リサイズしただけで 120 件・85.2 MiB が常駐したままになった ([#357])。上の集合と
    /// 混ぜると、外すときに確保したものまで巻き添えになる。
    ///
    /// [#357]: https://github.com/mokume-metal/mokume/issues/357
    let drawableResidency: any MTLResidencySet

    /// GPU の完了を知るための合図。投入のたびに 1 つ進める。
    private let completion: any MTLSharedEvent
    /// これまでに投入した本数。**写しが「どこまで映したか」を照らす物差し**にもなる
    /// (``RenderTarget/pixels``)。
    private(set) var submissionCount: UInt64 = 0

    /// 既定の GPU で作る。
    public convenience init() throws(RenderFailure) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw .deviceUnavailable
        }
        try self.init(device: device)
    }

    /// GPU を指定して作る。
    public convenience init(device: any MTLDevice) throws(RenderFailure) {
        try self.init(device: device, slotCount: RenderDevice.defaultSlotCount)
    }

    /// 置き場の本数を指定できる入口 (検査用)。
    ///
    /// 1 本にすると「待たない経路の直後に必ず同じ置き場が回ってくる」形になり、
    /// 環が実際に待っていることを検査から確かめられる。
    init(device: any MTLDevice, slotCount: Int) throws(RenderFailure) {
        self.device = device

        guard let queue = device.makeMTL4CommandQueue() else {
            throw .commandQueueUnavailable
        }
        self.queue = queue

        var slots: [Slot] = []
        for _ in 0..<max(1, slotCount) {
            guard let allocator = device.makeCommandAllocator() else {
                throw .commandAllocatorUnavailable
            }
            slots.append(Slot(allocator: allocator))
        }
        self.slots = slots

        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.label = "mokume.residency"
        let residencySet: any MTLResidencySet
        do {
            residencySet = try device.makeResidencySet(descriptor: residencyDescriptor)
        } catch {
            throw .residencySetUnavailable(reason: error.localizedDescription)
        }
        self.residencySet = residencySet
        queue.addResidencySet(residencySet)

        residencyDescriptor.label = "mokume.residency.drawable"
        let drawableResidency: any MTLResidencySet
        do {
            drawableResidency = try device.makeResidencySet(descriptor: residencyDescriptor)
        } catch {
            throw .residencySetUnavailable(reason: error.localizedDescription)
        }
        self.drawableResidency = drawableResidency
        queue.addResidencySet(drawableResidency)

        guard let completion = device.makeSharedEvent() else {
            throw .synchronizationUnavailable
        }
        self.completion = completion
    }

    /// **実行中のものが終わる前に土台を畳まない。**
    ///
    /// 投入は GPU の完了を待たずに返る (``commit(_:retaining:)``) ので、最後の投入の直後に
    /// この型が手放されると、発行口・合図・常駐の集合・抱えているリソースが GPU の実行中に
    /// 消える。実測では、それが同じ GPU の**別の**発行口に積まれた仕事まで巻き添えにした —
    /// 合図は進むのに絵が空のまま読める形で、しかも負荷のかかったときだけ出る (#727 の
    /// 検査で 3 本が同時に落ちた)。畳む前に待てば、投入した側は寿命を気にしなくてよい。
    ///
    /// 詰まっていたら諦めて畳む。ここで投げる先は無いので、警告だけ残す。
    isolated deinit {
        guard !isIdle else { return }
        let limit = UInt64(Self.waitLimitSeconds * 1000)
        if !completion.wait(untilSignaledValue: submissionCount, timeoutMS: limit) {
            Diagnostics.warn(
                "GPU の完了を \(Self.waitLimitSeconds) 秒待っても返らないまま、描画の土台を畳みます")
        }
    }

    // MARK: - リソース

    /// リソースを常駐させる。確保したリソースは必ずここを通す。
    ///
    /// 常駐は集合への追加だけでは効かず、追加のあとに確定させる必要がある。
    /// 呼ぶたびに確定させるので、確保の直後に 1 回呼べばよい。
    func makeResident(_ allocation: any MTLAllocation) {
        residencySet.addAllocation(allocation)
        residencySet.commit()
        residencySet.requestResidency()
    }

    /// 常駐から外す。**寿命が実行より短いリソースだけが通る。**
    ///
    /// 確保したものは基本ずっと生きるので、外す口はふつう要らない。要るのは**外から来る
    /// リソース**である — 別のプロセスが持つ面を引いて使う側は、相手が入れ替わるたびに
    /// 新しい面を引く。外さないと、見張っている間ずっと死んだ面が積み上がる。
    ///
    /// **GPU が空になってから外す。** 実行中のコマンドが踏んでいるリソースを常駐から
    /// 外すと、そのコマンドの結果が未定義になる (``releaseDrawableResidency()`` と同じ)。
    func releaseResidency(of allocations: [any MTLAllocation]) throws(RenderFailure) {
        guard !allocations.isEmpty else { return }
        try settle()
        for allocation in allocations { residencySet.removeAllocation(allocation) }
        residencySet.commit()
    }

    /// 常駐から外す番を待たせる。**待たずに返る** ([#738])。
    ///
    /// 上の口との違いは待ち方だけである。あちらは呼んだその場で全完了を待つので、
    /// **呼べるのは待ってよい場所からだけ**になる — 持ち主が死ぬ瞬間 (`deinit`) や、
    /// 字形の面を広げる途中は待ってよい場所ではない。こちらは番号を控えて並べるだけで、
    /// 実際に外れるのは、そのとき投入済みだったコマンドが終わってからである。
    ///
    /// **確保したものは、持ち主が死んでも常駐の集合が抱えている。** 集合が参照を持つので、
    /// ここを通さない限り解放されない — 症状は「絵は正しいのにメモリが減らない」だけで、
    /// 原因からは遠い。フレームごとに絵を読む・計算を作り直す書き方はこれで積み続ける。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    func retire(_ allocation: any MTLAllocation) {
        // **組み立て中のコマンドは、まだ番号を持っていない。** 開いている最中に死んだ
        // ものは、その 1 本が投入されて終わるまで外せないので 1 つ先の番号で待たせる
        let after = slotOfOpenCommands.isEmpty ? submissionCount : submissionCount + 1
        retired.append((after, allocation))
    }

    /// 表示に差し出す面を常駐させる。差し出す面へ書く前に呼ぶ。
    ///
    /// **既に入っていれば何もしない。** 集合なので入れ直しても数は増えないが、確定
    /// (``MTLResidencySet/commit()``) は毎フレーム払う必要がないため。面の環は大きさが
    /// 同じ限り有界で、実測では 120 フレーム回しても現れる面は 2 種類だった。
    func makeDrawableResident(_ texture: any MTLTexture) {
        guard !drawableResidency.containsAllocation(texture) else { return }
        drawableResidency.addAllocation(texture)
        drawableResidency.commit()
        drawableResidency.requestResidency()
    }

    /// 差し出す面の常駐を畳む。面の大きさが変わって環が作り直されたときに呼ぶ。
    ///
    /// **GPU が空になってから外す。** 実行中のコマンドが踏んでいる面を常駐から外すと、
    /// そのコマンドの結果が未定義になる。畳むのは面の大きさが変わったときだけなので、
    /// この待ちが毎フレームの経路に乗ることはない。
    func releaseDrawableResidency() throws(RenderFailure) {
        guard drawableResidency.allocationCount > 0 else { return }
        try settle()
        drawableResidency.removeAllAllocations()
        drawableResidency.commit()
    }

    /// 描画先にできるテクスチャを確保して常駐させる。
    func makeTexture(descriptor: MTLTextureDescriptor) throws(RenderFailure) -> any MTLTexture {
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw .textureUnavailable(width: descriptor.width, height: descriptor.height)
        }
        makeResident(texture)
        return texture
    }

    /// GPU 専用 (`.private`) の色の面を確保して常駐させ、**透明な黒で塗っておく**。
    ///
    /// GPU 専用の面の初期値は未定義で、CPU から読める置き場 (作られた時点で 0) とは違う。
    /// 塗り直しを頼まずに描き足す最初のフレーム (`background(_:)` を周囲で置く絵) や、
    /// 前のフレームの控えを最初のフレームから読む段 (時間方向の拡大) は、その未定義の
    /// 値を読む — 台帳の `surroundings` がこれで実際に動いた (#753)。作った時点で
    /// 1 度塗れば、置き場に載せていた頃と同じ「透明な黒から始まる」になる。
    ///
    /// 塗る仕事は投入するだけで待たない。続く投入は GPU 側で順に並ぶ。
    ///
    /// **コマンドを組み立てている最中には呼べない。** 塗るのに自分のコマンドを 1 本
    /// 開くので、開いたまま環を 1 周すると同じ置き場をもう一度開くことになる (検証層が
    /// 止める。層が無ければ未定義)。組み立ての最中に作る面 (効果の控え) は、全画素を
    /// 書く段しか通らないので塗らずに作る (``StageImage``)。
    func makeClearedTexture(descriptor: MTLTextureDescriptor) throws(RenderFailure)
        -> any MTLTexture
    {
        guard slotOfOpenCommands.isEmpty else { throw .commandBufferUnavailable }
        let texture = try makeTexture(descriptor: descriptor)
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        attachment.storeAction = .store
        let commands = try beginCommands()
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw .encoderUnavailable
        }
        encoder.endEncoding()
        commit(commands)
        return texture
    }

    /// CPU から読める領域を確保して常駐させる。
    func makeReadableBuffer(byteCount: Int) throws(RenderFailure) -> any MTLBuffer {
        // **頼む前に上限を見る。** 上限を超える長さをそのまま頼むと、検証層を有効にした
        // 実行 (検査がそうしている) では `nil` ではなく**異常終了**で返ってくる —
        // 「確保に失敗した」として扱えず、そこで走っている検査ごと落ちる
        guard byteCount > 0, byteCount <= device.maxBufferLength else {
            throw .bufferUnavailable(byteCount: byteCount)
        }
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw .bufferUnavailable(byteCount: byteCount)
        }
        makeResident(buffer)
        return buffer
    }

    /// 領域の上にテクスチャを載せるときの、1 行あたりのバイト数。
    ///
    /// 行の先頭が揃っていないとテクスチャを載せられない。**幅を切り上げるのではなく
    /// 行の間隔を広げる**ので、どんな幅でも載せられる — 幅を切り上げると、利用者の
    /// 指定した大きさと描かれる大きさが食い違う。
    /// **揃え方は形式ごとに違う**ので、載せる形式を渡す。既定は作業空間のもの。
    func alignedBytesPerRow(
        _ natural: Int, for pixelFormat: MTLPixelFormat = RenderTarget.pixelFormat
    ) -> Int {
        let alignment = device.minimumLinearTextureAlignment(for: pixelFormat)
        guard alignment > 1 else { return natural }
        return (natural + alignment - 1) / alignment * alignment
    }

    /// CPU から読める領域の上にテクスチャを載せて確保する。
    ///
    /// こうして作ったテクスチャへ描くと、結果は**同じメモリ**に現れる。写しを取らずに
    /// CPU から読めるのはこのためで、統一メモリの機械でしか成立しない ([ADR-0009])。
    ///
    /// **同じメモリでも、常駐は置き場とテクスチャで別々に数えられる。** 置き場を通した
    /// だけでは足りず、載せたテクスチャも通す — 通し忘れると検証レイヤが「どの residency
    /// set にも入っていない」と言う ([#351])。絵は普段どおり出てしまうので、症状からは
    /// 見つからない。
    ///
    /// [ADR-0009]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0009-platform-floor.md
    /// [#351]: https://github.com/mokume-metal/mokume/issues/351
    func makeBufferBackedTexture(
        descriptor: MTLTextureDescriptor, bytesPerRow: Int
    ) throws(RenderFailure) -> (texture: any MTLTexture, storage: any MTLBuffer) {
        let storage = try makeReadableBuffer(byteCount: bytesPerRow * descriptor.height)
        guard
            let texture = storage.makeTexture(
                descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
        else {
            throw .textureUnavailable(width: descriptor.width, height: descriptor.height)
        }
        makeResident(texture)
        return (texture, storage)
    }

    // MARK: - コマンド

    /// コマンドを 1 本組み立て始める。
    ///
    /// 環から次の置き場を取り、**そこへ積んだ前回のコマンドが終わっていなければ待つ**。
    func beginCommands() throws(RenderFailure) -> any MTL4CommandBuffer {
        let index = nextSlot
        nextSlot = (nextSlot + 1) % slots.count

        try waitForSlot(index)
        slots[index].allocator.reset()
        // 終わった番号のぶんは、ここで手放す。settle を 1 度も呼ばない経路 (表示だけを
        // 繰り返す) でも、抱えたものが際限なく溜まらない
        releaseFinished(through: completion.signaledValue)

        guard let commands = device.makeCommandBuffer() else {
            throw .commandBufferUnavailable
        }
        commands.beginCommandBuffer(allocator: slots[index].allocator)
        slotOfOpenCommands[ObjectIdentifier(commands)] = index
        return commands
    }

    /// 指定した置き場から投入したコマンドが終わるまで待つ。
    ///
    /// **#222 の不変条件 (実行中の置き場を巻き戻さない) を守っているのは、この待ち
    /// 1 つだけである。** 待てなければ投げるので、``beginCommands()`` の
    /// `allocator.reset()` へ進めるのは「この置き場へ積んだ投入は終わっている」
    /// ときだけになる。
    ///
    /// **その事後条件を確かめる者は、この型の中には置けない。** 判定に使える合図は
    /// ここが待っているのと同じ `completion` で、この世代には allocator の実行状態を
    /// 別経路で問う口が無いためである。見張りは検査が外から掛ける —
    /// `CommandAllocatorTests` の「置き場を取り直す口は、その置き場を読む投入が
    /// 終わってから巻き戻す」が、置き場を 1 本にして
    /// ``beginCommands()`` を直に呼び、返った時点の ``isIdle`` を見る ([#790])。
    ///
    /// [#790]: https://github.com/mokume-metal/mokume/issues/790
    private func waitForSlot(_ index: Int) throws(RenderFailure) {
        let pending = slots[index].submission
        guard pending > 0, completion.signaledValue < pending else { return }

        slotWaits += 1
        let limit = UInt64(Self.waitLimitSeconds * 1000)
        guard completion.wait(untilSignaledValue: pending, timeoutMS: limit) else {
            Diagnostics.warn(
                "コマンドの置き場が空くのを \(Self.waitLimitSeconds) 秒待っても返りませんでした")
            throw .timedOut(seconds: Self.waitLimitSeconds)
        }
    }

    /// 投入したコマンドがすべて終わるまで待つ。**GPU 可視メモリに触る直前に呼ぶ。**
    ///
    /// 待たない経路も番号を進めているので、最後の番号まで待てば「この GPU に積んだものが
    /// 全部終わった」ことになる。全部終わっていれば何もせずに返るので、呼ぶ側は
    /// 「待つかもしれない」ことだけを知っていればよい。終わった番号ぶんの抱えている
    /// リソースはここで手放す。
    func settle() throws(RenderFailure) {
        settleCalls += 1
        defer { releaseFinished(through: completion.signaledValue) }
        guard submissionCount > 0, completion.signaledValue < submissionCount else { return }

        blockingWaits += 1
        let limit = UInt64(Self.waitLimitSeconds * 1000)
        guard completion.wait(untilSignaledValue: submissionCount, timeoutMS: limit) else {
            // **黙って捨てない。** 詰まったことが分からないと、症状 (絵が止まる・
            // 観測が遅い) から原因へ辿る手がかりが 1 つも残らない
            Diagnostics.warn(
                "GPU の完了を \(Self.waitLimitSeconds) 秒待っても返りませんでした")
            throw .timedOut(seconds: Self.waitLimitSeconds)
        }
    }

    /// 番号 `submission` の投入が終わるまで待つ。**フレームごとに書く置き場の環が使う。**
    ///
    /// ``settle()`` との違いは待つ範囲だけである。あちらは投入済みの**全部**を待ち、
    /// こちらは**名指しした 1 本**を待つ。環にした置き場は「そのスロットを最後に読んだ
    /// 投入」さえ終わっていれば CPU が書いてよいので、その先に積まれた新しいフレームの
    /// 仕事まで待つ理由が無い ([#754])。
    ///
    /// **緩めてよいのは環にした置き場だけである。** 環にしていない置き場 (粒・数の
    /// 並び・画像・字形の面) は今までどおり ``settle()`` で全完了を待つ — どのスロットに
    /// 属するかを名乗れないものは、いつ読まれ終わるかも名乗れない。
    ///
    /// [#754]: https://github.com/mokume-metal/mokume/issues/754
    func waitForSubmission(_ submission: UInt64) throws(RenderFailure) {
        // 終わった番号ぶんの抱えているリソースは、待ちの有無によらずここで手放す。
        // 描き切りが settle を通らなくなったので、手放す契機をこちらにも置く
        defer { releaseFinished(through: completion.signaledValue) }
        guard submission > 0, completion.signaledValue < submission else { return }

        ringWaits += 1
        let limit = UInt64(Self.waitLimitSeconds * 1000)
        guard completion.wait(untilSignaledValue: submission, timeoutMS: limit) else {
            Diagnostics.warn(
                "フレームの置き場が空くのを \(Self.waitLimitSeconds) 秒待っても返りませんでした")
            throw .timedOut(seconds: Self.waitLimitSeconds)
        }
    }

    /// 投げられない口のための ``settle()``。詰まっていたら理由を残して進む。
    ///
    /// フレームごとに呼ばれる口は投げない ([ADR-0020] 決定 5) ので、そこから待つときは
    /// この形を使う。5 秒返らない GPU は壊れているので、ここで凝らない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func settleQuietly(before what: String) {
        do {
            try settle()
        } catch {
            Diagnostics.warn("\(what)の前に GPU の完了を待てませんでした: \(error.headline)")
        }
    }

    /// 番号 `finished` までの投入が終わったときの後片付け。
    ///
    /// **2 つを 1 か所で行う** — 終わるまで抱えていたリソースを手放すことと、持ち主が
    /// 死んだリソースを常駐から外すこと ([#738])。契機が同じ (「番号 n まで終わった」) なので、
    /// 呼ぶ場所を分けると片方だけを呼ぶ経路ができる。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    private func releaseFinished(through finished: UInt64) {
        if let last = held.lastIndex(where: { $0.submission <= finished }) {
            held.removeSubrange(...last)
        }
        guard let last = retired.lastIndex(where: { $0.submission <= finished }) else { return }
        for entry in retired[...last] { residencySet.removeAllocation(entry.allocation) }
        residencySet.commit()
        retired.removeSubrange(...last)
    }

    /// 直前に投入した番号を GPU 側で待つ命令を積む。
    ///
    /// この世代は別々に投入したコマンドの間の順序を自動では保証しない。CPU が毎回
    /// 待っていた間はそれで偶然成り立っていたが、待たなくなると「前のフレームが描画先を
    /// 読み終える前に次のフレームが消す」が起きうる。投入の直前にこれを積めば、GPU 上の
    /// 順序が投入順のまま保たれる。
    private func orderAfterPreviousSubmission() {
        guard submissionCount > 0 else { return }
        queue.waitForEvent(completion, value: submissionCount)
    }

    /// 投入に番号を振り、合図を出し、置き場へ書き戻す。
    ///
    /// **待つ経路も待たない経路も必ずここを通す。** 通さない経路があると、その置き場は
    /// 「終わったかどうか分からないまま巻き戻してよい」ことになってしまう。
    @discardableResult
    private func recordSubmission(of commands: any MTL4CommandBuffer) -> UInt64 {
        submissionCount += 1
        queue.signalEvent(completion, value: submissionCount)
        if let index = slotOfOpenCommands.removeValue(forKey: ObjectIdentifier(commands)) {
            slots[index].submission = submissionCount
        }
        return submissionCount
    }

    /// 組み立てたコマンドを投入する。**GPU の完了を待たない。**
    ///
    /// フレームを回す経路はこれで投入し、次に GPU 可視メモリへ触る直前に ``settle()``
    /// で待つ。その間の CPU の仕事 (次のフレームの頂点組み立て) が GPU と重なる。
    ///
    /// - Parameter resources: このコマンドが読むもののうち、投入した側がすぐ手放す参照。
    ///   終わるまでこの型が抱える。
    /// - Returns: 振った番号。
    @discardableResult
    func commit(_ commands: any MTL4CommandBuffer, retaining resources: [AnyObject] = []) -> UInt64 {
        commands.endCommandBuffer()
        orderAfterPreviousSubmission()
        queue.commit([commands])
        let submission = recordSubmission(of: commands)
        // **投入した本体も、終わるまで抱える。** 記録の実体は置き場 (allocator) にあるが、
        // 本体の寿命を GPU の実行より短くしない — 投入した側は直後に手放すので、
        // ここで抱えなければ実行中に消える
        held.append((submission, resources + [commands]))
        return submission
    }

    /// 組み立てたコマンドを投入し、GPU が終わるまで待つ。
    ///
    /// ``commit(_:retaining:)`` と ``settle()`` の合成。1 枚だけ描く経路と、読み戻すために
    /// その場で結果が要る経路のための形。
    func commitAndWait(_ commands: any MTL4CommandBuffer) throws(RenderFailure) {
        commit(commands)
        try settle()
    }
}

extension RenderDevice {
    /// 同梱したシェーダを読み込む。
    ///
    /// シェーダの原文は資源として運ばれ、ここで組み立てる — この道具立てでは原文を
    /// ビルドに含める手がないため。**原文の誤りはここまで来ないと分からない**ので、
    /// `make ci-check` が別途ビルド時に組み立てて落とす (`scripts/check-shaders.sh`)。
    func makeLibrary(named name: String) throws(RenderFailure) -> any MTLLibrary {
        let source = try bundledShaderSource(named: name)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: "\(name).metal", reason: error.localizedDescription)
        }
    }

    /// 図形を塗る断片を、共通部分を前置きしてから組み立てる。
    ///
    /// **前置きは無条件。** 断片が既に宣言を持っているかは見ない (ShaderSource を参照)。
    func makeShapeLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try bundledShaderSource(named: "Common")
        let source = ShaderSource.assemble(
            common: common, values: values, surfaces: surfaces, body: body)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: name, reason: error.localizedDescription)
        }
    }

    /// 計算の断片を、共通部分を前置きしてから組み立てる。
    ///
    /// **前置きは無条件** (塗りと同じ理由 — ShaderSource を参照)。塗りと違って入口の
    /// 関数は用意せず、束ねる先の宣言ごと利用者が書く。
    func makeComputeLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try bundledShaderSource(named: "Compute")
        let source = ShaderSource.assemble(common: common, values: values, body: body)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(name: name, reason: error.localizedDescription)
        }
    }

    /// 効果の断片を、前置きと合わせて組み立てる。
    func makeEffectLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try bundledShaderSource(named: "Effect")
        let source = ShaderSource.assemble(common: common, values: values, body: body)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(name: name, reason: error.localizedDescription)
        }
    }

    /// 同梱している断片を読む。
    ///
    /// **探すのは [ModuleResources] に任せる。** 道具立ての口だけを使うと、包みに入れて
    /// 配ったときに組み上げた機械の絶対パスへ落ちる ([ADR-0029] 決定 4)。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    func bundledShaderSource(named name: String) throws(RenderFailure) -> String {
        guard let url = ModuleResources.url(forResource: name, withExtension: "metal"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .shaderSourceMissing(name: "\(name).metal")
        }
        return source
    }
}

extension RenderDevice {
    /// 表示に使う面が空くのを待つよう予約する。差し出す面へ書く前に呼ぶ。
    func waitForDrawable(_ drawable: any MTLDrawable) {
        queue.waitForDrawable(drawable)
    }

    /// 組み立てたコマンドを投入し、**GPU の完了を待たずに**表示の合図を出す。
    ///
    /// 待たないのは、待てば表示のたびに CPU が止まり、フレームレートが GPU の
    /// 往復に縛られるため。差し出す面の同期は Metal 側の合図で足りる。
    ///
    /// **待たなくても番号は進める。** 進めないと、この経路で使った置き場だけが
    /// 「いつ終わったか分からない」まま環へ戻り、次の巻き戻しが実行中のコマンドを
    /// 踏む ([#222](https://github.com/mokume-metal/mokume/issues/222))。
    func commit(_ commands: any MTL4CommandBuffer, signalling drawable: any MTLDrawable) {
        commands.endCommandBuffer()
        orderAfterPreviousSubmission()
        queue.commit([commands])
        let submission = recordSubmission(of: commands)
        held.append((submission, [commands]))
        queue.signalDrawable(drawable)
    }
}
