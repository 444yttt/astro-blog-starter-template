# GitHub ActionsによるIPA作成

このフォルダーは、新しい公開リポジトリ `444yttt/Y3POSClient` の候補として分離したソースです。準備段階ではリポジトリの作成・公開・pushを行っていません。既存の非公開マニュアルリポジトリの公開範囲、履歴、ソース、workflowは変更しません。

## ビルド設定

- Source branch: `main`（署名Secretsを使う参照先として固定）
- Source directory: リポジトリのルート
- Project / shared Scheme / Target: `Y3Client.xcodeproj` / `Y3Client` / `Y3Client`
- Bundle ID: `com.ayato.y3posclient`
- Minimum deployment: iPhone / iOS 17.0
- Runner: standard `macos-15`; Xcode 16.4を明示的に選択。大容量runnerは使いません。
- Timeout: 30分
- Dependencies: Apple frameworksのみ。Extension、Swift Package、CocoaPodsはありません。
- Distribution: `app-store-connect`。IPAのexportのみで、TestFlight・App Storeへのアップロードは行いません。

公開リポジトリの標準GitHub-hosted runnerは、GitHubの公開リポジトリ向け無料利用の対象です。大容量runnerや別の有料サービスへ変更する場合は料金条件が異なります。このworkflowはBilling設定を変更しません。

App Store向けIPAは、ファイルをiPhoneへ渡すだけではインストールできません。直接配布へ変更する場合は、Ad Hoc用のProfileと登録済みUDIDが必要です。

## このリポジトリに登録するSecrets

別リポジトリのSecretsは、新しい公開リポジトリへ自動的に引き継がれません。GitHub APIから既存Secretsの平文を読み戻すこともできません。所有者が署名環境で保管している元ファイルを使い、このリポジトリのSettings → Secrets and variables → Actionsに登録する必要があります。

| 用途 | 推奨するSecret名 | 同じ新リポジトリで利用できる別名 |
| --- | --- | --- |
| 秘密鍵を含む.p12のBase64 | `BUILD_CERTIFICATE_BASE64` | `DIST_P12_BASE64` |
| .p12のパスワード | `P12_PASSWORD` | `DIST_P12_PASSWORD` |
| Apple Developer Team ID | `APPLE_TEAM_ID` | なし |
| 新アプリ専用ProfileのBase64（任意） | `BUILD_PROVISION_PROFILE_BASE64` | なし |
| 一時Keychainのパスワード（任意） | `KEYCHAIN_PASSWORD` | 未設定なら実行ごとに生成 |

Profileを登録しない場合は、同じ新リポジトリに `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY` を登録します。`ASC_PRIVATE_KEY`は対応する`.p8`ファイルのPEM本文です。APIキーにはCertificates, Identifiers & Profilesへのアクセス権限が必要です。

この候補を準備したGitHub連携ではSecretsの設定APIが403となるため、Secretsを新リポジトリへ登録・移行できたとは扱っていません。.p12、パスワード、Profile、API秘密鍵をソース、Issue、Actions入力欄、チャットに貼り付けないでください。

## 署名とProfileの準備

コード署名には.p12内の対応する秘密鍵と有効な証明書が必要です。.cerだけやApp Store Connect APIキーだけでは署名しません。

Profileが未設定の場合は、登録されたASCキーを使い、既存.p12の証明書に合う `com.ayato.y3posclient` 用のProfileを取得します。未登録なら、このBundle IDとApp Store Profileだけを作成します。既存アプリのProfile、証明書の新規作成・失効、既存アプリの設定変更は行いません。

署名前に秘密鍵identity、ProfileのTeam・App ID prefix・Bundle・許可証明書・期限・配布方式を照合します。署名設定は対象ターゲットにだけ一時的に適用し、ソースのTeam設定は空欄へ戻します。新しいExtension等を追加した場合は、そのターゲット用Profileと検証対応を追加するまで停止します。

## 実行と成果物

Secretsを用意する前でも、Actionsの `Check Y3 POS Client iOS Build` でApple SDKによる無署名Simulatorビルドを確認できます。このworkflowはSecretsの参照や署名資産の復元を行いません。

Secretsの登録後、Actionsから `Build Y3 POS Client IPA` を手動実行します。`source_ref`は`main`だけを受け付けます。Xcode 16.4を確認し、無署名Simulatorビルドの後、実機Releaseのarchive・manual export・署名検証を行います。

出力IPAの全architectureについて、コード署名、Bundle、実署名証明書、Entitlements、埋め込みProfile、期限、選択したProfileとの一致を検証します。成功した場合だけIPAと検証JSONをまとめ、受取人のage公開鍵で暗号化した`.age`ファイルだけをArtifactとして7日間保存します。平文のIPA、検証JSON、生のProfile、証明書ファイル、.p12、API秘密鍵、一時Keychain、archiveはアップロードしません。

公開リポジトリのActions Artifactは、リポジトリを閲覧できるGitHub利用者がダウンロードできますが、このworkflowが保存するのは暗号化済みパッケージだけです。IPAには署名証明書と埋め込みProfileが含まれるため、これらのTeam情報や証明書名も暗号化して保護します。

`delivery-recipient.txt`に入れるのは受取人のage公開鍵だけで、ソースへ登録できます。対応する秘密identityは受取人側で保管し、リポジトリ、Secrets、Actions入力欄、Artifactへ入れません。暗号化に追加のSecretsは不要です。生成する秘密identityはソース候補の外で保管します。受取人は秘密identityを使ってダウンロードした`.age`を復号し、中のIPAと検証JSONを取り出します。

成否にかかわらず、復元した署名ファイルとKeychainを削除し、Keychainの検索リストを戻します。IPAの生成後も、iPhone実機でのログイン・共有・AirPrintの確認は必要です。

## 実行が止まる場合

- Secret不足: エラーに表示された名前を、この新リポジトリのActions Secretsへ登録します。別の非公開リポジトリに同じ名前があっても利用されません。
- 秘密鍵identityなし: 対応する秘密鍵を含む.p12を、既存署名環境から書き出します。
- Apple APIの401: Key ID・Issuer ID・対応する.p8を確認します。
- Apple APIの403: APIキーのCertificates, Identifiers & Profiles権限を確認するか、新Bundleに適合するProfileを登録します。
- 期限切れ・Team不一致: 所有者のApple Developer Teamに属する、有効な証明書と対応するProfileを用意します。
- Runner開始前のアカウント制限: GitHubのBilling画面に表示された理由を確認します。このworkflowは支払いや利用上限を変更しません。
