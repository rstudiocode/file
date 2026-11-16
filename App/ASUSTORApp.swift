import FileProvider
import SwiftUI
import UIKit
import WebKit

@main
@MainActor
struct ASUSTORApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var browser = Browser()
    @State private var showFiles = false

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                HStack {
                    Button { browser.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Actualiser l’explorateur")
                    .disabled(!browser.ready)
                    Spacer()
                    Button { showFiles = true } label: {
                        Label("Apple Fichiers", systemImage: "folder")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.65, green: 0.24, blue: 0.13))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                ExplorerView(browser: browser)
            }
            .sheet(isPresented: $showFiles) {
                NavigationStack {
                    Form {
                        Section("Votre NAS") {
                            Text(browser.location ?? "Connectez-vous à votre NAS dans l’explorateur.")
                            if let message = browser.message { Text(message).foregroundStyle(.secondary) }
                            if browser.location != nil {
                                Button("Actualiser les dossiers du NAS") { browser.refreshFiles() }
                            }
                        }
                        Section("Dans l’app Fichiers") {
                            Text("Ouvrez Fichiers → Explorer → ⋯ → Modifier, puis activez l’emplacement ASUSTOR.")
                            Text("Les dossiers affichent leur liste. Le contenu est téléchargé quand Fichiers le demande pour une ouverture, un aperçu ou une copie.")
                            Text("Depuis Fichiers, vous pouvez lire et copier les documents du NAS. Utilisez l’explorateur pour importer ou gérer les fichiers sur le NAS.")
                        }
                    }
                    .navigationTitle("Apple Fichiers")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Terminé") { showFiles = false }
                        }
                    }
                }
            }
            .onChange(of: phase) { value in
                if value == .active { browser.resume() }
            }
        }
    }
}

@MainActor
private struct ExplorerView: UIViewRepresentable {
    @ObservedObject var browser: Browser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver, WKDownloadDelegate {
    @Published private(set) var location: String?
    @Published private(set) var message: String?
    @Published private(set) var ready = false

    let webView: WKWebView
    private var synchronization: Task<Void, Never>?
    private var revision = 0
    private var lastWebValue: String?
    private var seeded = false
    private var registered = false
    private var activeDomain: NSFileProviderDomain?
    private var popups: [ObjectIdentifier: UIViewController] = [:]
    private var downloads: [ObjectIdentifier: URL] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task { await start() }
    }

    private var cookies: WKHTTPCookieStore { webView.configuration.websiteDataStore.httpCookieStore }

    private func start() async {
        do {
            if let shared = try SessionStore.read(), (shared.rememberAcrossLaunch ?? (shared.expiry != nil)),
               let original = shared.httpCookie {
                await cookies.setCookie(original)
                lastWebValue = shared.value
            }
        } catch {
            message = error.localizedDescription
        }
        seeded = true
        cookies.add(self)
        ready = true
        webView.load(URLRequest(url: Relay.origin))
    }

    func resume() {
        guard seeded else { return }
        Task {
            // File Provider may have renewed the same account since the app was last visible.
            if let shared = try? SessionStore.read(), let cookie = shared.httpCookie,
               shared.value != lastWebValue,
               await webCookie()?.value == lastWebValue {
                lastWebValue = shared.value
                await cookies.setCookie(cookie)
            }
            scheduleSync(validate: true)
        }
    }

    func reload() {
        if webView.url == nil { webView.load(URLRequest(url: Relay.origin)) }
        else { webView.reload() }
    }

    func refreshFiles() {
        guard let activeDomain, let manager = NSFileProviderManager(for: activeDomain) else { return }
        Task {
            do {
                try await manager.signalEnumerator(for: .rootContainer)
                try await manager.signalEnumerator(for: .workingSet)
                message = "Actualisation demandée à Fichiers."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { scheduleSync() }

    private func webCookie() async -> RelayCookie? {
        await cookies.allCookies().compactMap(RelayCookie.init).first
    }

    private func scheduleSync(validate: Bool = false) {
        revision += 1
        let requestedRevision = revision
        synchronization?.cancel()
        synchronization = Task {
            do {
                let current = await webCookie()
                guard requestedRevision == revision, !Task.isCancelled else { return }
                if let current {
                    if !validate && lastWebValue == current.value && registered { return }
                    let shared = try SessionStore.read()
                    if !validate, shared?.value == current.value, let profile = shared?.profile,
                       activeDomain?.identifier.rawValue == profile {
                        lastWebValue = current.value
                        registered = true
                        return
                    }
                    let (status, renewed) = try await Relay.shared.status(current)
                    guard requestedRevision == revision, !Task.isCancelled else { return }
                    guard status.connected, let profile = status.profile, let account = status.account else {
                        try await disconnect()
                        if requestedRevision == revision, !Task.isCancelled {
                            let stale = await cookies.allCookies().filter { RelayCookie($0)?.value == current.value }
                            for cookie in stale { await cookies.delete(cookie) }
                        }
                        return
                    }
                    var session = renewed ?? current
                    session.profile = profile
                    session.rememberAcrossLaunch = status.remembered
                    if let shared, shared.value == current.value {
                        if try SessionStore.replace(shared, with: session) == false {
                            if let latest = try SessionStore.read(), latest.profile == profile, latest.value != shared.value {
                                session = latest
                            } else if let latest = try SessionStore.read(), latest.value == shared.value {
                                // Migrate tokens saved by older builds before their fingerprint was indexed.
                                try SessionStore.write(session)
                            } else {
                                return
                            }
                        }
                    } else {
                        try SessionStore.write(session)
                    }
                    lastWebValue = session.value
                    message = status.remembered == true
                        ? "Reconnexion automatique activée."
                        : "Session temporaire. Pour la conserver après fermeture, reconnectez-vous en activant « Rester connecté sur cet appareil »."
                    try await register(profile: profile, account: account)
                    guard requestedRevision == revision, !Task.isCancelled else { return }
                    if session.value != current.value, let restored = session.httpCookie {
                        await cookies.setCookie(restored)
                    }
                } else {
                    try await disconnect()
                }
            } catch {
                if requestedRevision == revision && !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func register(profile: String, account: String) async throws {
        let identifier = NSFileProviderDomainIdentifier(profile)
        let existing = try await NSFileProviderManager.domains()
        try Task.checkCancellation()
        for domain in existing where domain.identifier != identifier {
            try await NSFileProviderManager.remove(domain)
            try Task.checkCancellation()
        }
        let domain = existing.first(where: { $0.identifier == identifier }) ??
            NSFileProviderDomain(identifier: identifier, displayName: "ASUSTOR · " + account)
        if !existing.contains(where: { $0.identifier == identifier }) {
            try await NSFileProviderManager.add(domain)
        }
        try Task.checkCancellation()
        activeDomain = domain
        registered = true
        location = domain.displayName
    }

    private func disconnect() async throws {
        try SessionStore.remove()
        registered = false
        lastWebValue = nil
        activeDomain = nil
        location = nil
        for domain in try await NSFileProviderManager.domains() {
            try Task.checkCancellation()
            try await NSFileProviderManager.remove(domain)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleSync()
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == Relay.origin.host && (url.port == nil || url.port == 443)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, action.targetFrame?.isMainFrame != false,
           ["http", "https"].contains(url.scheme), !sameOrigin(url) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let attachment = disposition?.lowercased().hasPrefix("attachment") == true
        decisionHandler(response.isForMainFrame && (attachment || !response.canShowMIMEType) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme), !sameOrigin(url) {
            UIApplication.shared.open(url)
            return nil
        }
        guard let presenter = topController else { return nil }
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        let content = UIViewController()
        content.view = child
        content.title = "ASUSTOR"
        content.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Fermer", primaryAction: UIAction { [weak self, weak child] _ in
            guard let self, let child else { return }
            if child.url?.path == "/editor.html", child.url.map(self.sameOrigin) == true {
                child.evaluateJavaScript("document.getElementById('leave-editor')?.click()")
            } else {
                self.webViewDidClose(child)
            }
        })
        let sheet = UINavigationController(rootViewController: content)
        sheet.isModalInPresentation = true
        popups[ObjectIdentifier(child)] = sheet
        presenter.present(sheet, animated: true)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        let sheet = popups.removeValue(forKey: ObjectIdentifier(webView))
        sheet?.dismiss(animated: true)
    }

    private var topController: UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = topController else { completionHandler(); return }
        let alert = UIAlertController(title: "ASUSTOR", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = topController else { completionHandler(false); return }
        let alert = UIAlertController(title: "ASUSTOR", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Continuer", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let name = (suggestedFilename as NSString).lastPathComponent
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let url = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "Document" : name)
            downloads[ObjectIdentifier(download)] = url
            completionHandler(url)
        } catch {
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let presenter = topController, let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = presenter.view
        share.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        presenter.present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = downloads.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        message = error.localizedDescription
    }
}
