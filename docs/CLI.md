# switchmtp-batch-cli

> **Two command-line tools exist.** This document describes `switchmtp-batch-cli`, the Swift one
> bundled in the macOS app. There is also **`switchmtp-batch`**, a separate Go tool that links the
> backend directly and runs on **Linux as well as macOS** — see
> [Command line](../README.md#command-line). They overlap but are not interchangeable:
> this one goes through the FFI and needs the app bundle; the Go one is a single static
> binary and is the only option on Linux.

`switchmtp-batch-cli` is the command-line interface for SwitchMTP Batch's Go MTP backend. It targets
a Nintendo Switch running DBI's MTP responder.

The CLI ships inside the app bundle:

```sh
"/Applications/SwitchMTP Batch.app/Contents/Resources/bin/switchmtp-batch-cli" doctor
```

For a source build, the same bundled path is under the build product (from the repository
root):

```sh
build/products/SwitchMTP\ Batch.app/Contents/Resources/bin/switchmtp-batch-cli doctor
```

Optional convenience symlink:

```sh
mkdir -p /usr/local/bin
ln -sf "/Applications/SwitchMTP Batch.app/Contents/Resources/bin/switchmtp-batch-cli" /usr/local/bin/switchmtp-batch-cli
```

If something is wrong, run this first:

```sh
switchmtp-batch-cli doctor
```

## Global flags

```sh
switchmtp-batch-cli [--verbose] [--json] [--quiet] [--yes] [--device <id>] <command> [arguments]
```

- `--device <id>` selects a device when more than one usable MTP device is connected.
  Device IDs look like `1406|8221|SERIAL` and use decimal vendor/product IDs.
- `--json` prints the raw backend JSON envelope for the main operation.
- `--quiet` (`-q`) suppresses progress bars and confirmation messages; list output is
  still printed.
- `--yes` (`-y`) skips confirmation prompts (accepted for scripting parity; this CLI
  runs headless and does not prompt otherwise).
- `--verbose` enables backend protocol logging on stderr.

Device paths use `<storage>:<path>`. The `<storage>` part accepts, in order: a numeric
storage id (`65537`), a kind alias (`sdcard`, `nand`, `saves`, `album`, `gamecard`, …),
an exact display name, or a unique prefix of the display name. An ambiguous or unknown
selector is an error — the CLI never guesses a storage.

```sh
switchmtp-batch-cli ls 65537:/switch/
switchmtp-batch-cli ls sdcard:/switch/
switchmtp-batch-cli ls saves:/
```

## Commands

### `devices`

Lists connected MTP devices.

```sh
switchmtp-batch-cli devices
```

With no devices attached, plain text prints a hint to run `doctor`; `--json` emits an
empty array `[]`.

### `info`

Shows the selected device profile, identity, advice, and negotiated MTP capabilities.

```sh
switchmtp-batch-cli --device "1406|8221|XAW10000000000" info
```

### `storages`

Lists storage IDs, Switch/DBI storage kind, capability flags, free/total space, and
notes. DBI install storages are shown as write-only install triggers and not browsable;
virtual storages such as Installed Games/Game Card are marked as virtual/generated. Space
is shown as `—` when the storage does not report reliable capacity.

```sh
switchmtp-batch-cli storages
```

### `ls [-a] [-R] <storage>:<path>`

Lists a directory. Folders come first, then case-insensitive name order; a footer line
summarises file/directory counts and total size. Unknown virtual file sizes are shown as
`?`, never as a fake 4 GiB value.

- `-a`, `--all` includes hidden files and filesystem artefacts.
- `-R`, `--recursive` walks subdirectories and prints full paths.

```sh
switchmtp-batch-cli ls 65537:/
switchmtp-batch-cli ls -a sdcard:/switch/
switchmtp-batch-cli ls -R saves:/
```

### `cp <src>... <dst>` / `get` / `put`

Copies in either direction. Exactly one side must be device paths; one or more sources
are accepted, and every source must be on the same storage.

- `get` / `download` pins the direction device → Mac; the last argument is a local folder.
- `put` / `upload` pins the direction Mac → device; the last argument is a device path.

```sh
# Device to Mac
switchmtp-batch-cli cp 65537:/switch/app.nro ~/Downloads/
switchmtp-batch-cli get sdcard:/switch/a.nro sdcard:/switch/b.nro ~/Downloads/

# Mac to device directory
switchmtp-batch-cli cp ~/Downloads/app.nro 65537:/switch/
switchmtp-batch-cli put ~/Downloads/a.nsp ~/Downloads/b.nsp sdcard:/games/
```

Read-only install storages cannot be downloaded from; the CLI rejects the operation
instead of issuing a failing transfer.

### `rm <storage>:<path>...`

Deletes one or more files or folders from the device. All paths must be on the same
storage; the storage root cannot be deleted, and storages without a delete capability are
rejected.

```sh
switchmtp-batch-cli rm 65537:/switch/old-app.nro
switchmtp-batch-cli rm sdcard:/switch/a.nro sdcard:/switch/b.nro
```

### `mv <storage>:<path> <new-name>`

Renames an item within the same device directory. Moving between directories or storages
is refused; use `get` then `put` for that. The new name must be a bare file/folder name
(it cannot contain `/` or `\`).

```sh
switchmtp-batch-cli mv 65537:/switch/old.nro new.nro
```

### `mkdir <storage>:<path>`

Creates a device directory. The storage root cannot be created as a target.

```sh
switchmtp-batch-cli mkdir 65537:/switch/new-folder
```

### `install <file...> [--sd|--nand]`

Uploads one or more `.nsp`, `.nsz`, `.xci`, or `.xcz` files to DBI's install storage. SD
install is the default; pass `--nand` (or `-nand`) for internal storage. `--sd`/`-sd` is
accepted for explicitness. Files are checked locally — existence and extension — before
the device is opened.

```sh
switchmtp-batch-cli install ~/Downloads/game.nsp
switchmtp-batch-cli install ~/Downloads/game.nsz --nand
```

After the upload completes, installation continues on the Switch. DBI does not send a
final installation completion event over MTP, so the CLI can only report that the file
was uploaded. Watch the Switch screen for install progress and errors.

### `backup-saves <dir>`

Downloads the DBI Saves storage recursively into a dated `switch-saves-...` folder under
`<dir>`.

```sh
switchmtp-batch-cli backup-saves ~/Backups/Switch
```

Example destination:

```text
~/Backups/Switch/switch-saves-2026-08-06_185502
```

### `doctor`

Prints a human-readable diagnostic report: verdict, visible Nintendo/MTP devices, USB
client blockers, and ordered remediation steps.

```sh
switchmtp-batch-cli doctor
```

Use `--json` to capture the raw diagnostics envelope for scripts or bug reports:

```sh
switchmtp-batch-cli --json doctor > diagnostics.json
```
