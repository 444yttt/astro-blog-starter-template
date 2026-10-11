import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var replacementURL = ""
    @State private var validationError: String?
    @State private var submitting = false
    @State private var confirmRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if browser.hasSavedConnection {
                        Label("接続設定は登録済みです", systemImage: "checkmark.shield")
                        Text("変更する場合だけ、新しいURLを入力してください。空欄なら現在の設定を使います。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if browser.connectionStoreError == nil {
                        Text("ログイン開始URLを登録してください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    SecureField(browser.hasSavedConnection ? "新しいログイン開始URL" : "https://…", text: $replacementURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("ログイン開始URL")
                        .privacySensitive()
                        .disabled(submitting || browser.connectionStoreLoading)
                    if let validationError { Text(validationError).foregroundStyle(.red).font(.footnote) }
                    if let error = browser.connectionStoreError, error != validationError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                        Button("保存済み設定を再試行") {
                            Task { @MainActor in await browser.retrySavedConnection() }
                        }
                        .disabled(submitting || browser.connectionStoreLoading)
                    }
                    if submitting || browser.connectionStoreLoading { ProgressView("処理中…") }
                } header: { Text("ログイン開始URL") } footer: {
                    Text("店舗の接続情報を含むURLを、このiPhoneのKeychainに保存します。登録済みURLは表示しません。スタッフのID・パスワードはサイトのログイン画面に入力してください。")
                }
                Section("接続先") {
                    Text(URLPolicy.origin).font(.footnote).textSelection(.enabled)
                    Label("接続先の証明書を検証します", systemImage: "lock.shield").font(.footnote)
                }
                Section("ログイン状態") {
                    Text("Cookieはこのアプリ内で保持します。有効期限はサイトに従います。SafariやPC版とのログイン状態の共有はありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("接続設定を削除", role: .destructive) { confirmRemoval = true }
                        .disabled(submitting || browser.connectionStoreLoading || (!browser.hasSavedConnection && browser.connectionStoreError == nil))
                    Text("削除すると登録済みURLとCookieを消去し、接続設定を開き直します。メニューのログイン状態リセットはCookieだけを消去します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("バージョン", value: "1.0.0")
                    Text("サイト運営元の公式アプリではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("接続設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        submitting = true
                        validationError = nil
                        Task { @MainActor in
                            if let error = await browser.saveLoginURL(replacementURL) {
                                validationError = error
                                submitting = false
                                return
                            }
                            replacementURL = ""
                            submitting = false
                            dismiss()
                            browser.login()
                        }
                    }
                    .disabled(submitting || browser.connectionStoreLoading)
                }
            }
            .interactiveDismissDisabled(submitting)
            .alert("接続設定を削除", isPresented: $confirmRemoval) {
                Button("キャンセル", role: .cancel) {}
                Button("削除する", role: .destructive) {
                    submitting = true
                    validationError = nil
                    Task { @MainActor in
                        if let error = await browser.removeSavedConnection() {
                            validationError = error
                            submitting = false
                            return
                        }
                        replacementURL = ""
                        submitting = false
                        dismiss()
                    }
                }
            } message: {
                Text("登録済みURLと、このアプリのログイン状態を消去します。再度URLの登録が必要です。")
            }
            .onDisappear { replacementURL = "" }
        }
    }
}
