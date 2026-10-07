// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal

extension RenderTarget {

    // MARK: - 面に描かずに取り出す

    /// 出力段を通した絵を、**面に描かずに** 1 枚のテクスチャとして取り出す。
    ///
    /// [ADR-0024] 決定 6 の言う「取り出す道」である。画面へ差し出す経路は面の大きさへ
    /// 収めて帯を足すので、そこからは「絵そのもの」を取り出せない。毎フレーム絵を
    /// 受け取る出口はここから受け取る。
    ///
    /// **頼まれるまで 1 パスも積まない。** 出口が 1 つも無いスケッチは、この経路の
    /// 存在を一切払わない。
    ///
    /// 返るのは**使い回している 1 枚**なので、次に取り出すと中身が書き換わる
    /// ([ADR-0023] 決定 5)。持ち帰って後で読む用途には ``EncodedImage/read()`` で
    /// 値にしてから渡す。
    ///
    /// **GPU の完了を待たずに返る** ([#927])。返った時点で絵はまだ組み上がっていない
    /// ことがあり、待つのは中身に触る側である — ``EncodedImage/read()`` と、出口へ渡す
    /// 直前の ``SketchRuntime``。かつてはここで投入済みの全部を待っており、出口が 1 本
    /// でも刺さっていると毎フレーム CPU が GPU に追いついてしまっていた。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    func encodeToImage() throws(RenderFailure) -> EncodedImage {
        try encode { () throws(RenderFailure) in
            encodePassCount += 1
            if let encodedStorage { return encodedStorage }
            let image = try EncodedImage(gpu: gpu, width: width, height: height)
            encodedStorage = image
            encodedImagesMade += 1
            return image
        }
    }

    /// 出口へ渡すのと同じ道で組み、**GPU が仕上げたかを判定してから**読む。
    /// `SketchRuntime.renderFrame(to:)` の口 ([#1932])。
    ///
    /// 観測の撮影 (`SketchRuntime` の `continueCapture`) も通る。撮影は投げずに、失敗を目録の
    /// `complete: false` と警告で伝える (ADR-0018 決定 3)。
    ///
    /// 判定と範囲は ``encodeForDisplay(scale:)`` と同じで、打ち切りがあれば
    /// ``RenderFailure/workDropped(reason:)`` を投げる。出口へ渡す ``encodeToImage()`` そのものは
    /// 投げない (毎フレーム走る口なので・[ADR-0020] 決定 5)。
    ///
    /// - Parameter scale: 縮小率 (``EncodedImage/read(scaledBy:)`` と同じ。1 = 実寸)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    func encodeToImageAndRead(scaledBy scale: Double = 1) throws(RenderFailure) -> DisplayImage {
        try refuseHeldDrop()
        let image = try encodeToImage()
        // 出力段は最後に積んだ 1 本なので、名指しで待てば範囲の投入はすべて終わっている (#927)
        try gpu.waitForSubmission(image.pendingSubmission)
        try judgeDroppedWork()
        return image.read(scaledBy: scale)
    }

    /// 出力段を通した絵を、`storage` が渡す置き場へ組む。**待たずに投入して返る** (#927)。
    ///
    /// 出口へ渡す ``encodeToImage()`` と、同期で読む ``encodeForDisplay(scale:)`` が通る。
    /// 2 つは置き場だけが違い、道は同じ 1 本である ([ADR-0024] 決定 6)。置き場を受け取るのは
    /// 前の出力段を待ち終えてからで、待てずに投げたときは置き場を作らず、数えもしない。
    ///
    /// **書き戻したときだけ、この面へ書く投入として投入する** ([#1932])。出力段そのものは面を
    /// 読むだけで、面の中身を変えない。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    private func encode(
        into storage: () throws(RenderFailure) -> EncodedImage
    ) throws(RenderFailure) -> EncodedImage {
        // **前の出力段が終わるのを、ここで待つ。** この後の `setBrightness` が GPU 可視の
        // 置き場へ CPU で書くので、前の出力段が読んでいる最中には書けない。待つのは
        // 名指しした 1 本だけで、出口へ渡す経路では既に待ち済みなので何も起きない (#927)
        try gpu.waitForSubmission(lastEncodeSubmission)
        try catchUpWithDrawnPicture()
        let image = try storage()

        let pass: OutputPass
        if let outputPassStorage {
            pass = outputPassStorage
        } else {
            pass = try OutputPass(gpu: gpu)
            outputPassStorage = pass
        }

        pass.setSource(texture)
        // 明るさを写す段は**描画先が持つ**。画面へ差し出す経路と同じ設定が効く
        pass.setBrightness(brightness)

        // **書き戻すのは、この面を描く先に持つ面に任せる** ([#1524])。効果を通したフレームの後、
        // 止まっている間に書いた画素は、描く先と同時に効果を通す前の絵 (次のフレームの入り) にも
        // 写す要がある。任せるのは細かさ 1 の面だけである — 細かさを下げた面の出す先には、画素の
        // 書き込みが来ない (描く先への書き込みは、上の追い付き (``Canvas/catchUpOutput()``) が書き戻す)
        //
        // [#1524]: https://github.com/mokume-metal/mokume/issues/1524
        let keeper = drawer?.target === self ? drawer : nil
        // **書き戻す前に、この面を出す先に持つ描き場所を置いた側へ、置いた時点の絵を写させる**
        // ([#1942]・``Canvas/settlePlacersBeforeChange()``)。書き戻しは描き切りを通らずに出す先を
        // 書くので、描き切りの頭の関所を通らない。書き込み待ちが無ければ何も書かないので、通さない。
        // **コマンドを開く前に通す** — 置いた側の描き切り (写せないときの代わり) が、この出力段の
        // コマンドの組み立ての中に入らない
        //
        // [#1942]: https://github.com/mokume-metal/mokume/issues/1942
        if hasPendingPixelWrites { drawer?.settlePlacersBeforeChange() }
        let assembled = try gpu.withCommands { commands throws(RenderFailure) in
            // **CPU が画素へ書いたものがあれば、読む前に描画先へ戻す。** 描き切りを挟まずに
            // `pixels` へ書いてここへ来る経路 (フレームの外で書いて書き出す) のため (#753)
            let wroteBack: Bool
            if let keeper {
                wroteBack = try keeper.encodePixelWriteBackKeepingCarry(into: commands)
            } else {
                wroteBack = try encodePixelWriteBack(into: commands)
            }
            guard
                let encoder = commands.makeRenderCommandEncoder(descriptor: image.makeRenderPass())
            else {
                throw .encoderUnavailable
            }
            // **描き終えた絵を読むので、前の書き込み (描画と、直前の書き戻し) が終わるのを
            // 待つ。** この世代のコマンド構造は口をまたぐ依存を自動では張らない ([#341])
            //
            // [#341]: https://github.com/mokume-metal/mokume/issues/341
            encoder.barrier(
                afterQueueStages: [.fragment, .blit], beforeStages: .fragment,
                visibilityOptions: .device)
            encoder.setRenderPipelineState(pass.state)
            encoder.setViewport(
                MTLViewport(
                    originX: 0, originY: 0, width: Double(width), height: Double(height),
                    znear: 0, zfar: 1))
            encoder.setArgumentTable(pass.argumentTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            // **待たずに投入し、番号を憶える。** 中身が確定しているかを気にするのは触る側で、
            // ``EncodedImage/read()`` と出口へ渡す直前がその番号を名指しで待つ (#927)
            let submission = gpu.commit(
                commands, retaining: [image], writing: wroteBack ? [self] : [])
            return (submission: submission, wroteBack: wroteBack)
        }
        let submission = assembled.submission
        // **戻したことにするのは投入の後** (#1183)。組み立ての途中で投げると書き戻しは
        // 捨てられるので、次に触る段がもう一度積む (控えへの写しも、同じコマンドごと捨てられる)
        if assembled.wroteBack { markPixelsWrittenBack(by: submission) }
        image.pendingSubmission = submission
        lastEncodeSubmission = submission
        return image
    }

    // MARK: - 出す先を読む前の追い付き

    /// 読む前に、この面が**細かさを下げた面の出す先**なら、止まっている間に変わった描く先を広げ直す
    /// ([#1882])。
    ///
    /// 出す先を読む口 (出力段の ``encodeToImage()``・同期で読む ``encodeForDisplay(scale:)``・
    /// ``writePNG(to:)``・``readPixels()``) は、頭でここを通る。**止まっている間のコールバックを
    /// 配った直後にも、ランタイムが同じ追い付きを済ませる** (`SketchRuntime.advance()`) ので、
    /// 窓や共有の面のように出す先のテクスチャを直に読む口も同じ 1 枚を受け取る。ここが残るのは、
    /// コールバックの中で `save()` する形 (配っている最中の出力) と、面を直に回す使い方のためで、
    /// どちらも変わっていなければ何も積まない。細かさ 1 の面は描く先が出す先そのものなので通らない。
    ///
    /// **描き場所に面を置く口** (`image(canvas)`・`texture(canvas)`・断片の面) も配っている最中に
    /// 出す先を読むが、ここは通らない。置いた時点で、置く口の記録 (``Canvas/note(placing:)``) が
    /// 書き戻さずに広げ直す (``Canvas/catchUpOutputForPlacing(by:)``・[#2042]) — 置くのは描き切れて
    /// いる絵で、書いただけの画素は細かさ 1 の面でも出ないからである。
    ///
    /// **出す先を読む口の登録簿は、原文を読む検査 (`StoppedUpscaleOutletReadersTests`) が持つ** ([#2104])。
    /// 出す先を読む行はどれも、ここ (読む口)・置く口の記録・ランタイムの配った後・わざと古い、の
    /// どれで追い付くかを名乗る。出す先を書く側の関所 (``Canvas/settlePlacersBeforeChange()`` と、
    /// 最下層の検算 ``assertPlacersSettledBeforeWriting()``) と対になる読む側の守りで、読む口を足す
    /// ときは頭でここを通し、一覧に名乗りごと足す。
    ///
    /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    /// [#2104]: https://github.com/mokume-metal/mokume/issues/2104
    func catchUpWithDrawnPicture() throws(RenderFailure) {
        guard let drawer, drawer.target !== self, drawer.needsOutputEnlargement else { return }
        try drawer.catchUpOutput()
    }

    // MARK: - 読み戻す

    /// いまの内容を表示できる形へ変換して返す。**変換が終わってから返る。**
    ///
    /// **出口が受け取るのと同じ GPU の出力段を通す** ([#1752])。かつては全画素を読み戻して
    /// CPU で変換しており (`OutputStage.encode(_:)`)、4K では読み戻しと画素ごとの伝達関数が
    /// 費用の大半だった。出るバイト列は CPU の変換と全入力で同じである ([#1762] で揃えた。
    /// 検査は CPU の変換を独立した参照として残して突き合わせる)。
    ///
    /// **置き場は出口へ渡す絵とは別の 1 枚である。** 出口へ渡す絵は次のフレームの頭まで
    /// 控えられている (#927) ので、合間にここを呼んでも控えの中身を書き換えない。こちらの
    /// 1 枚も頼まれて初めて作り、以後は使い回す ([ADR-0023] 決定 5)。
    ///
    /// **待てなければ投げる。** 待ち口は全画素を読み戻していたときと同じ `RenderDevice.settle()`
    /// で、期限を越えれば ``RenderFailure/timedOut(seconds:)`` (直近の結末が打ち切りなら
    /// ``RenderFailure/workDropped(reason:)``) を投げる。出力段は最後に投入した 1 本なので、全部を
    /// 待っても待つ量は名指しで待つのと変わらない。
    ///
    /// **GPU が仕上げなかった絵は返さない** ([#1932])。待ちが成り立っても、返す絵が拠った投入の
    /// どれかを GPU が打ち切っていたら、結末が届くのを待ってから ``RenderFailure/workDropped(reason:)``
    /// を投げる — 打ち切られた描画の前の絵も、打ち切られた出力段の置き場に残っていた前の絵も、
    /// 成功として返さない。判定の範囲 (前に判定した読みの後に同じ土台へ積まれた投入すべてと、この
    /// 読みの出力段)・結末の待ちの上限・投げた後の読みの扱いは ``readPixels()`` と同じで、2 つの口は
    /// 同じ面の判定を分け合う。出力段だけが打ち切られたなら、次の呼び出しは組み直す。
    ///
    /// `scale` を 1 より小さくすると、置き場から拾う画素だけを読む (#1745)。出力段は画素ごとの
    /// 純関数で拾い方は `NearestNeighbor` の 1 つなので、間引いてから変換したのと同じバイト列に
    /// なる (#382)。
    ///
    /// - Parameter scale: 縮小率 (1 = 実寸)。1 以上または 0 以下は実寸として扱う。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    /// [#1752]: https://github.com/mokume-metal/mokume/issues/1752
    /// [#1762]: https://github.com/mokume-metal/mokume/issues/1762
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    public func encodeForDisplay(scale: Double = 1) throws(RenderFailure) -> DisplayImage {
        try refuseHeldDrop()
        let image = try encode { () throws(RenderFailure) in
            if let displayStorage { return displayStorage }
            let image = try EncodedImage(gpu: gpu, width: width, height: height)
            displayStorage = image
            return image
        }
        try gpu.settle()
        try judgeDroppedWork()
        return image.read(scaledBy: scale)
    }

    /// いまの内容を PNG として書き出す。**書き込みが終わってから返る。**
    ///
    /// 出力段を 1 度だけ通す ([ADR-0011] 決定 3)。絵は ``encodeForDisplay(scale:)`` から受け取るので、
    /// GPU が仕上げなかった絵は書き出さずに同じ ``RenderFailure`` を投げる ([#1932])。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    public func writePNG(to url: URL) throws {
        try PNGFile.write(try encodeForDisplay(), to: url)
    }
}
