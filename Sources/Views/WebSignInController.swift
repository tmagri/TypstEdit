import AppKit
import WebKit

/// Turns what the user typed in the sign-in sheet into the URL the window
/// opens. Separate from the view so the rule — a bare host always gets https —
/// can be tested without a window.
enum WebSignInAddress {
    /// A bare host gets https, because a login over http would leak the very
    /// password this window exists to protect. An explicit scheme is honoured
    /// as typed: `http://` is a deliberate choice the user made.
    static func resolve(_ raw: String, path: String = "") -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), url.host != nil else { return nil }
            return url
        }
        guard let base = URL(string: "https://" + trimmed), let host = base.host else { return nil }
        let suffix = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return base }
        // A path the user typed starts at the host root.
        return URL(string: "https://" + host + (suffix.hasPrefix("/") ? suffix : "/" + suffix)) ?? base
    }
}

/// The sign-in window for `web_fetch`: a real browser view of the site, in
/// its own empty cookie jar, with no app chrome over it.
///
/// The password never reaches TypstEdit. The user types it into the site's
/// own form inside this `WKWebView`, the way they would in Safari; what gets
/// saved afterwards is only the session cookies the site issued. That is the
/// whole point of doing this in WebKit rather than with a username/password
/// field: SSO, two-factor prompts, "Sign in with Google" and captchas all
/// work, and none of them require storing a password.
///
/// The data store is `nonPersistent()`, so nothing survives the window being
/// closed unless the user explicitly saves, and a sign-in to one site cannot
/// leak into a sign-in for another.
@MainActor
final class WebSignInController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    /// One sign-in window at a time. Opening a second one while the first is
    /// still on screen would present two cookie jars for the same site and no
    /// way to tell which one the user meant.
    static let shared = WebSignInController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var dataStore: WKWebsiteDataStore?
    private var targetHost: String = ""
    private var completion: ((WebSiteSession?) -> Void)?
    private var saveButton: NSButton?
    private var statusLabel: NSTextField?
    private var cookieObserver: NSObjectProtocol?

    private override init() { super.init() }

    /// Opens the window at `url` and calls `completion` once — with the saved
    /// session, or nil if the user cancelled or closed the window.
    ///
    /// `completion` is called exactly once, whichever way the window goes
    /// away, so a caller that awaits this never hangs.
    func present(url: URL, completion: @escaping (WebSiteSession?) -> Void) {
        close()  // A previous sign-in that was never resolved gets cancelled.
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            completion(nil)
            return
        }
        targetHost = host
        self.completion = completion

        let store = WKWebsiteDataStore.nonPersistent()
        dataStore = store

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        // No persistent process pool either: a fresh one per sign-in.
        configuration.processPool = WKProcessPool()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in — \(host)"
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContentView(webView: webView, host: host)
        self.window = window

        // A cookie change is the real signal that the sign-in worked, and it
        // can arrive without a navigation finishing (an SPA posting a login
        // form in place). Watching the store keeps "Save sign-in" from staying
        // disabled on a page that never reloads.
        cookieObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "WKHTTPCookieStoreDidChange"), object: store.httpCookieStore, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSaveButton() }
        }

        var request = URLRequest(url: url)
        request.setValue("com.tmagri.TypstEdit", forHTTPHeaderField: "X-Requested-With")
        webView.load(request)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateSaveButton()
    }

    /// Closes the window as a cancellation, if one is open.
    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        tearDownWebView()
        finish(with: nil)
    }

    private func tearDownWebView() {
        webView?.stopLoading()
        webView = nil
        dataStore = nil
        if let cookieObserver {
            NotificationCenter.default.removeObserver(cookieObserver)
            self.cookieObserver = nil
        }
    }

    /// Calls the completion, once, and forgets it.
    private func finish(with session: WebSiteSession?) {
        guard let completion else { return }
        self.completion = nil
        completion(session)
    }

    // MARK: - Chrome

    private func buildContentView(webView: WKWebView, host: String) -> NSView {
        let container = NSView()

        let explanation = NSTextField(labelWithString: "Sign in to \(host) below. TypstEdit sees only the cookies the site sets — never your password. The password is typed into the site's own page, exactly as in Safari.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 2

        let status = NSTextField(labelWithString: "Waiting for pages from \(host)…")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        statusLabel = status

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"  // Escape

        let save = NSButton(title: "Save sign-in", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.isEnabled = false
        saveButton = save

        let buttons = NSStackView(views: [status, NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [explanation, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)

        for view in [webView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: webView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Saving

    /// Enables "Save sign-in" only once the site has actually set a cookie
    /// for the host the user asked to sign in to. Before that there is
    /// nothing to save, and an enabled button would promise a session the
    /// next fetch could not use.
    private func updateSaveButton() {
        Task { [weak self] in
            guard let self, let dataStore = self.dataStore else { return }
            let cookies = await dataStore.httpCookieStore.allCookies()
            let relevant = cookies.filter { self.applies($0, to: self.targetHost) }
            await MainActor.run {
                self.saveButton?.isEnabled = !relevant.isEmpty
                if let status = self.statusLabel {
                    status.stringValue = Self.describe(relevant, host: self.targetHost)
                }
            }
        }
    }

    /// A cookie belongs to this sign-in when its domain is the target host or
    /// a parent of it, or when the target host is itself a subdomain the
    /// cookie covers. Cookies for unrelated third parties (analytics, ad
    /// networks) are deliberately left out of what gets saved.
    private func applies(_ cookie: HTTPCookie, to host: String) -> Bool {
        let target = host.lowercased()
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !domain.isEmpty else { return false }
        return target == domain || target.hasSuffix("." + domain) || domain.hasSuffix("." + target)
    }

    private static func describe(_ cookies: [HTTPCookie], host: String) -> String {
        guard !cookies.isEmpty else { return "No cookie from \(host) yet — finish signing in." }
        let names = cookies.prefix(3).map(\.name).joined(separator: ", ")
        let more = cookies.count > 3 ? ", …" : ""
        return "\(cookies.count) cookie\(cookies.count == 1 ? "" : "s") from \(host) (\(names)\(more))"
    }

    @objc private func saveTapped() {
        guard let dataStore, let window else { return }
        saveButton?.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let cookies = await dataStore.httpCookieStore.allCookies()
            let relevant = cookies.filter { self.applies($0, to: self.targetHost) }
            let session = WebSiteSession(
                host: self.targetHost,
                cookies: relevant.map(StoredCookie.init(cookie:)),
                savedAt: Date()
            )
            await MainActor.run {
                self.window = nil
                window.delegate = nil
                window.orderOut(nil)
                window.close()
                self.tearDownWebView()
                WebSessionStore.shared.save(session)
                self.finish(with: session)
            }
        }
    }

    @objc private func cancelTapped() {
        close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The user closed the window without saving: that is a cancellation.
        // Clearing the delegate first keeps the explicit close path and this
        // one from both calling `finish`.
        guard window != nil else { return }
        window = nil
        tearDownWebView()
        finish(with: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateSaveButton()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateSaveButton()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusLabel?.stringValue = "Could not load the page: \(error.localizedDescription)"
    }

    /// Only http(s) inside this window. A page that tries to hand the sign-in
    /// to a `file:`, `data:` or custom-scheme URL would be routing around the
    /// one thing this window is for.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            // Hand anything else to the system (an `mailto:`, an app link)
            // rather than loading it in this view.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
