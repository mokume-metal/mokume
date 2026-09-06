// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 続けて失敗した数を数え、**始まりと終わりだけ**言わせる。
///
/// 握り潰すと「絵が止まったのに理由がどこにも残らない」になる — 観測だけが黙ったように
/// 見える形の調査で、いちばん最初に欲しい 1 行がここだった
/// ([#221](https://github.com/mokume-metal/mokume/issues/221))。一方で毎フレーム言えば
/// 1 秒に 60 行流れ、本当に読むべき行が埋まる。
///
/// ## 言葉は持たない
///
/// 畳んだのは数え方だけで、**文面は呼び出し側にリテラルのまま残してある**。
///
/// 割れたときに黙って壊れるのは「回復したら 0 へ戻す」ほうである — 落とすと以後 1 度も
/// 言わなくなり、症状は #221 が塞いだ穴そのものに戻る。文面のほうは違う。
/// `Diagnostics.warn` は標準エラーへ直に書いて控えを持たないので、**畳んで壊しても
/// 確かめる手段が無い**。フレームの外での置き直しを知らせる 7 本
/// ([#953](https://github.com/mokume-metal/mokume/pull/953)) を文面ごと畳めたのは、
/// あちらが `WarningLog` に文面を控えていて検査が原文と突き合わせられたからである。
///
/// 組み立てた文が壊れるのは実際に起きている — その 7 本を畳んだとき、動詞の語幹から
/// 組んだせいで「頼んだ」が「頼んた」になった
/// ([#947](https://github.com/mokume-metal/mokume/issues/947))。
struct FrameFailureLog {
    private var consecutive = 0

    /// 1 つ数える。**言うべきなら `true`** — 続きの失敗では `false` を返す。
    mutating func note() -> Bool {
        consecutive += 1
        return consecutive == 1
    }

    /// 回復した。**言うべきなら飛ばした枚数**、言うことが無ければ `nil`。
    mutating func recovered() -> Int? {
        guard consecutive > 0 else { return nil }
        defer { consecutive = 0 }
        return consecutive
    }
}
