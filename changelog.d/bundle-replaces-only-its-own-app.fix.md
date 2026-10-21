<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume bundle` が、`--out` の直下にある `<name>.app` を、前に mokume が作ったものだけ作り直すようになりました。** これまでは中身を確かめずに消していたため、`--out ~/Applications` のように共有の置き場を指すと、同じ名前の無関係な `.app` (ただのフォルダでも) が中身ごと消えました。いまは `Info.plist` の mokume の印か、この版より前に束ねたものの識別子の一致で確かめ、確かめられなければビルドの前に場所を示して止まります (要らなければ手で消してください)。識別子を変えた作り直しも、印があるので通ります。
