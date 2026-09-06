import SwiftUI
import WebKit

/// claude.ai へアプリ内でログインしてもらい、その WebView が受け取った
/// `sessionKey` Cookie だけを取り出す。
///
/// 利用者にブラウザの開発者ツールを開かせないための入口。データストアは
/// 使い捨て（`.nonPersistent()`）にしてあるので、ログインセッションが
/// ディスクへ残らず、取り出した鍵だけが Keychain に入る。
struct ClaudeSignInView: View {
    let language: AppLanguage
    let onCaptured: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("signIn.title", language: language))
                    .font(.headline)
                Spacer()
                Button(L10n.text("signIn.cancel", language: language), action: onCancel)
                    .controlSize(.small)
            }
            .padding(12)

            Divider()

            ClaudeSignInWebView(onSessionKey: { key in
                guard ClaudeSessionKey.save(key) else { return }
                onCaptured()
            })

            Divider()

            Text(L10n.text("signIn.detail", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 660)
        .environment(\.locale, language.locale)
    }
}

private struct ClaudeSignInWebView: NSViewRepresentable {
    let onSessionKey: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSessionKey: onSessionKey) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 使い捨てのストア。ログイン状態をディスクへ残さない。
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let store = configuration.websiteDataStore.httpCookieStore
        store.add(context.coordinator)
        context.coordinator.start(watching: store)

        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver {
        private let onSessionKey: (String) -> Void
        private var store: WKHTTPCookieStore?
        private var poll: Timer?
        private var delivered = false

        init(onSessionKey: @escaping (String) -> Void) {
            self.onSessionKey = onSessionKey
        }

        /// 観測通知だけに頼らない。macOS 26 以降、ネットワークプロセスが受け取った
        /// `Set-Cookie` が WebView 側のストアへすぐ現れないことがあるため、
        /// 取れるまで一定間隔でも確かめる。
        func start(watching store: WKHTTPCookieStore) {
            self.store = store
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        }

        func stop() {
            poll?.invalidate()
            poll = nil
            if let store { store.remove(self) }
            store = nil
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in self.check() }
        }

        @MainActor
        private func check() {
            guard !delivered, let store else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.delivered else { return }
                guard let cookie = cookies.first(where: {
                    $0.name == "sessionKey" && $0.domain.contains("claude.ai")
                }), ClaudeSessionKey.isValid(cookie.value) else { return }

                self.delivered = true
                self.stop()
                self.onSessionKey(cookie.value)
            }
        }
    }
}
