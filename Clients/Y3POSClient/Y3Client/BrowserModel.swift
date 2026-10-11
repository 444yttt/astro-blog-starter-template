import Foundation
import Combine
import UIKit
import WebKit

struct ConnectionFailure {
    let title: String
    let message: String
    let code: Int
}

struct BrowserPopup: Identifiable {
    let id = UUID()
    let webView: WKWebView
}

struct SharedDownload: Identifiable {
    let id = UUID()
    let file: URL
}

enum ClientSheet: Identifiable {
    case settings
    case download(SharedDownload)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .download(let file): return file.id.uuidString
        }
    }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject {
    let webView: WKWebView
    @Published private(set) var title = "POS CM CLOUD"
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: ConnectionFailure?
    @Published private(set) var needsLogin = false
    @Published private(set) var framePanes: [FramePane] = []
    @Published private(set) var selectedFramePaneID: String?
    @Published private(set) var popups: [BrowserPopup] = []
    @Published private(set) var loginURLText = ""
    @Published private(set) var connectionStoreLoading = false
    @Published private(set) var connectionStoreError: String?
    @Published var sheet: ClientSheet?
    @Published private(set) var isResetting = false
    @Published var showResetConfirmation = false
    @Published var notice: String?

    private var started = false
    private var connectionRestored = false
    private var connectionRetryNeeded = false
    private var initialConnectionOpened = false
    private var reopenSetupAfterReset = false
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var failures: [ObjectIdentifier: ConnectionFailure] = [:]
    private var downloadRecords: [ObjectIdentifier: (WKDownload, URL?)] = [:]
    private var cancelledDownloads: Set<ObjectIdentifier> = []
    private var completedDownloads: [SharedDownload] = []
    private var currentSharing: SharedDownload?
    private var sheetPresentationActive = false
    private var resetNavigation: WKNavigation?
    private var requestedURLs: [ObjectIdentifier: URL] = [:]
    private var paneLists: [ObjectIdentifier: [FramePane]] = [:]
    private var focusedPanePaths: [ObjectIdentifier: [Int]] = [:]
    private var frameDiscoveryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var framePaneEpochs: [ObjectIdentifier: Int] = [:]
    private var frameFocusRevisions: [ObjectIdentifier: Int] = [:]
    private var dialogs: [QueuedDialog] = []
    private var presentingDialog: QueuedDialog?

    var activeWebView: WKWebView { popups.last?.webView ?? webView }
    var hasPopups: Bool { !popups.isEmpty }
    var hasSavedConnection: Bool { !loginURLText.isEmpty }
    var showSettings: Bool {
        get { if case .settings? = sheet { return true }; return false }
        set {
            if newValue && !isResetting && sheet == nil && !sheetPresentationActive {
                sheetPresentationActive = true
                sheet = .settings
            }
        }
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configure(webView)
    }

    private func configure(_ view: WKWebView) {
        let controller = view.configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source == LegacySiteSupport.viewportAndTouch }) {
            controller.addUserScript(WKUserScript(source: LegacySiteSupport.viewportAndTouch,
                injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.keyboardDismissMode = .interactive
        let refresh: (WKWebView, Any) -> Void = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        }
        observations[ObjectIdentifier(view)] = [
            view.observe(\.title, options: [.new]) { view, change in refresh(view, change) },
            view.observe(\.isLoading, options: [.new]) { view, change in refresh(view, change) },
            view.observe(\.estimatedProgress, options: [.new]) { view, change in refresh(view, change) },
            view.observe(\.canGoBack, options: [.new]) { view, change in refresh(view, change) },
            view.observe(\.canGoForward, options: [.new]) { view, change in refresh(view, change) }
        ]
    }

    func start() {
        guard !started else { return }
        started = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = await self.restoreLoginURL()
            if restored {
                if self.hasSavedConnection { self.login() }
                else { self.showSettings = true }
            }
            self.presentNextDialog()
        }
    }

    private func refreshState() {
        let view = activeWebView
        title = view.title?.isEmpty == false ? view.title! : "POS CM CLOUD"
        loading = view.isLoading
        progress = view.estimatedProgress
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        failure = failures[ObjectIdentifier(view)]
        needsLogin = !view.isLoading && failure == nil && title.contains("ログインエラー")
        framePanes = paneLists[ObjectIdentifier(view)] ?? []
        selectedFramePaneID = focusedPanePaths[ObjectIdentifier(view)]?.map(String.init).joined(separator: ".")
    }

    func back() { if !isResetting { activeWebView.goBack() } }
    func forward() { if !isResetting { activeWebView.goForward() } }
    func home() {
        guard !isResetting else { return }
        closeAllPopups()
        if let url = webView.url, URLPolicy.isTrusted(url), url.path == URLPolicy.home.path { return }
        guard let url = webView.url, URLPolicy.isTrusted(url) else { returnToLoginForHome(); return }
        webView.evaluateJavaScript(LegacySiteSupport.siteHome) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isResetting else { return }
                if error != nil || (result as? Bool) != true { self.returnToLoginForHome() }
            }
        }
    }

    private func returnToLoginForHome() {
        notice = hasSavedConnection
            ? "サイト内のメニューリンクが見つからないため、保存したログイン画面を開きます。"
            : "メニューに直接移動できないため、接続設定からログイン画面を開いてください。"
        login()
    }

    func reload() {
        guard !isResetting else { return }
        let view = activeWebView
        if failures[ObjectIdentifier(view)] != nil {
            notice = "直前の処理を再送せず、ログイン画面から接続し直します。"
            login()
        } else { view.reload() }
        refreshState()
    }

    func login() {
        guard !isResetting else { return }
        guard connectionRestored else {
            Task { @MainActor [weak self] in
                guard let self, await self.restoreLoginURL() else { return }
                self.login()
            }
            return
        }
        guard let url = URLPolicy.loginURL(from: loginURLText) else { showSettings = true; return }
        closeAllPopups()
        initialConnectionOpened = true
        webView.load(URLRequest(url: url))
    }

    private func restoreLoginURL() async -> Bool {
        guard !connectionStoreLoading else { return false }
        connectionStoreLoading = true
        defer { connectionStoreLoading = false }
        do {
            let saved = try await KeychainStore.shared.read()
            if let saved, URLPolicy.loginURL(from: saved) != nil {
                loginURLText = saved
                UserDefaults.standard.removeObject(forKey: "loginURL")
            } else {
                if saved != nil { try await KeychainStore.shared.remove() }
                if let previous = UserDefaults.standard.string(forKey: "loginURL"),
                   URLPolicy.loginURL(from: previous) != nil {
                    try await KeychainStore.shared.save(previous)
                    loginURLText = previous
                    UserDefaults.standard.removeObject(forKey: "loginURL")
                } else {
                    loginURLText = ""
                    UserDefaults.standard.removeObject(forKey: "loginURL")
                }
            }
            connectionRestored = true
            connectionRetryNeeded = false
            if notice == connectionStoreError { notice = nil }
            connectionStoreError = nil
            return true
        } catch {
            connectionRestored = false
            connectionRetryNeeded = true
            connectionStoreError = "接続設定を読み出せませんでした。\(error.localizedDescription)"
            if sheet == nil { notice = connectionStoreError }
            return false
        }
    }

    func retrySavedConnection() async {
        guard await restoreLoginURL() else { return }
        if !hasSavedConnection { showSettings = true }
        else if !initialConnectionOpened { login() }
    }

    func saveLoginURL(_ text: String) async -> String? {
        guard !connectionStoreLoading && !isResetting else { return "処理が終わってからお試しください。" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            if connectionRestored && hasSavedConnection { return nil }
            return connectionRestored ? "ログイン開始URLを入力してください。" : "保存済みの接続設定を確認できません。再試行するか、新しいURLを入力してください。"
        }
        if URLPolicy.loginURL(from: value) == nil {
            return "\(URLPolicy.origin) 内のログインURLを指定してください。"
        }
        connectionStoreLoading = true
        defer { connectionStoreLoading = false }
        do {
            try await KeychainStore.shared.save(value)
            loginURLText = value
            connectionRestored = true
            connectionRetryNeeded = false
            if notice == connectionStoreError { notice = nil }
            connectionStoreError = nil
            UserDefaults.standard.removeObject(forKey: "loginURL")
            return nil
        } catch {
            let message = "接続設定を保存できませんでした。\(error.localizedDescription)"
            connectionStoreError = message
            return message
        }
    }

    func removeSavedConnection() async -> String? {
        guard !connectionStoreLoading && !isResetting else { return "処理が終わってからお試しください。" }
        connectionStoreLoading = true
        defer { connectionStoreLoading = false }
        do {
            try await KeychainStore.shared.remove()
            UserDefaults.standard.removeObject(forKey: "loginURL")
            loginURLText = ""
            initialConnectionOpened = false
            connectionRestored = true
            connectionRetryNeeded = false
            if notice == connectionStoreError { notice = nil }
            connectionStoreError = nil
            reopenSetupAfterReset = true
            resetSession()
            return nil
        } catch {
            let message = "接続設定を削除できませんでした。\(error.localizedDescription)"
            connectionStoreError = message
            return message
        }
    }

    private func presentSetupAfterResetIfNeeded() {
        guard reopenSetupAfterReset && !isResetting && sheet == nil && !sheetPresentationActive else { return }
        reopenSetupAfterReset = false
        showSettings = true
    }

    func resetSession() {
        guard !isResetting else { return }
        isResetting = true
        closeAllPopups()
        cancelDialogs(for: webView)
        webView.stopLoading()
        for (id, record) in downloadRecords {
            cancelledDownloads.insert(id)
            record.0.cancel { [weak self] _ in
                Task { @MainActor [weak self] in
                    let saved = self?.downloadRecords.removeValue(forKey: id) ?? record
                    self?.cancelledDownloads.remove(id)
                    if let file = saved.1 { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                }
            }
        }
        for download in completedDownloads { try? FileManager.default.removeItem(at: download.file.deletingLastPathComponent()) }
        completedDownloads.removeAll()
        resetNavigation = webView.loadHTMLString("", baseURL: nil)
        if resetNavigation == nil {
            isResetting = false
            notice = "ログイン状態を消去できませんでした。もう一度お試しください。"
            presentSetupAfterResetIfNeeded()
        }
    }

    private func finishReset() {
        resetNavigation = nil
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isResetting = false
                self.requestedURLs.removeAll()
                if self.reopenSetupAfterReset { self.presentSetupAfterResetIfNeeded() }
                else { self.login() }
            }
        }
    }

    func closeTopPopup() {
        guard let popup = popups.last else { return }
        removePopup(popup.webView)
    }

    private func closeAllPopups() {
        for popup in popups.reversed() { detach(popup.webView) }
        popups.removeAll()
        refreshState()
    }

    private func removePopup(_ view: WKWebView) {
        guard let index = popups.firstIndex(where: { $0.webView === view }) else { return }
        detach(view)
        popups.remove(at: index)
        refreshState()
    }

    private func detach(_ view: WKWebView) {
        cancelDialogs(for: view)
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        observations.removeValue(forKey: ObjectIdentifier(view))
        failures.removeValue(forKey: ObjectIdentifier(view))
        requestedURLs.removeValue(forKey: ObjectIdentifier(view))
        clearFramePanes(in: view)
        view.removeFromSuperview()
    }

    private func clearFramePanes(in view: WKWebView) {
        let id = ObjectIdentifier(view)
        frameDiscoveryTasks.removeValue(forKey: id)?.cancel()
        paneLists.removeValue(forKey: id)
        focusedPanePaths.removeValue(forKey: id)
        framePaneEpochs[id] = (framePaneEpochs[id] ?? 0) + 1
        frameFocusRevisions[id] = (frameFocusRevisions[id] ?? 0) + 1
        if view === activeWebView { framePanes = []; selectedFramePaneID = nil }
    }

    private func scheduleFrameDiscovery(in view: WKWebView) {
        let id = ObjectIdentifier(view)
        frameDiscoveryTasks[id]?.cancel()
        frameDiscoveryTasks[id] = Task { @MainActor [weak self, weak view] in
            // A bounded series covers ordinary frame loads without background polling.
            let delays: [UInt64] = [0, 350_000_000, 900_000_000]
            for delay in delays {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self, let view, !self.isResetting,
                      let url = view.url, URLPolicy.isTrusted(url) else { return }
                self.discoverFramePanes(in: view)
            }
        }
    }

    private func discoverFramePanes(in view: WKWebView) {
        let id = ObjectIdentifier(view)
        let epoch = framePaneEpochs[id] ?? 0
        view.evaluateJavaScript(LegacySiteSupport.discoverFrames) { [weak self, weak view] result, error in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, !self.isResetting,
                      let url = view.url, URLPolicy.isTrusted(url), error == nil,
                      (self.framePaneEpochs[id] ?? 0) == epoch else { return }
                let records = result as? [[String: Any]] ?? []
                var resultIndex = 0
                var panes: [FramePane] = []
                for record in records.prefix(12) {
                    guard let path = record["path"] as? [Int], !path.isEmpty, path.count <= 8,
                          path.allSatisfy({ (0 ..< 64).contains($0) }), let kind = record["kind"] as? String else { continue }
                    let label: String
                    switch kind {
                    case "condition": label = "検索条件"
                    case "controls": label = "操作"
                    case "navigation": label = "ナビ"
                    case "export": label = "エクスポート"
                    case "result": resultIndex += 1; label = "結果\(resultIndex)"
                    default: continue
                    }
                    panes.append(FramePane(path: path, title: label))
                }
                let id = ObjectIdentifier(view)
                self.paneLists[id] = panes
                if let path = self.focusedPanePaths[id] {
                    if panes.contains(where: { $0.path == path }) {
                        view.evaluateJavaScript(LegacySiteSupport.focusScript(path: path), completionHandler: nil)
                    } else {
                        self.focusedPanePaths.removeValue(forKey: id)
                        self.frameFocusRevisions[id] = (self.frameFocusRevisions[id] ?? 0) + 1
                        view.evaluateJavaScript(LegacySiteSupport.focusScript(path: nil), completionHandler: nil)
                    }
                }
                self.refreshState()
            }
        }
    }

    func focusFramePane(_ pane: FramePane?) {
        guard !isResetting else { return }
        let view = activeWebView
        guard let url = view.url, URLPolicy.isTrusted(url),
              pane == nil || framePanes.contains(where: { $0.id == pane?.id }) else { return }
        let path = pane?.path
        let id = ObjectIdentifier(view)
        let epoch = framePaneEpochs[id] ?? 0
        let previousPath = focusedPanePaths[id]
        let revision = (frameFocusRevisions[id] ?? 0) + 1
        frameFocusRevisions[id] = revision
        // Store the requested focus before discovery can enqueue a competing script.
        if let path { focusedPanePaths[id] = path }
        else { focusedPanePaths.removeValue(forKey: id) }
        refreshState()
        view.evaluateJavaScript(LegacySiteSupport.focusScript(path: path)) { [weak self, weak view] result, error in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, !self.isResetting,
                      (self.framePaneEpochs[id] ?? 0) == epoch,
                      self.frameFocusRevisions[id] == revision else { return }
                if error != nil || (result as? Bool) != true {
                    if let previousPath { self.focusedPanePaths[id] = previousPath }
                    else { self.focusedPanePaths.removeValue(forKey: id) }
                }
                self.refreshState()
            }
        }
    }

    func printPage() {
        guard !isResetting, presenter() != nil else { return }
        guard UIPrintInteractionController.isPrintingAvailable else { notice = "このiPhoneでは印刷を利用できません。"; return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = activeWebView.viewPrintFormatter()
        controller.present(animated: true) { [weak self] _, _, error in
            if let error { self?.notice = "印刷できませんでした：\(error.localizedDescription)" }
        }
    }

    func openInSafari() {
        guard let url = activeWebView.url, URLPolicy.externalWebURL(url) else { return }
        confirmExternal(url)
    }

    private func confirmExternal(_ url: URL) {
        guard URLPolicy.externalWebURL(url) else { return }
        let controller = UIAlertController(title: "Safariで開く", message: "\(url.host ?? "外部サイト") をSafariで開きますか？このアプリのログイン状態は引き継がれません。", preferredStyle: .alert)
        let record = QueuedDialog(controller: controller, source: nil, cancel: {})
        controller.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self, weak record] _ in
            guard let record else { return }; self?.resolve(record) {}
        })
        controller.addAction(UIAlertAction(title: "開く", style: .default) { [weak self, weak record] _ in
            guard let record else { return }
            self?.resolve(record) { UIApplication.shared.open(url) }
        })
        enqueue(record)
    }

    private func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var current = root
        while let next = current?.presentedViewController, !next.isBeingDismissed { current = next }
        return current
    }

    func resumeDialogs() {
        presentNextDialog()
        if started && connectionRetryNeeded && !connectionStoreLoading {
            Task { @MainActor [weak self] in await self?.retrySavedConnection() }
        }
    }

    private func enqueue(_ record: QueuedDialog) {
        dialogs.append(record)
        presentNextDialog()
    }

    private func presentNextDialog() {
        guard presentingDialog == nil, !dialogs.isEmpty, UIApplication.shared.applicationState == .active else { return }
        guard let presenter = presenter(), presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingPresented && !presenter.isBeingDismissed,
              presenter.presentedViewController == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.presentNextDialog() }
            return
        }
        let record = dialogs.removeFirst()
        presentingDialog = record
        presenter.present(record.controller, animated: true)
    }

    private func resolve(_ record: QueuedDialog, action: () -> Void) {
        guard !record.finished else { return }
        record.finished = true
        action()
        record.controller.dismiss(animated: true) { [weak self, weak record] in
            guard let self else { return }
            if self.presentingDialog === record { self.presentingDialog = nil }
            self.presentNextDialog()
        }
    }

    private func cancelDialogs(for view: WKWebView) {
        let cancelled = dialogs.filter { $0.source === view }
        dialogs.removeAll { $0.source === view }
        for record in cancelled where !record.finished { record.finished = true; record.cancel() }
        if let record = presentingDialog, record.source === view {
            if !record.finished { record.finished = true; record.cancel() }
            record.controller.dismiss(animated: false)
            presentingDialog = nil
        }
        DispatchQueue.main.async { [weak self] in self?.presentNextDialog() }
    }

    func sharingCompleted(id: UUID) {
        guard currentSharing?.id == id else { return }
        sheet = nil
    }

    func sheetDidDismiss() {
        guard sheetPresentationActive else { return }
        sheetPresentationActive = false
        if let download = currentSharing {
            try? FileManager.default.removeItem(at: download.file.deletingLastPathComponent())
        }
        currentSharing = nil
        DispatchQueue.main.async { [weak self] in
            self?.presentSetupAfterResetIfNeeded()
            self?.showNextShare()
            self?.resumeDialogs()
        }
    }

    private func showNextShare() {
        guard sheet == nil, !sheetPresentationActive, currentSharing == nil, !completedDownloads.isEmpty else { return }
        let next = completedDownloads.removeFirst()
        currentSharing = next
        sheetPresentationActive = true
        sheet = .download(next)
    }

    private func beginDownload(_ download: WKDownload) {
        guard !isResetting else { download.cancel { _ in }; return }
        downloadRecords[ObjectIdentifier(download)] = (download, nil)
        download.delegate = self
    }
}

@MainActor
private final class QueuedDialog {
    let controller: UIAlertController
    weak var source: WKWebView?
    let cancel: () -> Void
    var finished = false
    init(controller: UIAlertController, source: WKWebView?, cancel: @escaping () -> Void) {
        self.controller = controller
        self.source = source
        self.cancel = cancel
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if isResetting && url.absoluteString != "about:blank" { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false && !URLPolicy.allowsNavigation(url) {
            decisionHandler(.cancel)
            confirmExternal(url)
            return
        }
        let fileDownload = URLPolicy.isTrusted(url)
            && url.path.lowercased().hasPrefix("/scripts/verona/download/")
            && ["csv", "xls"].contains(url.pathExtension.lowercased())
        if navigationAction.targetFrame?.isMainFrame == true && URLPolicy.isTrusted(url)
            && !navigationAction.shouldPerformDownload && !fileDownload {
            requestedURLs[ObjectIdentifier(webView)] = url
            clearFramePanes(in: webView)
        }
        decisionHandler(navigationAction.shouldPerformDownload || fileDownload ? .download : .allow)
        if URLPolicy.isTrusted(url) && !navigationAction.shouldPerformDownload && !fileDownload { scheduleFrameDiscovery(in: webView) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           let url = navigationResponse.response.url, !URLPolicy.allowsNavigation(url) {
            decisionHandler(.cancel)
            confirmExternal(url)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.split(separator: ";", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: .whitespaces).lowercased()
        } == "attachment"
        decisionHandler(attachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failures[ObjectIdentifier(webView)] = nil
        clearFramePanes(in: webView)
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isResetting, let navigation, let resetNavigation, navigation === resetNavigation { finishReset(); return }
        refreshState()
        resumeDialogs()
        scheduleFrameDiscovery(in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }

    private func failed(_ view: WKWebView, error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if isResetting {
            isResetting = false
            resetNavigation = nil
            notice = "ログイン状態を消去できませんでした。もう一度お試しください。"
        }
        let message: String
        if error.domain == NSURLErrorDomain && (-1206 ... -1200).contains(error.code) {
            message = "接続先の証明書を確認できません。iPhoneの日時を確認し、解決しない場合はシステム管理者へ連絡してください。"
        } else {
            message = "ネットワークへの接続を確認してください。社内Wi-FiやVPNが必要な場合は、接続してから再試行してください。"
        }
        failures[ObjectIdentifier(view)] = ConnectionFailure(title: "サイトに接続できません", message: message, code: error.code)
        refreshState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isResetting { finishReset(); return }
        failures[ObjectIdentifier(webView)] = ConnectionFailure(title: "画面を再読み込みしてください", message: "画面の表示が中断されました。更新ボタンで接続し直せます。", code: 0)
        refreshState()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { beginDownload(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { beginDownload(download) }
}

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !isResetting else { return nil }
        if let url = navigationAction.request.url, !URLPolicy.allowsNavigation(url) {
            confirmExternal(url)
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        popups.append(BrowserPopup(webView: popup))
        refreshState()
        // WebKit loads the supplied request. Loading it here could resubmit a POST.
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) { removePopup(webView) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard !isResetting else { completionHandler(); return }
        let controller = UIAlertController(title: frame.request.url?.host ?? "サイトからのメッセージ", message: message, preferredStyle: .alert)
        let record = QueuedDialog(controller: controller, source: webView, cancel: completionHandler)
        controller.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak record] _ in
            guard let record else { return }
            self?.resolve(record) { completionHandler() }
        })
        enqueue(record)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard !isResetting else { completionHandler(false); return }
        let controller = UIAlertController(title: frame.request.url?.host ?? "サイトからの確認", message: message, preferredStyle: .alert)
        let record = QueuedDialog(controller: controller, source: webView, cancel: { completionHandler(false) })
        controller.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self, weak record] _ in
            guard let record else { return }
            self?.resolve(record) { completionHandler(false) }
        })
        controller.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak record] _ in
            guard let record else { return }
            self?.resolve(record) { completionHandler(true) }
        })
        enqueue(record)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard !isResetting else { completionHandler(nil); return }
        let controller = UIAlertController(title: frame.request.url?.host ?? "サイトからの入力", message: prompt, preferredStyle: .alert)
        controller.addTextField { $0.text = defaultText }
        let record = QueuedDialog(controller: controller, source: webView, cancel: { completionHandler(nil) })
        controller.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self, weak record] _ in
            guard let record else { return }
            self?.resolve(record) { completionHandler(nil) }
        })
        controller.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak record, weak controller] _ in
            guard let record else { return }
            self?.resolve(record) { completionHandler(controller?.textFields?.first?.text) }
        })
        enqueue(record)
    }
}

extension BrowserModel: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        guard !isResetting, !cancelledDownloads.contains(id),
              downloadRecords[id]?.0 === download else { completionHandler(nil); return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Y3-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (suggestedFilename as NSString).lastPathComponent
            let filename = name.isEmpty || name == "." || name == ".." ? "download" : name
            let destination = folder.appendingPathComponent(filename, isDirectory: false)
            downloadRecords[ObjectIdentifier(download)] = (download, destination)
            completionHandler(destination)
        } catch {
            notice = "ファイルの保存先を用意できませんでした。iPhoneの空き容量を確認してください。"
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let record = downloadRecords.removeValue(forKey: ObjectIdentifier(download)), let file = record.1 else { return }
        if isResetting || cancelledDownloads.contains(ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); return
        }
        let shared = SharedDownload(file: file)
        completedDownloads.append(shared)
        showNextShare()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let record = downloadRecords.removeValue(forKey: ObjectIdentifier(download)), let file = record.1 {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        if (error as NSError).code != NSURLErrorCancelled { notice = "ダウンロードできませんでした：\(error.localizedDescription)" }
    }
}
