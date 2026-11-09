// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

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
    /// 名乗る口。**検査から差し替える** (bootstrap と手元の目録に触らずに数えるため)。
    var announce: (_ identity: String, _ share: FrameShare) -> FrameAnnouncement?
    /// 名乗っている項目。名乗っていなければ `nil`。
    private(set) var announcement: FrameAnnouncement?

    init(
        identity: String,
        announce: @escaping (String, FrameShare) -> FrameAnnouncement? = { identity, share in
            FrameAnnouncement.announce(sketch: share.sketch, identity: identity, title: share.title)
        }
    ) {
        self.identity = identity
        self.announce = announce
    }

    /// 映す世代の絵から名乗りの中身を読んだ。`nil` は断っている。
    func follow(_ share: FrameShare?) {
        // 倒れた子は共有面に書かないので、ここへ来るのは共有面へ戻った世代の絵だけである
        guard let share else {
            withdraw()
            return
        }
        if let announcement {
            announcement.update(sketch: share.sketch, title: share.title)
        } else {
            announcement = announce(identity, share)
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
