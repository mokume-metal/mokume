<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

絵を返す・書き出す口 (`RenderTarget.readPixels()`・`encodeForDisplay(scale:)`・`writePNG(to:)`・`SketchRuntime.renderFrame(to:)`) が、GPU が仕事を打ち切って仕上げなかった絵を、正常な結果として返さなくなりました ([#1932](https://github.com/mokume-metal/mokume/issues/1932))。

これまでは、GPU が描画や読み戻しを打ち切っても (hang・page fault・他の仕事の巻き添えなど)、待ちさえ成り立てば前の絵や描きかけの絵がそのまま返り、PNG にも書き出されていました。打ち切りを知る手がかりは、標準エラーに最初の 1 回だけ出る警告だけでした。検査では、比べる絵の描画が打ち切られると前の絵が残り、黙って緑になることがありました。

これからは、返す絵が拠った投入 (同じ面で前にこれらの口が読んだ後に、同じ `RenderDevice` へ積まれた仕事すべて) のどれかが打ち切られていれば、GPU から結末が届くのを待ってから `RenderFailure.workDropped(reason:)` を投げます。1 行目に Metal が名乗った理由が載り、ファイルは書きません。読み戻し・出力段だけが打ち切られたときは、次の呼び出しがやり直します。描画が打ち切られたときは、次に何か描くまで同じ理由で投げ続けます。`workDropped` の文面の 1 行目も、待ちが終わらなかったとは言い切らない形 (`… so the picture was never finished: <理由>`) に変わりました。

毎フレーム読む口 (`pixels`・`loadPixels()`・`get`・`save()`・録画・観測) は今までどおり投げません。

移行: これらの口を `try` で呼んでいるコードは、これまで待ちの期限切れのときにだけ届いていた `RenderFailure.workDropped(reason:)` を、待ちが成り立った後にも受け取るようになります。失敗をまとめて扱っているなら変更は要りません。`.workDropped` を「待ちが終わらなかった」として名指しで扱っているなら、絵が仕上がらなかった場合として扱ってください。打ち切りの後に絵を取り直すなら、描き直してから読みます。
