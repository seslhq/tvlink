#!/bin/bash
# Install or update tvlink from GitHub in one line: main, or a commit, branch or tag of the repo.
#   curl -fsSL https://raw.githubusercontent.com/seslhq/tvlink/main/get.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/seslhq/tvlink/main/get.sh | sudo bash -s -- [--force] [COMMIT]
# Downloads the archive over https into a root-only temp dir, unpacks it whole, then runs its install.sh; the temp
# dir goes after. --force: run on something other than Raspberry Pi OS or Debian trixie arm64.
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 cpwillis (https://github.com/seslhq/tvlink)
# All in main, run on the last line: a download cut short runs nothing.
main() {
  set -euo pipefail
  local force=0 ref=main archive=${TVLINK_ARCHIVE:-https://github.com/seslhq/tvlink/archive} dir id='' code='' arch
  die() { echo "$*" >&2; exit 1; }
  for a in "$@"; do
    case $a in
      --force) force=1 ;;
      -*) die "Usage: get.sh [--force] [COMMIT]" ;;
      *) ref=$a ;;
    esac
  done
  [ "$(id -u)" = 0 ] || die "Run as root: curl -fsSL .../get.sh | sudo bash"
  [[ $ref =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Not a commit, branch or tag: $ref"
  [[ $archive =~ ^https:// ]] || die "TVLINK_ARCHIVE must be an https link" # the test's stand-in, https too
  # shellcheck disable=SC1091
  [ ! -r /etc/os-release ] || { . /etc/os-release; id=${ID:-} code=${VERSION_CODENAME:-}; }
  arch=$(dpkg --print-architecture 2>/dev/null) || arch=$(uname -m)
  [[ $force = 1 || ($id =~ ^(debian|raspbian)$ && $code = trixie && $arch = arm64) ]] ||
    die "tvlink runs on Raspberry Pi OS Lite or Debian trixie arm64, not ${id:-unknown} ${code:-?} $arch." \
      "To try anyway: curl -fsSL .../get.sh | sudo bash -s -- --force"

  dir=$(mktemp -d /var/tmp/tvlink-get.XXXXXX) # root's, mode 700
  # shellcheck disable=SC2064 # expand now: dir is local
  trap "rm -rf '$dir'" EXIT
  echo "Downloading tvlink $ref"
  curl -fsSL --proto =https --proto-redir =https -m 300 -o "$dir/tvlink.tar.gz" "$archive/$ref.tar.gz" ||
    die "Download failed: $archive/$ref.tar.gz"
  mkdir "$dir/src"
  tar -xzf "$dir/tvlink.tar.gz" -C "$dir/src" --strip-components=1 --no-same-owner || die "Can't unpack the archive"
  [ -x "$dir/src/install.sh" ] || die "No install.sh in the archive"
  # Unpacked whole: now install. stdin is this script's pipe, so nothing below may read it.
  DEBIAN_FRONTEND=noninteractive "$dir/src/install.sh" </dev/null
}
main "$@"
