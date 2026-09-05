// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 名前の付いた 1 つの値 (`{"name", "type", "value"}`)。
///
/// この形は 3 か所に出る — 外から置かれる要求 (``ParamRequest``)、道具が書く要求
/// (``RemoteParams``)、続きを返す保存 (``ParamStore/Saved``)。**3 つとも同じ 1 つの
/// 書き方と読み方を使う。**
///
/// ## なぜ 1 つにするか
///
/// かつては 3 か所が別々に書いていた。片方は `name` を先に書き、片方は値を先に書いて
/// から `name` を足し (順序に依存していた)、片方は型の綴りを手で `encode` していた。
/// ``ParamValue`` にケースを足したとき 3 か所とも直る保証が無く、**割れても
/// コンパイルは通り、書いたものを自分で読めなくなるだけ**だった
/// ([#803](https://github.com/mokume-metal/mokume/issues/803)・
/// [ADR-0008](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 6)。
///
/// 型と値は ``ParamValue`` に任せる — 名乗り方を知っているのはあちらだけにする。
struct NamedParamValue: Codable, Equatable {
    let name: String
    let value: ParamValue

    init(name: String, value: ParamValue) {
        self.name = name
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case name
    }

    /// 型と値は 1 つの組として読む (`{"type", "value"}`)。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try ParamValue(from: decoder)
    }

    /// **`name` を先に書く。** 値の書き方に踏み込まないので、``ParamValue`` の
    /// ケースが増えてもここは動かない。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try value.encode(to: encoder)
    }
}
