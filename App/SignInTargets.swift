import Foundation

/// アプリ内ログインの対象。取り出す値と、その保存先だけが違う。
extension WebSignInView.Target {
    static var claude: WebSignInView.Target {
        WebSignInView.Target(
            loginURL: URL(string: "https://claude.ai/login")!,
            cookieDomain: "claude.ai",
            extract: { cookies in
                cookies.first { $0.name == "sessionKey" }
                    .map(\.value)
                    .flatMap { ClaudeSessionKey.isValid($0) ? $0 : nil }
            },
            verify: nil,
            save: ClaudeSessionKey.save
        )
    }

    /// Grok Bot と Cursor が共有する cursor.com のアカウント。
    /// セッションCookieはHttpOnlyで名前が公になっていないため、名前を決め打ちせず、
    /// 集めたCookieで実際に応答が返るかで成立を判定する。
    static var cursorAccount: WebSignInView.Target {
        WebSignInView.Target(
            loginURL: URL(string: "https://cursor.com/dashboard")!,
            cookieDomain: "cursor.com",
            extract: { cookies in
                let value = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                return CursorSession.isValid(value) ? value : nil
            },
            verify: { await GrokBotCollector.sessionWorks(cookie: $0) },
            save: CursorSession.save
        )
    }
}
