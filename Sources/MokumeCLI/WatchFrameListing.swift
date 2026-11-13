// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Metal
import MokumeCore
import MokumeDiagnostics

/// 見張りの下で、道具が作品のウィンドウの持ち主として目録へ名乗る ([ADR-0049] 決定 2・[#3919])。
///
/// **名乗るのは道具で、子は名乗らない。** 保存のたびに子が入れ替わっても、受け手は繋ぎ直さずに済む — 目録の項目と
/// bootstrap の名前は、見張りが続く間変わらない。作品名と題は、作品のウィンドウが映す世代の子が共有面に載せた
/// 値 (``SharedFrameSurface/FrameShare``) を写す。
///
/// | 起きたこと | 名乗り |
/// | --- | --- |
/// | 映す世代の絵に名乗りの中身が載っている | 名乗る (名乗っていれば、作品名と題だけ書き換える) |
/// | 載っていない (断った・古いライブラリの子) | 下ろす |
/// | 子が自分のウィンドウへ倒れた | 下ろす (倒れた子が自分で名乗る)。次に映す世代の絵が届けば、また従う |
/// | 見張りが終わる | 下ろす |
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3919]: https://github.com/mokume-metal/mokume/issues/3919
final class WatchFrameListing {
    /// 作品を見分ける欄 (見張っているパッケージの場所)。
    let identity: String
    /// 名乗る口。**検査から差し替える** (bootstrap と手元の目録に触らずに数えるため)。幅と高さは分からなければ `nil`。
    var announce: (_ identity: String, _ share: FrameShare, _ width: Int?, _ height: Int?) -> FrameAnnouncement?
    /// 名乗っている項目。名乗っていなければ `nil`。
    private(set) var announcement: FrameAnnouncement?
    /// 子の面から受け手の面へ写す GPU (作品のウィンドウの台のもの)。`nil` なら受け手へ渡さない (検査)。
    private let gpu: RenderDevice?
    /// 受け手へ渡すフレームの番号。**道具が数える** — 保存で子が入れ替わっても途切れない ([#3920])。
    ///
    /// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
    private(set) var frameCount: Int64 = 0
    /// 写せなかったことを言ったか。毎フレーム同じ 1 行を流さない。
    private var saidCopyFailure = false
    /// 繋がった・切れたことを人へ 1 行言う口 (端末)。**既定は診断の 1 行**で、見張りは端末の行 (`say`) を渡す (#3921)。
    var say: (String) -> Void = { Diagnostics.warn($0) }
    /// 繋がっている相手の名前が変わったときの知らせ。見張りはプレビューの題に出す (ADR-0049 決定 6・#3921)。
    var onReceiversChanged: (([String]) -> Void)?
    /// 台が読んだ名乗りの中身のうち、同じリフレッシュの絵 (``attach(to:)``) を待っているもの。外側の `nil` は読んでいない。
    private var unfollowed: FrameShare??

    init(
        identity: String, gpu: RenderDevice? = nil,
        announce: @escaping (String, FrameShare, Int?, Int?) -> FrameAnnouncement? = { identity, share, width, height in
            FrameAnnouncement.announce(
                sketch: share.sketch, identity: identity, title: share.title, width: width, height: height)
        }
    ) {
        self.identity = identity
        self.gpu = gpu
        self.announce = announce
    }

    /// 作品のウィンドウの台の知らせに繋ぐ。**作品のウィンドウが映す世代に従う** ([ADR-0049] 決定 2) — プレビューは
    /// 試聴の子を映すことがあるので繋がない。検査も同じ口で繋ぐ。**ウィンドウが名乗りを持つ** (名乗りはウィンドウを
    /// 持たないので環にならない)。
    ///
    /// **名乗りの中身には、同じリフレッシュの絵の大きさを添えて従う** (#3949)。台は中身を読んだ直後に、同じ絵を
    /// ``SharedFrameWindow/onFrame`` で渡す。中身を読んだ時点で名乗ると、寸法の無い項目が一瞬目録に載り、その間に読んだ
    /// 受け手は旧い送り手と取り違える。
    func attach(to window: SharedFrameWindow) {
        window.onFrameShareRead = { share in self.unfollowed = .some(share) }
        window.onFrame = { texture, isNew in
            if let share = self.unfollowed {
                self.unfollowed = nil
                self.follow(share, width: texture?.width, height: texture?.height)
            }
            self.handOver(texture, isNew: isNew)
        }
    }

    /// 作品のウィンドウが映す世代のいまの絵を、繋いできた受け手の面へ写す ([ADR-0049] 決定 2・[#3920])。
    /// **リフレッシュごとに呼ぶ** ([#3945])。番号を進めるのは新しい絵のときだけで、受け手ごとに同じ番号の絵は
    /// 写し直さない (後から繋いだ受け手には今の 1 枚を写す)。写した絵の GPU の完了は、絵が無くても毎回見て知らせる。
    /// 名乗っていなければ何もしない。受け手の頼みは、名乗った後の最初の絵から受け始める。
    ///
    /// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
    /// [#3945]: https://github.com/mokume-metal/mokume/issues/3945
    func handOver(_ texture: (any MTLTexture)?, isNew: Bool) {
        guard let announcement, let gpu else { return }
        guard let texture else {
            announcement.sender?.announceCompleted()
            return
        }
        let fresh = announcement.sender == nil
        guard let sender = announcement.startSending(gpu: gpu, width: texture.width, height: texture.height)
        else { return }
        if fresh {
            sender.warn = { [weak self] line in self?.say(line) }
            sender.onReceiversChanged = { [weak self] names in self?.onReceiversChanged?(names) }
        }
        // 名乗るのは台が新しい絵から名乗りの中身を読んだ回 (``follow(_:)``) で、同じリフレッシュの絵は新しいと
        // 知らされる。だから名乗った後の最初の絵は必ず番号を進める (0 を渡さない)
        if isNew { frameCount += 1 }
        do {
            try sender.deliver(copying: texture, frameCount: frameCount, hostTime: mach_absolute_time())
            saidCopyFailure = false
        } catch {
            guard !saidCopyFailure else { return }
            saidCopyFailure = true
            Diagnostics.warn("Could not hand this frame to the apps receiving it: \(error)")
        }
    }

    /// 映す世代の絵から名乗りの中身を読んだ。`nil` は断っている。
    ///
    /// - Parameters:
    ///   - width: その絵の幅 (受け手の面の大きさ)。分かれば目録に載せる (#3949)。送り手を起こした後は、送り手の大きさが
    ///     変わるたびに名乗りが書き換える (``FrameAnnouncement/startSending(gpu:width:height:startsListening:)``)。
    ///   - height: 同じく高さ。
    func follow(_ share: FrameShare?, width: Int? = nil, height: Int? = nil) {
        // 倒れた子は共有面に書かないので、ここへ来るのは共有面へ戻った世代の絵だけである
        guard let share else {
            withdraw()
            return
        }
        if let announcement {
            announcement.update(sketch: share.sketch, title: share.title)
            if let width, let height { announcement.recordSize(width: width, height: height) }
        } else {
            announcement = announce(identity, share, width, height)
        }
    }

    /// 子が自分のウィンドウへ倒れた。**倒れた子が自分で名乗るので、道具は下ろす** (名乗りが 2 つ出ない)。
    func fellBack() {
        withdraw()
    }

    /// 下ろす。名乗っていなければ何もしない。
    func withdraw() {
        announcement?.withdraw()
        announcement = nil
    }
}
