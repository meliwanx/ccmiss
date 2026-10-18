# ccmiss

<p align="center">
  <img src="Resources/Brand/ccmiss-logo.png" width="136" height="136" alt="ccmiss app logo">
</p>

**A clearer network environment for Claude on macOS.**

[English](README.md) · [简体中文](README.zh-CN.md)

Check your environment, configure privacy settings, and switch account-specific SOCKS5 exits from one small native app. ccmiss brings routing, DNS, browser WebRTC checks, and Claude exit monitoring into a single workflow—so you can see what is active before you start working.

**Add a proxy. Prepare once. Switch when you need to.**

## A look inside

The app interface is currently in Simplified Chinese. Account details in these screenshots have been redacted.

![ccmiss account workspace with account details redacted](docs/images/account-workspace.png)

*Account workspace: network status and profile controls in one compact view.*

<details>
<summary>More screenshots: adding a profile and Claude Code tools</summary>

**Add a SOCKS5 profile**

![Add a SOCKS5 account profile in ccmiss, with sensitive details redacted](docs/images/add-profile.png)

*Keep a proxy URL, account label, and description together in one profile.*

**Claude Code tools**

![ccmiss Claude Code tools for local conversation backups and installation maintenance](docs/images/claude-code-tools.png)

*Browse local conversation backups and access user-initiated maintenance tools.*

</details>

## What you get

| Feature | What it does |
| --- | --- |
| Account profiles | Save multiple SOCKS5 proxies with names and descriptions. Distinguish the selected profile from the profile actually in use. |
| One-click switching | Apply a profile to supported services, or stop the override and return to the previous system network. |
| Claude exit monitoring | Make a fresh HTTPS request to Claude and show the observed exit IP, active mode, and check time in the sidebar. |
| Exit consistency | Compare the observed Claude IP with the verified account exit. Green means confirmed consistency; red means a mismatch; gray means unconfirmed. |
| Environment checks | Inspect network-service authorization, conflicting tunnels, proxy readiness, and browser protection status. |
| DNS and WebRTC setup | Configure managed DNS routing and supported browser WebRTC preferences, with backups and explicit status. |
| Standalone networking | Run with a bundled Mihomo core and native macOS background service. Clash is optional. |
| Optional Clash coexistence | Use an already running Clash Verge Rev instance to override only supported service routes. |
| Private browser checks | Open Claude, Cloudflare, DNS, and WebRTC check pages in a supported default browser's private window. |
| Claude Code tools | Back up and browse local conversations, prepare readable context for a new session, and explicitly run supported installation maintenance. |

Designed for people who use several accounts or proxy exits and want fewer manual edits, clearer status, and a repeatable setup.

## The everyday workflow

1. **Add an account profile.** Enter a label, an optional description, and a SOCKS5 URL:

   ```text
   socks5://USERNAME:PASSWORD@203.0.113.10:1080
   ```

   This is an example address, not a working proxy. Percent-encode reserved characters in credentials.

2. **Prepare this Mac once.** Open Software Settings. In standalone mode, authorize the network service through macOS. If supported Clash coexistence is available, ccmiss uses that path instead. Browser protection is a separate setting shared by all account profiles.
3. **Enable the profile.** ccmiss checks the candidate route before applying it and validates the resulting configuration. Selecting a row alone does not change your network.
4. **Check the sidebar.** Read the actual active account or system mode and the latest observed Claude exit. Refresh manually when needed; checks also update periodically while the app is visible.
5. **Switch or restore.** Choose another profile and apply it, or use **Stop and restore system network** on the active profile.

Opening the app or saving a new profile does not, by itself, activate a new proxy.

## Two ways to run

### Standalone

ccmiss manages its own signed network service and Mihomo core. The default scope routes Claude/Anthropic, Cloudflare's own services, Stripe/Link, and supported check endpoints through the account proxy. Local-network traffic and other traffic follow the generated routing rules. An optional public-network scope routes more traffic and rejects unsupported public UDP.

The service saves the DNS values it changes and restores values it still owns when you stop it. It checks for conflicting VPNs and unsupported network conditions before taking over. A confirmed standalone setup can remember the activation intent and attempt to resume it on login when conditions permit.

### With Clash Verge Rev

If a supported Clash Verge Rev core is already running, ccmiss can add a scoped account override to it. Supported service routes and their DNS policies use the account exit; unrelated Clash settings continue to operate as before.

ccmiss does not need to restart Clash, stop its TUN, or clear all connections to switch profiles. It checks the managed overlay before changing or withdrawing it and keeps recovery records when restoration cannot be confirmed. This integration is specific to supported Clash Verge Rev layouts, not every application named Clash.

**Switches apply to new connections.** Existing connections may keep their previous exit until they finish. Browser extensions, application-specific proxies, and pooled browser connections may also use a different path from the app's probe.

## Know what the status means

The sidebar's Claude IP comes from a new request to `https://claude.ai/cdn-cgi/trace` through the current macOS network path. It is not copied from a proxy's hostname. A proxy server address and its actual public exit can differ.

| Color | Meaning |
| --- | --- |
| Green | The account's observed exit matches its verified exit, or a current system-mode exit was successfully observed. |
| Red | The account's observed exit differs from its verified exit. |
| Gray | The result is pending, unavailable, or no longer valid for the current network state. |

Colors describe **connection and exit consistency**, not IP reputation. ccmiss has no IP reputation scoring service, blacklist certification, or paid IP quality API. DNS tests report resolver addresses, which do not have to equal the website-visible exit IP.

## Browser privacy checks

Supported Chromium browsers include Chrome, Edge, and Brave. ccmiss can back up and update existing profile preferences to limit unproxied WebRTC UDP. It writes only while the browser is fully closed and may require macOS file-access permission. New browser profiles should be checked again; extensions or managed policies can override preferences.

Check buttons open external `ip.net.coffee` pages in private windows using supported Chrome/Chromium, Edge, Brave, or Firefox launch arguments. Unsupported browsers receive a clear message; the app does not silently substitute an ordinary window. Private browsing does not create a separate network identity.

## Claude Code conversations and maintenance

- Create a **full backup** or select a **start/end time range**, including an “until now” option.
- Browse readable conversation content in the app and open Markdown files locally.
- Prepare recent readable text as context for a **new** Claude Code session. Preview it before explicitly launching the session; at launch, it is sent to the service selected by the current Claude Code configuration.
- Delete backups and eligible related files after confirmation, with size information and protection for unfinished maintenance recovery.
- Explicitly request supported native-install maintenance. The workflow checks for running Claude clients, backs up first, and preserves recovery material. It does not terminate running tasks or automatically replace custom launchers, npm, or Homebrew installations.

Readable content migration does not restore old session, message, device, or login state. A time-range backup is not a full installation rollback package. Raw backup and recovery copies can contain credentials and old identifiers; they stay local and must be treated as sensitive. Review any exported text before sharing it.

## Privacy and boundaries

Account metadata, complete proxy URLs, settings, and backups are stored locally under `~/Library/Application Support/AccountProxySwitcher/`. Private directories use owner-only permissions; credential files use `0600`. **Proxy credentials are local plaintext, not in Keychain or an encrypted vault.** Protect your macOS account and backups accordingly.

Network checks contact the relevant service endpoints. Browser checks contact the external check website. These requests expose the connecting exit IP to those services, as ordinary requests do. Backing up or browsing conversations does not upload them; launching a prepared new Claude session is a separate, confirmed action.

Account separation here means **separate routing profiles and proxy exits**. ccmiss does not create browser containers, isolate cookies or login sessions, impersonate devices, or erase server-side records. It does not guarantee account safety or prevent bans. Use services in accordance with their terms and supported locations.

ccmiss is an independent project and is not affiliated with or endorsed by Anthropic, Cloudflare, Stripe, or Clash Verge Rev. These names identify compatibility targets. See [SECURITY.md](SECURITY.md) and [architecture notes](docs/architecture.md) for the security boundaries.

## Build from source

This repository provides source code and build instructions. It does not include personal runtime settings, proxy credentials, conversation backups, local handoff records, signing certificates, or prebuilt application packages.

Current target: **Apple Silicon, macOS 13.5 or later**. The application interface is currently in Simplified Chinese; bilingual documentation does not imply an English app interface.

You need Xcode Command Line Tools, Python 3, and your own Developer ID Application signing identity. The app and privileged service must share the configured signing team. Dependency downloads are pinned and verified by the preparation script; see [third-party notices](THIRD_PARTY_NOTICES.md).

```sh
./Tools/fetch-dependencies.sh

export ACCOUNT_PROXY_SIGN_IDENTITY='Developer ID Application: YOUR NAME (YOUR_TEAM_ID)'
export ACCOUNT_PROXY_TEAM_ID='YOUR_TEAM_ID'

./build.sh
```

Dependencies are prepared under `.deps/darwin-arm64/`. Use `ACCOUNT_PROXY_NODE` to select a Node.js executable if needed; the build checks its supported version and architecture. The output is `dist/ccmiss.app`.

Building does not register the service or switch the current network. A developer's signing identity is required for the supported privileged-service workflow; unsigned source checks are not an unsigned TUN installation method. Developer ID signing and Apple notarization are separate; the build does not submit anything to Apple for notarization.

To try your build, place it in `/Applications`, open it, add your own proxy, and follow the setup checks. Stop ccmiss networking and confirm restoration before removing the app or disabling its background service.

## Source checks

```sh
python3 Tools/check-public-source.py
./Tools/verify.sh
```

The public-source check helps detect accidental local data and credentials. Verification runs the project's isolated checks; it is not permission to take over your real network or reinstall Claude Code. Privileged TUN, DNS restoration, login recovery, and VPN coexistence still need controlled end-to-end testing on a suitable Mac before distribution.

| Source | Responsibility |
| --- | --- |
| `Sources/AccountProxySwitcher/` | SwiftUI app, profile storage, environment checks, browser preferences, Claude exit probe, conversation tools UI. |
| `Sources/AccountProxyService/` | Native privileged service, signed-client validation, core ownership, DNS lifecycle, recovery. |
| `Resources/` | Network orchestration and Claude Code tools backends; pinned dependency metadata. |
| `Tools/` | Dependency preparation, signing/build steps, public-source checks, and isolated verification. |

Before sharing logs, issues, or screenshots, remove proxy URLs, account labels, local paths, tokens, and conversation content. Do not commit the app's runtime data directory.

## License

ccmiss is licensed under **GPL-3.0-or-later**. See [LICENSE](LICENSE). Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the pinned provenance metadata. The Mihomo core is used without changes to its upstream source.
