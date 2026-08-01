//
//  TelegramLogConfig.swift
//  Paladala
//
//  Centralised Telegram Bot API credentials and endpoints for
//  the in-app "上报日志" (report log) button.
//
//  The constants live in this file alone so a token rotation via
//  @BotFather only requires editing one place; every caller
//  (`TelegramLogReporter`) reads from here.
//
//  SECURITY NOTE — the bot token is embedded in the open-source
//  repository.  Anyone who builds the app from source can post
//  to the target channel.  Mitigations:
//    * Treat the channel as an "open inbox" — only the file
//      contents matter; do not route replies back through the
//      bot with elevated permissions.
//    * Rotate the token via @BotFather and update `botToken`
//      below if the previous token is compromised.
//    * If you fork, set your own token + chat ID before
//      shipping a public build.
//

import Foundation

enum TelegramLogConfig {
    /// Bot token issued by @BotFather.  Format: `<bot_id>:<secret>`.
    static let botToken = "8407209108:AAHC4De0vzIh1_IC025LG_4lGCj4xQni56E"
    /// Target channel / supergroup ID.  The leading `-` marks a
    /// supergroup or channel; positive IDs are private chats,
    /// public channels usually start with `-100`.
    static let chatID = "-1003921870047"
    /// Telegram Bot API base.  `sendDocument` is the right
    /// endpoint for file uploads — log exports are well under
    /// the 50 MB ceiling.
    static let apiBase = URL(string: "https://api.telegram.org")!
    /// Request timeout.  `sendDocument` typically returns in
    /// < 5 s on a healthy connection; 30 s covers the cold
    /// path on metered / weak networks.
    static let requestTimeout: TimeInterval = 30
    /// User-Agent.  Telegram records this on the bot side; a
    /// truthful value is more useful than `curl/7.x` when
    /// triaging abuse reports.
    static let userAgent = "Paladala-iOS/0.5.1"
}
