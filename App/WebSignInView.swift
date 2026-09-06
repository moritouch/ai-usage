import SwiftUI
import WebKit

/// 対象サイトへアプリ内でログインしてもらい、その WebView が受け取った Cookie から
/// 必要な分だけを取り出す。
///
/// 利用者にブラウザの開発者ツールを開かせないための入口。データストアは
/// 使い捨て（`.nonPersistent()`）にしてあるので、ログインセッションがディスクへ残らず、
/// 取り出した値だけが Keychain に入る。
struct WebSignInView: View {
    struct Target {
        let loginURL: URL
        let cookieDomain: String
        /// 集まった Cookie から保存する文字列を組み立てる。足りなければ nil。
        let extract: ([HTTPCookie]) -> String?
        /// ログインが成立したかを実際の応答で確かめる。
        /// Cookie 名が公開されていない相手では、名前を決め打ちするより確実。
        /// nil なら extract が返った時点で成立とみなす。
        let verify: ((String) async -> Bool)?
        let save: (String) -> Bool
    }

    let target: Target
    let language: AppLanguage
    let titleKey: String
    let onCaptured: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text(titleKey, language: language))
                    .font(.headline)
                Spacer()
                Button(L10n.text("signIn.cancel", language: language), action: onCancel)
                    .controlSize(.small)
            }
            .padding(12)

            Divider()

            SignInWebView(target: target, onCaptured: onCaptured)

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

private struct SignInWebView: NSViewRepresentable {
    let target: WebSignInView.Target
    let onCaptured: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(target: target, onCaptured: onCaptured)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 使い捨てのストア。ログイン状態をディスクへ残さない。
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let store = configuration.websiteDataStore.httpCookieStore
        store.add(context.coordinator)
        context.coordinator.start(watching: store)
        webView.load(URLRequest(url: target.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver {
        private let target: WebSignInView.Target
        private let onCaptured: () -> Void
        private var store: WKHTTPCookieStore?
        private var poll: Timer?
        private var delivered = false
        private var checking = false

        init(target: WebSignInView.Target, onCaptured: @escaping () -> Void) {
            self.target = target
            self.onCaptured = onCaptured
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
        private func finish(with value: String) {
            guard !delivered, target.save(value) else { return }
            delivered = true
            stop()
            onCaptured()
        }

        @MainActor
        private func check() {
            guard !delivered, !checking, let store else { return }
            let domain = target.cookieDomain
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.delivered else { return }
                let matching = cookies.filter { $0.domain.contains(domain) }
                guard !matching.isEmpty, let value = self.target.extract(matching) else { return }

                guard let verify = self.target.verify else {
                    self.finish(with: value)
                    return
                }
                // 確認中に次のtickが走らないよう先に止める。失敗したら再開する。
                self.checking = true
                Task { @MainActor in
                    let ok = await verify(value)
                    self.checking = false
                    if ok { self.finish(with: value) }
                }
            }
        }
    }
}
