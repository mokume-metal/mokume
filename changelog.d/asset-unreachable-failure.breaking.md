<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

資材の名前を探す口は、候補の場所の親のフォルダに入れず**在るかを確かめられない**とき、「見つからない」と言って資源の宣言を確かめるよう勧めるのをやめ、そこで探すのを止めて、入れなかった場所と OS の事情を名乗るようになりました ([#2838](https://github.com/mokume-metal/mokume/issues/2838))。以前は、`assets` に入る権利を外す (`chmod 000 assets`) と、その下に置いたファイルが在っても `AssetFailure.notFound` (「資源の宣言を確かめよ」) になり、置いたファイルを探させる的外れな助言が出ていました。入れない親の下では、在るファイルと無いファイルの区別が付きません。

公開の `AssetFailure` に `unreachable(path:location:reason:)` を足しました。`assetURL(_:)` が投げます。`location` には確かめられなかった場所、`reason` には OS が名乗った事情 (`Permission denied`・symlink が巡る・宛先の無い symlink) が入ります。文面は `"assets/notes.txt" cannot be reached at "/Users/me/sketch/assets/notes.txt": cannot tell whether it exists (Permission denied)` の形で、「見つかった」とは言いません。`loadTable`・`loadStrings` などの文字のファイルを読む口と、画像・モデル・断片・音・動画を読む口は、それぞれの型の `unopenable(path:location:reason:)` で名乗ります (形は変えず、`reason` が `cannot tell whether it exists (…)` で始まります)。本当に無いときは、今までどおり `notFound` と探した場所の一覧です。

**入れない候補に当たったら、後ろの候補に本物があっても採りません。** 入れない場所は在るかもしれない場所で、黙って飛ばすと原因に辿り着けないためです。宛先の無い symlink も、無いものとは数えず、辿り着けないものとして名乗ります (以前は無いものとして次の候補へ進んでいました)。

移行: `AssetFailure` を `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .unreachable(let path, let location, let reason):` の枝を足してください。直す先を示すなら、渡した名前 (`path`) ではなく確かめられなかった場所 (`location`) を使います。`notFound` の枝で「資源の宣言を確かめよ」と案内していたなら、入れない場所の権利を直すという案内は新しい枝へ移します。失敗をまとめて扱っている (`catch` で受けて `description` を出す、`try?` で受ける、など) なら、コードの変更は要りません。
