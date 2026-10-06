# claude-usage-bar

A macOS menu bar item showing your Claude Code and Codex plan usage, styled after
[Omarchy](https://github.com/basecamp/omarchy)'s agent usage panel.

The menu bar shows the Claude session and weekly limits (`✳︎ 18% · 21%`). Clicking it opens a panel with:

- **Limits**: session, weekly and per-model weekly limits, with reset countdowns.
- **Tokens by day**: the last 7 days.
- **Tokens by model**: the last 7 or 30 days, or all history.
- **Settings**: color themes and custom colors, font and size, menu bar format, refresh interval,
  and notifications when a limit crosses a threshold.

## Where the numbers come from

It mirrors Omarchy's `omarchy-agent-usage-claude` and `omarchy-agent-usage-codex` collectors:

| | Limits | Tokens |
|---|---|---|
| Claude Code | `https://api.anthropic.com/api/oauth/usage`, with the Claude Code login token from the Keychain (`Claude Code-credentials`) or `~/.claude/.credentials.json` | Transcripts in `~/.claude/projects` |
| Codex | `codex app-server` JSON-RPC (`account/rateLimits/read`), only while the Codex tab is open | Session rollouts in `~/.codex/sessions` |

Transcripts are indexed in `~/Library/Caches/com.belerico.claude-usage/`, so after the first
scan only new lines are read. The app never refreshes the OAuth token itself (that would rotate
Claude Code's refresh token); if it expires, running `claude` refreshes it. Or click the error in
the panel to run `claude auth login`: its sign-in page opens in the Chrome profile signed in to
your Claude account's email (from `~/.claude.json`), or in the default browser if there is none.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`); no Xcode project.

```sh
./install.sh            # build ~/Applications/ClaudeUsage.app and start it at login
./install.sh uninstall  # remove the app, its LaunchAgent and its cache
```

`~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --dump` prints what the panel would show.
Logs: `log show --last 1h --predicate 'subsystem == "com.belerico.claude-usage"'`.

The usage endpoint and the Codex app-server API are undocumented and may change.

## License

[MIT](LICENSE)
