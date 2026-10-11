<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

文字のファイルを読む口 (`loadStrings`・`loadTable`・`loadJSONObject`・`loadXML`・`loadShape` と、待たない版の `requestStrings`・`requestTable`・`requestJSONObject`・`requestXML`・`requestShape`) は、名前の指す先が**ディレクトリだったときと、読む権利の無いファイルだったとき**に、新しい `DataFailure.unopenable(path:location:reason:)` で投げるようになりました ([#2341](https://github.com/mokume-metal/mokume/issues/2341))。`location` には名前が解けた場所、`reason` には OS が名乗った事情 (`Is a directory`・`Permission denied`) が入ります。文面は `"data.csv" was found at "/Users/me/sketch/data.csv" but cannot be opened: Is a directory` の形で、相対の名前でも、どこにあるものを直せばよいかが分かります (名前が解けた場所と同じなら `at …` は省きます)。

これまでは、どちらも `DataFailure.unreadable(path:)` で投げ、文面は `… cannot be read as UTF-8 text. Check that the file is saved as UTF-8` でした。中身の文字の符号化とは関係の無い失敗なのに、UTF-8 で保存し直すという的外れな手を勧めていました。`unreadable` は今後、開けた中身が UTF-8 の文字でないときだけ投げます。

移行: `DataFailure` を `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .unopenable(let path, let location, let reason):` の枝を足してください。直す先を示すなら、渡した名前 (`path`) ではなく解けた場所 (`location`) を使います。ディレクトリや読む権利の無いファイルを `.unreadable` の枝で受けていたなら、その扱いを新しい枝へ移します。失敗をまとめて扱っている (`catch` で受けて `description` を出す、など) なら、コードの変更は要りません。
