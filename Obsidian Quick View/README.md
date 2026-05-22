# Obsidian Quick View

A tiny `.exe` that becomes the default handler for `.md` files. Double-click any markdown file anywhere on disk and it opens in Obsidian — without forcing the whole filesystem to live inside a vault.

## What it does

When you double-click a `.md` file in File Explorer, this exe runs and:

1. **If the file is already inside your main Obsidian vault** → just fires `obsidian://open?vault=...&file=<relative-path>` so Obsidian opens it in place. No copy, no extra files, no watcher.
2. **If the file is outside your vault** → copies it to a `TEMP/` subfolder inside your vault, fires the same `obsidian://` URL pointing at the copy, then watches Obsidian's `workspace.json`. When the tab containing the copy is closed, the copy is auto-deleted. A `HKCU\…\RunOnce` key is registered as a belt-and-suspenders cleanup in case the watcher process is killed before it can clean up.

That way you can have ONE permanent Obsidian vault and still double-click stray `.md` files from anywhere on the system, with the staging area cleaning itself up.

## Files

| File | Role |
|---|---|
| `open_md_to_vault.exe` | The handler. Wrapped from the `.ps1` via `ps2exe`. Silent (no console window, no popups). |
| `open_md_to_vault.ps1` | The human-readable source. Edit this, then re-wrap with `ps2exe` (see below). |

## Setup

1. Pick a path for the `.exe`. The script's hardcoded vault path assumes it'll live somewhere stable — anywhere works as long as it doesn't move.
2. **Register `.md` to open with this exe.** Right-click any `.md` file in File Explorer → **Open with** → **Choose another app** → **More apps** → **Look for another app on this PC** → browse to `open_md_to_vault.exe` → tick **Always use this app to open .md files** → **OK**. Windows writes a properly-hashed `UserChoice` entry for you. Don't try to hand-edit the file-association registry — Windows guards `UserChoice` with a deny ACL.
3. **(Optional) Custom file icon.** The `.exe` registered above gets a new ProgID under `HKCU\Software\Classes\Applications\open_md_to_vault.exe`. Add a `DefaultIcon` value pointing at a multi-resolution `.ico` to override the generic ps2exe icon. Refresh the cache afterwards with `ie4uinit.exe -ClearIconCache` and `ie4uinit.exe -show`.

## Hardcoded paths

The `.ps1` script has several path constants at the top. Edit and re-wrap if your setup differs:

| Constant | Default | Purpose |
|---|---|---|
| `$VaultRoot` | `C:\Users\azt12\OneDrive\Documents\Obsidian Vault` | Your main Obsidian vault. |
| `$VaultName` | `Obsidian Vault` | Vault name as it appears in Obsidian's vault list (used in the `obsidian://` URL). |
| `$VaultTempDir` | `<VaultRoot>\TEMP` | Where out-of-vault files get staged. |
| `$WorkspaceJson` | `<VaultRoot>\.obsidian\workspace.json` | Watched for tab-close detection. |
| `$LogPath` | `C:\Users\azt12\open_md_to_vault.log` | Append-only operational log. |

## How the tab-close detection works

When the script opens a file via `obsidian://`, the tab is recorded in `<vault>\.obsidian\workspace.json` under one of the workspace regions (`main` / `left` / `right`) as a leaf with `state.state.file = "TEMP/<filename>"`.

A `System.IO.FileSystemWatcher` set to wake on writes to `workspace.json` runs an event loop: on each change it re-reads the JSON and walks the leaf tree looking for the relative path. Once the file has been seen open at least once and then disappears from every leaf, the tab is considered closed, and the script deletes the staging copy and exits.

No polling — `WaitForChanged` blocks until an actual write event fires. The 30-second timeout in the loop is just a periodic re-check tick (in case Obsidian wrote workspace.json in a way the watcher missed).

If the script is killed before the watcher fires (force-kill, system reboot, etc.), the `HKCU\…\RunOnce` entry catches the cleanup at the next login.

## Rebuilding the .exe from the .ps1

```powershell
Install-Module ps2exe -Scope CurrentUser
Import-Module ps2exe
Invoke-ps2exe `
    -inputFile  open_md_to_vault.ps1 `
    -outputFile open_md_to_vault.exe `
    -noConsole -noOutput -noError `
    -title 'Open MD to Vault' `
    -company '<your name>' `
    -product 'open_md_to_vault'
```

The `-noConsole` flag suppresses the cmd window, and `-noOutput` / `-noError` prevent any stray `Write-Output` / errors from ps2exe-wrapped scripts being shown as MessageBox popups.

## Why not just register Obsidian.exe directly?

Obsidian's CLI doesn't open arbitrary on-disk paths well — it'll launch into whatever vault was last open (which is sticky across sessions) and ignore the path argument if the file isn't inside that vault. The `obsidian://open` URL scheme is the documented way to tell Obsidian which vault AND which file to open, but Explorer's double-click only passes a file path, not a URL. This `.exe` is the adapter between those two.

## Why not a `.bat`?

Three problems with `.bat` as a Windows file-association target:

1. Windows' `Open With` browser filter sometimes excludes `.bat`, so users can't pick it in the standard dialog.
2. Explorer's `%1` substitution in registered command lines is unreliable for `.bat` targets — observed on Win11 24H2 the batch receives the literal string `%1` instead of the substituted path.
3. A `.bat` flashes a console window before its `>nul` redirects can take effect.

A compiled `.exe` avoids all three.
