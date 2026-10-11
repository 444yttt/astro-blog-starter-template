# Y3 Client for iPhone

POS CM CLOUD用のiPhoneクライアントです。SwiftUIとWKWebViewで、サイトのログイン・検索・帳票・エクスポートを開きます。iOS 17以降に対応します。

## 対応する操作

サイトのログイン、データ閲覧、在庫照会、帳票検索、販売データのエクスポートに対応します。アプリはサイトのフォームと遷移処理を利用します。

メニューURLを独立したリクエストで開き直すと、サイトが「不正操作」のエラーを返します。そのため、起動時は保存したログイン入口を使い、ホームボタンは各画面の「メニュー選択画面」リンクを操作します。画面内のフォーム、文字コード、名前付きフレーム、検索送信とサイト側の遷移処理を保持します。

帳票は複数のフレームで構成されます。検索条件・結果・操作画面を個別に広く表示する切替を追加しています。「全体」で元の構成に戻ります。表の列を保ち、横に長い結果は横スクロールで確認できます。入力欄・操作ボタンをiPhone向けに大きくし、品番検索の小窓も画面幅に合わせます。

販売エクスポートは、同じホストのHTTPSポート7705にある別サービスをフレーム内で呼び出し、ポート15505のダウンロードリンクを返します。確認したCSV・Excelリンクは「保存」ボタンとして表示し、ダウンロード後にiPhoneの共有画面を開きます。

## 初回設定とログイン

最初に接続設定へログイン開始URLを貼り付けます。指定できるURLは、`https://adidas-y3.poscmcloud.jp:15505` 内のHTTPS URLです。店舗の接続情報を含むため、実際のURLやスタッフの資格情報はソースコードに入れていません。

登録したURLは、ロック解除中にだけ利用できる、このiPhone専用のKeychainへ保存します。設定画面では保存済みURLを表示しません。変更する場合だけ新しいURLを入力し、空欄なら現在の設定を使います。以前の版の設定がある場合は、正常にKeychainへ保存してから通常の設定領域から削除します。

スタッフのID・パスワードはサイトのログイン画面へ入力します。アプリ独自のスタッフ資格情報保存や自動入力はありません。アプリ内のCookieを利用し、Safariとのログイン状態は共有しません。サイトのセッション期限に応じて再ログインが必要です。

「ログイン状態をリセット」はCookieなどのサイトデータを消去し、登録したログイン入口を開きます。「接続設定を削除」はKeychainのURLとサイトデータを両方消去します。

## 操作

- 画面下から戻る・進む・更新・ホームを操作します。
- フレームのある画面では、上部から検索条件・結果・操作画面を切り替えます。画面の内容によって表示される切替が異なります。
- 同じ接続先の別ウィンドウはアプリ内に開きます。「閉じる」で元の画面へ戻ります。
- JavaScriptの確認・入力ダイアログに対応します。
- ダウンロード後の共有画面から「ファイルに保存」などを選びます。CSVの文字コードはサイトが返す形式のまま保持します。
- 「…」メニューからAirPrintやSafariを開けます。AirPrintには対応プリンターが必要です。SafariにはこのアプリのCookieが引き継がれません。

HTTPSの証明書検証を使い、ATSの例外は設定していません。社内ネットワークやVPNが必要な場合は、iPhoneを接続してから利用します。閲覧・検索にはネットワーク接続が必要です。

## GitHub ActionsでIPAを作る

GitHub Actionsの標準macOS runnerとXcode 16.4を使う`.github/workflows/build-ipa.yml`を用意しています。手元にMacがなくても、このリポジトリへ登録したSecretsの秘密鍵付き証明書を使い、新しいアプリ専用Profileでarchive・署名・IPAの書き出しを行う構成です。別リポジトリのSecretsは自動的に引き継がれません。設定・実行方法・署名資産の対応は[CI_BUILD.md](docs/CI_BUILD.md)を参照してください。

配布方式はApp Store向けです。IPAをiPhoneへ渡すだけではインストールできません。今回はexportのみを行い、TestFlight・App Storeへアップロードしません。公開Actionsの成果物には、IPAと検証JSONを受取人のage公開鍵で暗号化したファイルだけを保存します。秘密identityは受取人側に保持します。

## Macでローカルビルドする場合

以下はMacの既存署名環境を使う代替手順です。

既存Y3マニュアルアプリのプロジェクトと、その署名を使ったXcodeアカウント・KeychainがあるMacでは、次を実行できます。

```sh
./scripts/sign-and-export.sh \
  --reference-project '/path/to/Y3Manual.xcodeproj'
```

スクリプトは参照プロジェクトの実際のTeamを取得し、シミュレーターでの無署名ビルドが通った後にarchive・IPAの書き出し・署名検査を行います。出力は新規フォルダーに保存します。複数の署名チームがある場合は`--reference-scheme`で対象を選べます。既存のTeam IDが分かる場合は`--team`、既存の書き出し設定を使う場合は`--export-options`を指定できます。詳しくは`--help`を参照してください。

```sh
./scripts/sign-and-export.sh --team YOUR_TEAM_ID
```

スクリプトはMacに設定済みのAppleアカウントと証明書を使用し、外部へアップロードしません。自動署名によって、このアプリのBundle IDが既存チームに登録される場合があります。Bundle IDは`com.ayato.y3posclient`です。

Xcodeから実機へ直接インストールする場合は、`Y3Client.xcodeproj`を開き、ターゲットの`Signing & Capabilities`で既存のTeamを選びます。接続したiPhoneを実行先として選択し、実行します。端末で求められた場合はデベロッパモードを有効にしてください。

## 検証と現在の制限

実サイトの確認には、iPhone WebKitのUser-Agentを設定したChromiumを使用しました。iPhone上のWebKitエンジンでの実行確認とは異なります。

2026年10月11日、公開リポジトリの一時ビルド用フォルダーで、GitHub ActionsのmacOS 15 runnerとXcode 16.4（16F6）による無署名iOS Simulatorビルドが[成功しました](https://github.com/444yttt/astro-blog-starter-template/actions/runs/38126986127)。Apple SDKによるコンパイルは確認済みです。署名済みIPAの生成、iPhone実機での動作、AirPrintの出力結果、iOS上の共有画面は未確認です。

作成環境はLinuxです。Xcodeプロジェクトの参照・設定・アイコン形式とSwiftの構文、CIのProfile準備と署名検証処理も検証しています。専用の公開リポジトリへの移行と署名用Secretsの準備は別途必要です。

外部ライブラリやSwift Packageの追加はありません。Appleの標準フレームワークを使います。Pythonによる構造・構文検証は次の通りです。

```sh
python -m pip install -r Tests/requirements.txt
python Tests/verify_project.py
```

`Tests/legacy_site_support.cjs`は、実サイトへ接続しない架空の画面で、フレーム切替・フォーム送信・表示調整を検証します。Node.js、PlaywrightとChromiumがある環境で実行できます。

```sh
node Tests/legacy_site_support.cjs
```

これらはApple SDKによる型チェックやXcodeビルドを代替しません。実機で利用する前に、対象の業務画面、ダウンロード、印刷を確認してください。

このアプリはサイト運営元やadidasの公式アプリではありません。
