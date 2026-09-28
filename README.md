# ADB Lease Guard

One Android device, one announced operator. ADB Lease Guard places a small,
open-source launcher in the normal `adb` path. Before forwarding a command to
the original Android platform-tools binary, it checks a lease ID with your
existing lease command over SSH. The launcher is the whole project: it does
not ship a lease server, phone scripts, or a copy of Android's ADB binary.

The guard is useful when several agents or hosts share a test phone and an
accidental `adb shell`, `install`, or `connect` can interrupt someone else's
work. It was exercised on Linux and Windows with a physical phone and an
unrelated emulator.

## Install from one link

Have ADB installed and an SSH alias for a lease server first. That server must
provide a command with `check LEASE_ID` as described below. Replace the
example host, serial, and model with your own values.

**Linux or macOS** (prompts for the lease server, its command, and the device;
installs ahead of the existing `adb` in `/usr/local/bin`):

```sh
curl -fsSL https://github.com/megamen32/adb-lease-guard/releases/latest/download/install.sh | sudo bash
```

For a noninteractive installation, pass the values explicitly:

```sh
curl -fsSL https://github.com/megamen32/adb-lease-guard/releases/latest/download/install.sh |
  sudo bash -s -- --lease-host lease-host --lease-bin device-lease \
  --serials USB_SERIAL --models DEVICE_MODEL --adb /path/to/existing/adb
```

**Windows PowerShell** (installs at the first `adb.exe` found on `PATH` and
prompts for the lease host, its command, and the device):

```powershell
irm https://github.com/megamen32/adb-lease-guard/releases/latest/download/install.ps1 | iex
```

To choose a specific Windows ADB copy, download the same script and run it with
`-AdbPath`, `-LeaseHost`, `-LeaseBin`, `-Serials`, and `-Models`. Run it once for
each ADB executable used by your tools. Both installers verify the downloaded
binary against the release's `SHA256SUMS` before changing ADB. They preserve
the original executable or symlink for rollback. Go is not needed to install.

On Linux and macOS, pass `--prefix "$HOME/.local"` for a user installation,
then put `$HOME/.local/bin` before other ADB directories on `PATH`. The system
installation above needs write access to `/usr/local`. Use a pinned tag instead
of `latest` when repeatable installation matters: set
`ADB_LEASE_GUARD_VERSION=v0.1.2` before running `install.sh`, or pass
`-Version v0.1.2` to `install.ps1`.

## Use

Claim the shared device before interacting with it. Put the returned
`lease_id` in `ADB_LEASE_ID` (or the name chosen with `--id-env` / `-IdEnv`):

```sh
ssh lease-host device-lease acquire --owner my-task --purpose debug --minutes 45
export ADB_LEASE_ID=THE_RETURNED_LEASE_ID
adb -s USB_SERIAL shell getprop ro.product.model
ssh lease-host device-lease release "$ADB_LEASE_ID"
```

PowerShell uses `$env:ADB_LEASE_ID = 'THE_RETURNED_LEASE_ID'`. A selected device
command without a valid ID exits **75**. ADB `version`, `devices`, and
`start-server` remain available for discovery. Explicit emulator targets are
left alone. The launcher identifies a selected physical device by configured
serial or by the `model:` field in `adb devices -l`.

The lease server is external to this repository. Its `check ID` action must
print one JSON line containing `{"status":"valid"}` for the current ID. Any
other status, missing response, SSH failure, or timeout denies the ADB command.
Use short leases, renew while working, and release when done. The installer
writes `adb-lease.json` beside the guard; its `lease_command` array can be
edited for a local command or a different SSH route.

```json
{
  "real_adb": "/path/to/original/adb",
  "lease_command": ["ssh", "-n", "-T", "lease-host", "device-lease"],
  "device_serials": ["USB_SERIAL"],
  "device_models": ["DEVICE_MODEL"],
  "id_env": "ADB_LEASE_ID"
}
```

## What the guard can and cannot enforce

This is an operator coordination tool. It guards calls made through the
installed `adb` entrypoint. Another ADB copy, the preserved original binary,
direct USB access, and tools that bypass the command can still reach the
device. A newly unknown `adb connect` target cannot be recognized before it
appears in `adb devices -l`; subsequent device commands are checked. Anyone
who can edit the local config or obtain a current lease ID can use it. Apply
normal OS permissions to the config, SSH account, and original ADB path.

The project does not store lease IDs. The launcher reads the ID from its
configured environment variable, asks the server once per selected ADB
invocation, and forwards arguments and exit status to the original ADB.

## Roll back

On Linux/macOS, `adb-lease.json` records the absolute original ADB path. Point
`/usr/local/bin/adb` back to that path (or restore the saved
`adb-before-lease` symlink/file) and remove the guard when no client is running.
On Windows, close ADB clients using that path, remove the guarded `adb.exe`,
rename the sibling `adb-real.exe` to `adb.exe`, and remove `adb-lease.json`.

## Develop

```sh
go test ./...
bash scripts/build-release.sh
```

`scripts/build-release.sh` writes binaries, installers, and checksums under
ignored `.tmp/dist/`. GitHub Actions runs tests on Linux and Windows and
publishes those assets for version tags. See [LICENSE](LICENSE).
