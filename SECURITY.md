# Security and privacy

ccmiss manages network settings on the local Mac. Its security model is based on explicit activation, narrowly scoped routing, authenticated local control, and reversible changes.

## Local data

- SOCKS5 links are stored in owner-readable local application files. They are not encrypted with Keychain. Anyone who can read the files or a machine backup can obtain the credentials.
- The active proxy core and a Clash configuration necessarily receive the selected proxy credentials. Runtime configurations, transaction snapshots, and diagnostic files must remain private.
- Claude Code backups can contain conversations, project paths, tool output, and raw configuration. A backup is not a sanitized public export. Review any Markdown export before sharing it.
- Credential migration, conversation backups, and maintenance operate locally. Preparing a new-session context does not submit it to Claude; the user's subsequent Claude invocation does.

Runtime data belongs in the user's Application Support directory, outside this repository. Do not commit it, attach it to issues, or include it in source releases.

## Network requests

While the main window is visible, ccmiss periodically opens a fresh HTTPS request to `claude.ai/cdn-cgi/trace` to observe that connection's exit IP. It uses an ephemeral session without account cookies or a persisted credential store. The result describes a new application connection; browser-specific proxy extensions and older connections may differ.

Activation checks contact the configured public service endpoints, including Claude, Anthropic, Cloudflare, and Stripe. Optional browser check buttons open third-party diagnostic pages in the default browser's private mode. Those services can observe the connecting IP. The application does not upload local accounts, proxy passwords, or conversation archives to a ccmiss server.

There is no IP reputation scoring client. Green means the current exit was observed or matches the active account's verified exit. It is not an account safety rating.

## Privileged network service

The standalone service requires a matching Developer ID signature, the expected application identifiers and paths, the current console user, and an authenticated application-to-runtime process relationship. Unsigned development code is not allowed to control the privileged service. Building from source must not weaken these checks.

The service controls only its owned core and records DNS restoration state. Optional Clash coexistence uses the existing controller and scoped overlays. It does not intentionally restart Clash or purge existing connections. A configuration reload can still delay new requests, and routing changes can affect application behavior.

## What profile separation means

Profiles separate saved proxy settings and the exit selected for new network connections. They do not create virtual machines, containers, separate browser cookie jars, or separate website logins. ccmiss does not erase server-side history, rotate device identity, or guarantee that a service will accept an account.

## Reporting a vulnerability

Use the repository's private vulnerability reporting feature when available. Do not post credentials, raw conversation archives, full network configurations, or personal addresses in a public issue. For a public issue, provide a minimal reproduction using reserved example domains and documentation IP ranges.

## Source release checks

Run `python3 Tools/check-public-source.py` and `./Tools/verify.sh` before publishing a change. The source tree intentionally excludes builds, downloaded runtimes, signed applications, logs, backups, credentials, and operational handoff material. Automated scanning supplements human review; it is not proof that arbitrary future files contain no private information.
