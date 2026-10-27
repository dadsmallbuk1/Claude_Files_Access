# Claude Files Access

Let Claude browse, read and change files in the iOS **Files** app — built for troubleshooting Windows games running under Wine in **Madeira** on iPhone and iPad.

Claude can explore a Wine prefix, read and tail logs, search for files and text, check whether a DLL is 32- or 64-bit, edit configs, download and unpack DXVK/VKD3D releases, and swap DLLs. Every change is backed up first and can be undone.

```
Claude (iPhone app / web / desktop)
        │  MCP over HTTPS
        ▼
Cloudflare Worker relay   ← you deploy this once (free plan)
        │  WebSocket (the app connects out; nothing to open on your network)
        ▼
Claude Files app on your iPhone/iPad  ──►  folders you picked in Files (e.g. On My iPhone › Madeira)
```

The relay stores nothing. It only forwards requests between Claude and the app, and is protected by a long random secret in the URL.

## What's in this repo

| Path | What it is |
| --- | --- |
| `relay/` | Cloudflare Worker + Durable Object: the MCP endpoint Claude talks to. TypeScript, with tests. Its Wrangler config is `wrangler.toml` at the repo root. |
| `ios/ClaudeFilesAccess/` | SwiftUI app (universal iPhone + iPad): folder picker, connection, activity log, backups. |
| `ios/Packages/FilesCore/` | Swift package with all the file tools, archive extraction, backups/undo. Unit-tested. |
| `ios/project.yml` | XcodeGen spec for the Xcode project. |
| `.github/workflows/build.yml` | CI: runs tests and builds an **unsigned IPA** for sideloading. |

## Setup

### 1. Deploy the relay (once, ~5 minutes)

You need a free Cloudflare account and Node.js on any computer. No computer? Use the Cloudflare dashboard option below.

```sh
cd relay
npm install
npx wrangler login      # opens a browser to sign in to Cloudflare
npx wrangler deploy
```

Wrangler prints your relay URL, e.g. `https://claude-files-relay.<your-subdomain>.workers.dev`. Opening it in a browser should show "Claude Files Access relay is running."

**Without a computer (from the Cloudflare dashboard, works on a phone):**

1. Go to **Workers & Pages › Create application** and choose **Import a repository** (GitHub). Authorize the Cloudflare GitHub app for this repository if asked.
2. Select this repository (or your fork) and set:
   - **Project / Worker name:** `claude-files-relay` (must match `name` in `wrangler.toml`)
   - **Branch:** `main`
   - **Build command:** leave empty
   - **Deploy command:** `npx wrangler deploy`
   - **Root directory / Path:** leave empty (the repo root holds `wrangler.toml`)
3. Select **Save and Deploy**. When the build finishes, the Worker page shows its URL, `https://claude-files-relay.<your-subdomain>.workers.dev`. If this is your first Worker, Cloudflare asks you to pick the `workers.dev` subdomain.

After that, every push to `main` that changes the relay redeploys it automatically.

### 2. Install the app (sideload)

1. Open the **Actions** tab of this repo, click the latest successful **Build** run, and download the `ClaudeFilesAccess-ipa` artifact (a zip containing `ClaudeFilesAccess.ipa`). Tagged versions (`v*`) also appear under **Releases**.
2. Install the IPA with **AltStore**, **SideStore**, **Sideloadly** or **TrollStore**, the same way you installed Madeira. AltStore/SideStore re-sign it with your Apple ID; with a free Apple ID that lasts 7 days, so keep your refresh routine.

*Prefer Xcode?* On a Mac: `brew install xcodegen && cd ios && xcodegen generate && open ClaudeFilesAccess.xcodeproj`, pick your team under *Signing & Capabilities*, and run on your device.

### 3. Connect the app

1. Open **Claude Files** on your iPhone/iPad.
2. Paste your relay URL into the **Relay** field. The status should turn green (**Connected**).
3. Tap **Add Folder** and choose **On My iPhone › Madeira** (or **On My iPad › Madeira**). Add other folders too if you want, e.g. **Downloads** for staging files.
   - Folders appear to Claude by name: `Madeira/...`, `Downloads/...`. Long-press a folder to rename it.
4. Tap **Copy URL** under *Connector URL for Claude*.

### 4. Add the connector in Claude

In Claude (claude.ai on the web, or the desktop app): **Settings › Connectors › Add custom connector**, give it a name like *iPhone Files*, and paste the connector URL. Leave the OAuth fields empty. Connectors you add there also show up in the Claude iPhone/iPad app.

In a chat, enable the connector from the tools menu, then ask something like:

> My game crashes on launch in Madeira. Look through my Madeira folder, find the most recent logs, and tell me what's going wrong.

> Install DXVK 2.4 into my prefix: download it from GitHub, extract it, and copy the x64 DLLs to system32 and the x32 DLLs to syswow64.

## Using it day to day

- **Running under LiveContainer?** The Files picker may open but refuse to select a folder. Either enable **Fix File Picker** in LiveContainer's settings for Claude Files, or tap **Browse Folders Directly** in the app: apps inside LiveContainer can see each other's data folders, so you can open Madeira's folder (labelled with its app ID) and tap **Share This Folder**.
- **Keep the app open while Claude works.** iOS suspends apps in the background, which disconnects the relay (the app reconnects automatically when you return). Typical flow: run the game in Madeira → switch to Claude Files → chat with Claude. On **iPad**, put Claude Files in Split View or Slide Over next to Madeira. *Keep Screen Awake* stops the screen locking while connected.
- **Allow Changes** off = read-only. Claude is told when changes are disabled.
- **Undo:** ask Claude to "list recent changes" or "undo that change". Backups also appear in **Files › On My iPhone › Claude Files › Backups**, so you can restore files by hand. Clear them from the app when you don't need them.
- **Activity** in the app shows every request Claude made.
- **Log:** the app writes a log to **Files › On My iPhone › Claude Files › Logs › app.log** (view or share it from the app's *Log* section). It records launches, connection changes, tool calls, folder-picker steps and any main-thread freezes. Claude can read it too, through the built-in `AppData` folder.
- **New secret:** *Generate New Secret* invalidates the old connector URL immediately. Update the connector in Claude afterwards.

## Tools Claude gets

| Tool | Purpose |
| --- | --- |
| `device_status` | Is the app connected, which folders are shared, are changes allowed |
| `list_directory` | List a folder, optionally as a tree (`depth`); symlinks are shown but not followed |
| `file_info` | Size/dates, text encoding, SHA-256, and **PE architecture** (x86/x64) for `.dll`/`.exe` |
| `read_file` | Read text (UTF-8/UTF-16/ANSI auto-detected) with paging; images come back viewable; `base64` for binaries |
| `tail_file` | Last N lines of a log |
| `search` | Find files by name glob and/or text/regex inside files |
| `recent_files` | Most recently modified files (what changed after the last launch?) |
| `write_file` | Create/overwrite/append (text keeps the file's existing encoding; base64 for binaries) |
| `edit_file` | Exact find-and-replace in text files; keeps UTF-16/BOM and Windows CRLF line endings |
| `make_directory`, `copy`, `move`, `delete` | File management, across folders too (e.g. Downloads → prefix) |
| `download_url` | Download straight to the device |
| `extract_archive` | `.zip`, `.tar`, `.tar.gz`, `.tar.xz`, `.tar.zst` (VKD3D-Proton), with `strip_components` and `list_only` |
| `job_status` | Follow up on long downloads/extractions |
| `list_changes`, `undo_change` | Change history and one-step undo |

`.7z` and `.rar` aren't supported. Extract those with another app into a shared folder.

## Security notes

- Anyone with the connector URL can reach the shared folders while the app is connected, so treat it like a password. Regenerate the secret if it leaks.
- Claude can only reach folders you added in the app. Paths can't escape them with `..`, and symlinks are never followed when listing or searching.
- Only one device can be connected per secret; a new connection replaces the old one.

## Development

```sh
# Relay
cd relay && npm install && npm run typecheck && npm test
npx wrangler dev            # local relay at http://localhost:8787

# iOS core (macOS)
swift test --package-path ios/Packages/FilesCore

# App
cd ios && xcodegen generate && open ClaudeFilesAccess.xcodeproj
```

Tool definitions live in `relay/src/tools.ts` (what Claude sees) and are implemented in `ios/Packages/FilesCore/Sources/FilesCore/ToolRouter.swift` and the `*Tools.swift` files next to it. Keep the two in sync.

Limits: individual results are capped at ~1 MB to keep them a sensible size for Claude's context, so `read_file` reads at most 256 KB per call and large images are downscaled before being sent.
