#!/usr/bin/env bash
set -euo pipefail

REPO=megamen32/adb-lease-guard
VERSION=${ADB_LEASE_GUARD_VERSION:-latest}
PREFIX=/usr/local
LEASE_HOST=
LEASE_BIN=
SERIALS=
MODELS=
ADB_PATH=
ID_ENV=ADB_LEASE_ID

usage() {
  cat <<'EOF'
Install the ADB lease guard in front of an existing adb binary.

Usage: install.sh [--prefix DIR] [--lease-host SSH_HOST]
                  [--lease-bin REMOTE_COMMAND] [--serials CSV]
                  [--models CSV] [--adb ABSOLUTE_PATH]
                  [--id-env ENV_NAME]

The SSH host must already run REMOTE_COMMAND with a `check LEASE_ID` action
that prints one JSON line with {"status":"valid"} for the current lease.
The original adb remains available at the path recorded in adb-lease.json.
EOF
}

while (($#)); do
  case "$1" in
    --prefix|--lease-host|--lease-bin|--serials|--models|--adb|--id-env)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 64; }
      case "$1" in
        --prefix) PREFIX=$2 ;;
        --lease-host) LEASE_HOST=$2 ;;
        --lease-bin) LEASE_BIN=$2 ;;
        --serials) SERIALS=$2 ;;
        --models) MODELS=$2 ;;
        --adb) ADB_PATH=$2 ;;
        --id-env) ID_ENV=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

for command in curl python3; do
  command -v "$command" >/dev/null || { echo "Required command missing: $command" >&2; exit 69; }
done
if [[ -z "$LEASE_HOST" && -r /dev/tty ]]; then
  read -r -p 'SSH alias for the existing lease server: ' LEASE_HOST </dev/tty
fi
if [[ -z "$LEASE_BIN" && -r /dev/tty ]]; then
  read -r -p 'Lease command on that server [device-lease]: ' LEASE_BIN </dev/tty
fi
LEASE_BIN=${LEASE_BIN:-device-lease}
if [[ -z "$SERIALS" && -z "$MODELS" && -r /dev/tty ]]; then
  read -r -p 'Device serial(s), comma separated: ' SERIALS </dev/tty
  read -r -p 'Device model(s), comma separated (optional): ' MODELS </dev/tty
fi
[[ -n "$LEASE_HOST" && ( -n "$SERIALS" || -n "$MODELS" ) ]] || {
  echo 'Pass --lease-host and --serials or --models.' >&2; exit 64;
}
[[ "$ID_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo 'Invalid --id-env' >&2; exit 64; }
[[ "$LEASE_HOST" != -* && "$LEASE_BIN" != -* ]] || { echo 'Invalid SSH host or lease command' >&2; exit 64; }

if [[ -z "$ADB_PATH" ]]; then
  ADB_PATH=$(command -v adb || true)
fi
[[ -n "$ADB_PATH" && -e "$ADB_PATH" ]] || { echo 'Existing adb not found; pass --adb PATH.' >&2; exit 69; }
REAL_ADB=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ADB_PATH")
[[ "$REAL_ADB" = /* ]] || { echo 'Original adb path must be absolute.' >&2; exit 64; }
[[ "$PREFIX" = /* ]] || { echo '--prefix must be absolute.' >&2; exit 64; }

case "$(uname -s)" in Linux) platform=linux ;; Darwin) platform=darwin ;; *) echo 'Unsupported OS' >&2; exit 69 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo 'Unsupported CPU' >&2; exit 69 ;; esac
asset="adb-lease-guard-${platform}-${arch}"
if [[ -n "${ADB_LEASE_GUARD_BASE_URL:-}" ]]; then
  base=${ADB_LEASE_GUARD_BASE_URL%/}
elif [[ "$VERSION" = latest ]]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

stage="$PREFIX/share/adb-lease-guard/.tmp/install-$$"
mkdir -p "$stage" "$PREFIX/bin"
entry=
backup=
committed=0
cleanup() {
  status=$?
  if ((status != 0 && committed == 0)) && [[ -n "$backup" ]]; then
    [[ -z "$entry" ]] || rm -f "$entry"
    mv "$backup" "$entry" || true
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
curl -fsSL --retry 3 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
curl -fsSL --retry 3 "$base/$asset" -o "$stage/$asset"
expected=$(awk -v name="$asset" '$2 == name {print $1}' "$stage/SHA256SUMS")
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { echo 'Release checksum is missing.' >&2; exit 65; }
actual=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$stage/$asset")
expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
[[ "$actual" = "$expected" ]] || { echo 'Release checksum mismatch.' >&2; exit 65; }

guard="$PREFIX/bin/adb-lease-guard"
entry="$PREFIX/bin/adb"
config="$PREFIX/bin/adb-lease.json"
if [[ "$REAL_ADB" = "$guard" ]]; then
  echo 'adb already points to this guard; pass --adb PATH to the preserved original.' >&2; exit 65
fi
if [[ -e "$entry" || -L "$entry" ]]; then
  if [[ -L "$entry" && "$(readlink "$entry")" = "$guard" ]]; then
    : # Updating an existing installation.
  elif [[ "$entry" = "$REAL_ADB" ]]; then
    [[ ! -e "$PREFIX/bin/adb-real" ]] || { echo 'adb-real already exists; refusing to overwrite it.' >&2; exit 65; }
    mv "$entry" "$PREFIX/bin/adb-real"
    backup="$PREFIX/bin/adb-real"
    REAL_ADB="$PREFIX/bin/adb-real"
  else
    [[ ! -e "$PREFIX/bin/adb-before-lease" && ! -L "$PREFIX/bin/adb-before-lease" ]] || {
      echo 'adb-before-lease already exists; refusing to overwrite it.' >&2; exit 65;
    }
    mv "$entry" "$PREFIX/bin/adb-before-lease"
    backup="$PREFIX/bin/adb-before-lease"
  fi
fi

ADB_LEASE_REAL_ADB="$REAL_ADB" ADB_LEASE_HOST="$LEASE_HOST" \
ADB_LEASE_BIN="$LEASE_BIN" ADB_LEASE_SERIALS="$SERIALS" \
ADB_LEASE_MODELS="$MODELS" ADB_LEASE_ID_ENV="$ID_ENV" \
python3 - "$stage/adb-lease.json" <<'PY'
import json, os, sys
split = lambda value: [part.strip() for part in value.split(',') if part.strip()]
data = {
    'real_adb': os.environ['ADB_LEASE_REAL_ADB'],
    'lease_command': ['ssh', '-n', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                      os.environ['ADB_LEASE_HOST'], os.environ['ADB_LEASE_BIN']],
    'device_serials': split(os.environ['ADB_LEASE_SERIALS']),
    'device_models': split(os.environ['ADB_LEASE_MODELS']),
    'id_env': os.environ['ADB_LEASE_ID_ENV'],
}
with open(sys.argv[1], 'w', encoding='utf-8') as stream:
    json.dump(data, stream, indent=2)
    stream.write('\n')
PY
install -m 0755 "$stage/$asset" "$guard.new"
mv -f "$guard.new" "$guard"
install -m 0644 "$stage/adb-lease.json" "$config"
ln -sfn "$guard" "$entry"
"$entry" version >/dev/null
committed=1
printf 'Installed: %s\nOriginal adb: %s\nConfig: %s\n' "$entry" "$REAL_ADB" "$config"
printf 'Set %s to a valid lease ID before ADB commands to the selected device.\n' "$ID_ENV"
