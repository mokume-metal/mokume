// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 弱く持つ入れ物。**手放されたものは、ここから自然に居なくなる。**
///
/// 使うのは「作ったものを後から見に行きたいが、生かしておきたくはない」控えである
/// (``Canvas`` が観測へ失敗を載せるために持つ断片と計算)。強く持つと、利用者が
/// 手放したものまで面と同じ寿命になり、GPU 側の置き場ごと解放されない
/// ([#738](https://github.com/mokume-metal/mokume/issues/738))。
///
/// 入れ物そのものは残るので、足す側が死んだ入れ物を落とす (``Canvas``)。
struct Weak<T: AnyObject> {
    weak var value: T?

    init(_ value: T) { self.value = value }
}
