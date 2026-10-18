# Contributing

Contributions should keep network ownership explicit, preserve unrelated routes and existing tasks, and make recovery state visible.

1. Read [the architecture](docs/architecture.md) and [security model](SECURITY.md).
2. Use only synthetic accounts, reserved documentation IP ranges, and `example.com` / `.test` domains in fixtures. Never add an exported local profile or a real conversation archive.
3. Implement the change, then run the relevant offline checks and `python3 Tools/check-public-source.py`. Network tests must use isolated fixtures and must not modify the developer's live proxy, DNS, TUN, or browser settings.
4. Describe the resulting behavior, validation, and any recovery or compatibility implications in the pull request.

Do not weaken helper signature, process-origin, file-permission, or network-ownership checks to make a local build work. The build uses the developer's own signing identity; signing credentials never belong in the repository.

Original contributions are provided under GPL-3.0-or-later. Third-party components retain their own licenses; preserve their notices and source availability requirements.
