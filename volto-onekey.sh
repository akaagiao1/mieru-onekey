#!/usr/bin/env bash
set -euo pipefail

# Volto v1.8.2 bootstrap. The upstream script verifies the release signature
# and archive checksum before installing the requested or latest release.
upstream_commit=e8dabe342be16d3071b43d0c8ba0477a226ace88
upstream_sha256=b53abf79770c394022d608394d31b1f38c0800d15b7036e8d248cdaf17c2ea5a
upstream_url="https://raw.githubusercontent.com/vcarus/volto/$upstream_commit/script/deploy.sh"

installer=$(mktemp)
trap 'rm -f -- "$installer"' EXIT

curl --proto '=https' --fail --silent --show-error --location \
  --output "$installer" "$upstream_url"

download_sha256=$(sha256sum < "$installer")
if [[ "${download_sha256%% *}" != "$upstream_sha256" ]]; then
  printf '%s\n' 'Volto installer download failed SHA-256 verification.' >&2
  exit 1
fi

# Match the upstream bootstrap's stdin invocation and keep stdout attached
# to the terminal so the upstream installer can display the Surge password.
bash -s -- "$@" < "$installer"
