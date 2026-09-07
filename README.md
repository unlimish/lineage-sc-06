# lineage-sc-06 — docomo GALAXY S III (SC-06D) を新しい Android にする + ワンセグを生かす

SC-06D（Samsung GALAXY S III / docomo / コードネーム **`d2dcm`**）に LineageOS を入れて、
**ワンセグを動かしたまま新しい Android にする**ためのプロジェクトです。

このリポジトリには、実機なしで用意できるところまで（デバイスツリー、ビルド設定、
移植手順、実機調査ツール）が入っています。

---

## 最初に読む結論

調査の結果、**「新しい Android」と「ワンセグ」は難易度がまったく違います**。
先に事実だけ書きます。

| 目標 | 実現性 | 根拠 |
|---|---|---|
| LineageOS を入れる | **できる** | `d2` 系のカーネル／デバイスツリーが lineage-16.0 まで生きている |
| Android のバージョンを上げる | **Android 9 まで**（純正 4.1.2 から大幅前進） | MSM8960 向けは lineage-16.0 が事実上の上限 |
| ワンセグのカーネルドライバ | **すでに用意されている** | `drivers/media/nmi326/` が lineage-16.0 のカーネルに残っており、`lineageos_d2dcm_defconfig` で `CONFIG_ISDBT_NMI=y` |
| ワンセグが実際に映る | **未解決。ただし道筋は見えた** | 実機調査でスタックと**チューナ API を特定済み**（`OneSegDrv_SetChannel` / `ReadData` など、C リンケージで `dlsym` 可能）→ [`docs/07`](docs/07-実機調査の結果.md) |

つまり、

> **カーネルの入口（`/dev/isdbt`）までは新しい Android でも開いている。
> その先のユーザー空間が丸ごと欠けている。**

というのが今の状態です。詳しくは [`docs/02-ワンセグの構造と壁.md`](docs/02-ワンセグの構造と壁.md) に書きました。

### 「Android 13 や 14 にしたい」場合

**できません。** SC-06D の SoC は Qualcomm MSM8960（Snapdragon S4, 2012年）で、
この世代向けの Android 10 以降のツリーは存在しません。Galaxy S3 で LineageOS 20 / 21 が
動いているという話は、**Exynos 版の i9300 の話**であって、SC-06D（Snapdragon 版）とは別物です。

SC-06D で現実的に狙えるのは **Android 9（LineageOS 16.0）** です。
純正が Android 4.1.2 で止まっているので、これでも 7 世代ぶんの前進になります。

---

## ワンセグについての現実的な見通し

ワンセグを新しい Android で動かすのは、LineageOS を入れること自体より難しく、
**成功は保証できません**。ただし壁は 2 つで、かつては 3 つあると考えていたうちの
1 つ（DRM）は、調べた結果**存在しませんでした**。

### 壁 1: カーネルドライバが何もしてくれない

`drivers/media/nmi326/nmi326.c` は電源 ON/OFF と割り込みと SPI の生の read/write しか
持っていません。チューニングも復調も TS の切り出しも、全部ユーザー空間の
クローズドなライブラリの仕事です。

### 壁 2: そのユーザー空間を誰も移植していない

CM13 時代の d2dcm デバイスツリーの `proprietary-files.txt` には、
FeliCa（おサイフケータイ）や docomo 絵文字は入っているのに、
**ワンセグ関連のファイルが 1 つも入っていません**。過去に誰も通していない、ということです。

### 壁ではなかったもの: DRM

**ワンセグ放送はスクランブルされていません。** 視聴に B-CAS カードは不要で、
RMP（コンテンツ権利保護専用方式）はフルセグ側の仕組みです。
SC-06D はフルセグ非対応なので、**そもそも関係ありません**。

これは大きな意味を持ちます。**チューナから TS を取り出せさえすれば、
中身は平文の MPEG-2 TS（H.264 + AAC）** で、あとは何ででも再生できます。
純正のワンセグアプリを Android 9 で動かす必要はなく、
自前のプレイヤーでも ffmpeg でも構いません。

つまりこのプロジェクトの課題は、**「NMI326 から TS を取り出す」一点に絞られます**。

その攻略手順を [`docs/05-ワンセグ移植の手順.md`](docs/05-ワンセグ移植の手順.md) に書きました。
最初の一歩は「純正 ROM のワンセグスタックが何でできているかを実機から吸い出す」ことで、
そのためのスクリプトを [`tools/oneseg-probe.sh`](tools/oneseg-probe.sh) に用意しました。

### 実機調査の結果（2026年9月・Android 4.0.4 実機）

実際に SC-06D を調べた結果、**見通しは想定より良い**ことが分かりました。

- `/dev/isdbt` を開いているのは **`libonesegdmxdriver.so` ただ 1 つ**
- その依存は `libonesegutils.so` → `libPGL.so` と AOSP の基本ライブラリだけ。
  **移植対象の独自ライブラリは 3 つ**
- しかも **`libbinder` / `libandroid_runtime` / `libsurfaceflinger_client` を要求しない**
  （後者は Android 9 に存在しないライブラリ。これを避けられるのが大きい）
- 暗号（CPRM）は**録画パス**にあり、受信パスには無い。
  **録画を「TS をそのまま書く」方式にすると決めた**ので、CPRM ごと移植対象外
  → 純正から持ち込むのは**上記 3 ファイルで全部**（[`docs/08`](docs/08-アプリ設計.md)）
- データ放送（DSM-CC/BML）と NexPlayer は**移植不要**
- **チューナ API が判明**: `libonesegdmxdriver.so` は 141 シンボルを C リンケージで
  公開しており、`OneSegDrv_Initailze` / `SetChannel` / `ReadData` / `CheckChannelLock`
  がそのまま `dlsym` で呼べます。**純正 ROM のまま、焼く前に検証できます**

詳細と次の一手は [`docs/07-実機調査の結果.md`](docs/07-実機調査の結果.md)。

**ワンセグが最優先なら**、純正のまま root だけ取る、という選択肢も真剣に検討してください。
[`docs/01-結論と実現可能性.md`](docs/01-結論と実現可能性.md) に判断材料をまとめています。

---

## リポジトリの構成

```
docs/                            ドキュメント（日本語）
  01-結論と実現可能性.md          どの道を選ぶかの判断材料
  02-ワンセグの構造と壁.md        ワンセグのスタック構造と、何が足りないか
  03-ビルド手順.md                LineageOS 16.0 のビルド
  04-書き込み手順.md              SC-06D への書き込みと復旧
  05-ワンセグ移植の手順.md        ワンセグを通すための段階的な攻略手順
  06-調査ログ.md                  上の結論の一次ソース（実際に確認したコード）
  07-実機調査の結果.md            ★実機 SC-06D から判明した事実（唯一の実測データ）
  08-アプリ設計.md                視聴・録画アプリの構成（録画は TS をそのまま書く）

device/samsung/d2dcm/            SC-06D 用デバイスツリー（LineageOS 16.0 向け・未検証）
  BoardConfig.mk                 d2att-unified を継承して SC-06D 差分を上書き
  device.mk / lineage_d2dcm.mk   製品定義
  system.prop                    docomo 向けプロパティ
  proprietary-files.txt          純正から抜くファイル一覧（ワンセグ分は実機で特定済み）
  extract-files.sh               純正 ROM / 実機から blob を抽出
  rootdir/etc/init.oneseg.rc     /dev/isdbt のパーミッション
  sepolicy/                      SELinux ポリシー（isdbt デバイス）

kernel/patches/                  SPI 通信トレース用パッチ（ドライバ有効化は不要。理由は同 README）
manifests/local_manifest.xml     repo sync 用マニフェスト
tools/
  oneseg-probe.sh                純正 ROM のワンセグスタックを実機から調査する（最重要）
  analyze-oneseg-blobs.py        ELF 依存関係の解析 / --symbols でエクスポート関数一覧
  isdbt-dump.c                   /dev/isdbt を開いて電源を入れ、読めたものを保存する
  oneseg-api-probe.c             純正ライブラリを dlopen してチューナ API を直接叩く
  link-device-tree.sh            d2dcm ツリーを Lineage ツリーに繋ぐ
  verify-tree.sh                 ビルド前の静的チェック
```

---

## 使い方

### 1. まず実機を調べる（ワンセグを狙うなら必須・最重要）

対象は **純正のまま root を取った SC-06D**。4.0.4 でも 4.1.2 でも構いません
（ワンセグは発売時の 4.0.4 から搭載されています）。
LineageOS を焼く前でないと取れない情報です。

> **スクリプトは PC で実行します。端末側では動きません。**
> 端末は USB で挿しておくだけです。端末に何かをインストールすることもありません。
>
> **Google アカウントは不要です。** adb は Play Services を一切通らないので、
> 「Play 開発者サービスが古くてログインできない」状態でも問題なく調査できます。

#### 準備するもの: adb だけ

| OS | 入れ方 |
|---|---|
| Windows | [Platform-Tools](https://developer.android.com/tools/releases/platform-tools) を展開し、**Git Bash** で実行（WSL は USB が見えないので不可）。Samsung USB ドライバも必要 |
| macOS | `brew install --cask android-platform-tools` |
| Ubuntu/Debian | `sudo apt install adb` |
| Arch | `sudo pacman -S android-tools` |

#### 手順

```bash
# 1. 端末側: 設定 > 開発者向けオプション > USB デバッグ を ON にして USB 接続
#    （Android 4.0.4 には「USBデバッグを許可しますか?」のダイアログはありません。
#      あれは 4.2.2 からです。挿すだけで繋がります）

# 2. PC 側: 見えているか確認
adb devices
#   List of devices attached
#   xxxxxxxx        device        ← "device" と出れば OK

# 3. このリポジトリを取ってきて実行
git clone https://github.com/unlimish/lineage-sc-06.git
cd lineage-sc-06
bash tools/oneseg-probe.sh
```

`chmod +x` を忘れて `Permission denied` になる場合があるので、
上のように **`bash tools/oneseg-probe.sh`** と書くのが確実です。

途中で root 権限を求めるので、**端末の画面に出る SuperSU / SuperUser の許可ダイアログを
見逃さないでください**（タイムアウトで拒否されると root 部分が丸ごと欠けます）。

#### 結果

`oneseg-report/` に保存されます。まず見るのはこの 3 つ:

| ファイル | 何がわかるか |
|---|---|
| `dmesg-isdbt.txt` | ワンセグのチューナが正常に認識されているか |
| `hits-devnode.txt` | **`/dev/isdbt` を開いているライブラリはどれか**（移植の本丸） |
| `by-name.txt` | 実際のパーティション構成（`BoardConfig.mk` 用） |

続けて依存関係を解析します。

```bash
python3 tools/analyze-oneseg-blobs.py oneseg-report/

# チューナを叩くライブラリの API（エクスポート関数）を見る
python3 tools/analyze-oneseg-blobs.py oneseg-report/ --symbols libonesegdmxdriver
```

**これがないとワンセグ移植は始まりません。**
既知の結果は [`docs/07-実機調査の結果.md`](docs/07-実機調査の結果.md) にあります。

### 2. LineageOS 16.0 をビルドする

[`docs/03-ビルド手順.md`](docs/03-ビルド手順.md) を参照してください。
ディスク 300GB 前後、RAM 16GB 以上が必要です。

### 3. 焼く

[`docs/04-書き込み手順.md`](docs/04-書き込み手順.md) を参照してください。
**先に純正 ROM のフルバックアップ（特に EFS パーティション）を取ってください。**

---

## この構成の検証状態

正直に書きます。

- **実機で検証していません。** このリポジトリの作者環境に SC-06D はありません。
- `device/samsung/d2dcm/` は、実在する 2 つのツリー
  （`Samsung-Galaxy-S3-MSM8960/android_device_samsung_d2att-unified` の lineage-16.0 と、
  `kbc-developers/android_device_samsung_d2dcm` の cm-13.0）から
  SC-06D の差分を組み直したもので、**ビルドは通していません**。
- 一方で、**カーネル側の事実関係は実際のソースを読んで確認済み**です。
  `nmi326` ドライバの存在、`/dev/isdbt`（major 225）、ioctl の一覧、
  `CONFIG_ISDBT_NMI=y`、`board-m2_dcm.c` の SPI/GPIO 結線まで、
  すべて [`docs/06-調査ログ.md`](docs/06-調査ログ.md) に引用元付きで記録しています。

最初のビルドでは高確率でエラーが出ます。パーティションサイズ、RIL、
`proprietary-files.txt` の中身あたりは、**実機と純正 ROM を見ながらの調整が前提**です。

---

## ライセンスと注意

- デバイスツリーは Apache License 2.0（元ツリーに準拠）。
- 純正 ROM 由来のバイナリ（blob）は**このリポジトリに含めません**。各自の端末から抽出してください。
- ブートローダのアンロックや ROM の書き換えは**メーカー保証の対象外**になり、
  文鎮化のリスクがあります。自己責任で行ってください。
- おサイフケータイ（FeliCa）は、カスタム ROM では動かないものと考えてください。
  **移行前に必ず残高を移してください。**
