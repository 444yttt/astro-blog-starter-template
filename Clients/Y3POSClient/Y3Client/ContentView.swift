import SwiftUI
import WebKit

@MainActor
struct ContentView: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        NavigationStack {
            BrowserSurface(browser: browser, webView: browser.activeWebView)
                .navigationTitle(browser.hasPopups ? "別ウィンドウ" : "Y3 Client")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if browser.hasPopups { Button("閉じる", action: browser.closeTopPopup) }
                        else {
                            Label("POS CM CLOUD", systemImage: "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("接続設定", systemImage: "slider.horizontal.3") { browser.showSettings = true }
                            .labelStyle(.iconOnly)
                    }
                    ToolbarItemGroup(placement: .bottomBar) { BrowserControls(browser: browser).labelStyle(.iconOnly) }
                }
                .disabled(browser.isResetting)
                .sheet(item: $browser.sheet, onDismiss: browser.sheetDidDismiss) { sheet in
                    switch sheet {
                    case .settings: SettingsView(browser: browser)
                    case .download(let download):
                        ShareSheet(file: download.file) { browser.sharingCompleted(id: download.id) }
                    }
                }
                .alert("ログイン状態をリセット", isPresented: $browser.showResetConfirmation) {
                    Button("キャンセル", role: .cancel) {}
                    Button("消去する", role: .destructive) { browser.resetSession() }
                } message: {
                    Text("このアプリに保存したログイン状態を消去します。再ログインが必要になり、別ウィンドウも閉じます。")
                }
                .alert("Y3 Client", isPresented: Binding(get: { browser.notice != nil }, set: { if !$0 { browser.notice = nil } })) {
                    Button("OK") { browser.notice = nil }
                } message: { Text(browser.notice ?? "") }
        }
        .tint(Color.accentColor)
        .onAppear { browser.start() }
    }
}

@MainActor
struct BrowserSurface: View {
    @ObservedObject var browser: BrowserModel
    let webView: WKWebView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(browser.failure == nil ? Color.accentColor : .orange).frame(width: 5, height: 5)
                Text(browser.title).lineLimit(1)
                Spacer(minLength: 8)
                if browser.loading { Text("読み込み中").font(.caption2) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(.secondarySystemBackground))
            if !browser.framePanes.isEmpty && browser.failure == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        paneButton("全体", selected: browser.selectedFramePaneID == nil) { browser.focusFramePane(nil) }
                        ForEach(browser.framePanes) { pane in
                            paneButton(pane.title, selected: browser.selectedFramePaneID == pane.id) { browser.focusFramePane(pane) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .background(Color(.secondarySystemBackground))
                .accessibilityLabel("表示するフレーム")
            }
            if browser.needsLogin {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                    Text("ログインが必要です").font(.footnote)
                    Spacer(minLength: 8)
                    Button("ログイン画面", action: browser.login).font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.tertiarySystemBackground))
            }
            ZStack(alignment: .top) {
                WebView(webView: webView).id(ObjectIdentifier(webView))
                    .opacity(browser.failure == nil ? 1 : 0)
                    .accessibilityHidden(browser.failure != nil)
                if browser.failure == nil && !browser.hasSavedConnection && !browser.isResetting
                    && (webView.url == nil || webView.url?.absoluteString == "about:blank") {
                    ContentUnavailableView {
                        Label("接続設定が必要です", systemImage: "link")
                    } description: {
                        Text("ログイン開始URLを登録して、POS CM CLOUDを開きます。")
                    } actions: {
                        Button("接続設定") { browser.showSettings = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let failure = browser.failure {
                    ContentUnavailableView {
                        Label(failure.title, systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("もう一度接続する", action: browser.reload).buttonStyle(.borderedProminent)
                        Button("接続設定") { browser.showSettings = true }
                    }
                }
                if browser.loading { ProgressView(value: browser.progress).progressViewStyle(.linear) }
                if browser.isResetting {
                    Color(.systemBackground).opacity(0.95)
                    ProgressView("ログイン状態を消去しています…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func paneButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .background(selected ? Color.accentColor : Color(.tertiarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
struct BrowserControls: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        Button("戻る", systemImage: "chevron.left", action: browser.back).disabled(!browser.canGoBack)
        Spacer()
        Button("進む", systemImage: "chevron.right", action: browser.forward).disabled(!browser.canGoForward)
        Spacer()
        Button("更新", systemImage: "arrow.clockwise", action: browser.reload)
        Spacer()
        Button("ホーム", systemImage: "house", action: browser.home)
        Spacer()
        Menu {
            Button("ログイン画面", systemImage: "person.crop.circle", action: browser.login)
            Button("AirPrintで印刷", systemImage: "printer", action: browser.printPage)
                .disabled(browser.needsLogin || browser.failure != nil)
            Button("Safariで開く", systemImage: "safari", action: browser.openInSafari)
            Divider()
            Button("接続設定", systemImage: "slider.horizontal.3") { browser.showSettings = true }
            Button("ログイン状態をリセット", systemImage: "arrow.counterclockwise", role: .destructive) { browser.showResetConfirmation = true }
        } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("メニュー") }
        .labelStyle(.iconOnly)
    }
}

