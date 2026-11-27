# Launcher updates

The launcher checks for a newer stable release at startup and every six hours while its window is visible. **About launcher → Check for updates…** checks immediately. Checks use the public GitHub endpoint `https://api.github.com/repos/kolyanok/firestorm-macos-launcher/releases/latest`, with no account, cookies, or token.

A newer release appears in the launcher with **Download update**. Once the archive has downloaded and passed verification, **Install and restart** prepares and replaces the application, then opens the new version. Checks and downloads do not block playing. Installation requires WoW to be closed and any game installation, repair, or other operation to finish first.

Only stable numeric `X.Y.Z` versions newer than the installed version are accepted. The expected asset is `Firestorm-Launcher-X.Y.Z-macOS-Universal.zip` in this repository's matching release. The download must use HTTPS; redirects are restricted to GitHub's asset hosts. The downloaded size and SHA-256 must match GitHub's release metadata. Releases without a SHA-256 remain available through **Release notes**, but cannot install through the updater.

Before extraction, the archive is checked for unsafe paths, links, duplicate names, encryption, and excessive sizes. The extracted application must have the production bundle identifier, expected version, valid code signature, and both supported executable architectures. The project currently uses ad hoc signing; this check verifies bundle integrity rather than a Developer ID publisher identity. Trust comes from the fixed repository, HTTPS, and GitHub's asset digest.

The replacement is staged in a private folder next to the installed application. A separate helper waits for the old launcher process to exit, rechecks the target version, then renames the application and reopens it. Move or reopen failures restore the previous application. This rollback does not detect a later crash after macOS has accepted the launch. Installed WoW clients, game data, add-ons, and preferences are outside the replacement.

The installed application and its parent directory must be writable. App Translocation, read-only locations, and test copies cannot install updates; move the regular launcher into Applications or another writable location, or install the GitHub release manually.

GitHub's release and digest fields are documented in the [Releases REST API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release) and [Release assets REST API](https://docs.github.com/en/rest/releases/assets).
