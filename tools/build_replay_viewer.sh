#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

requested_output="$1"

# A Windows caller hands us its native path (C:\... or C:/...), which every
# check below would reject as non-absolute. Normalize to POSIX first so the
# same validation applies. Under WSL or a real Unix the paths already start
# with / and this is a no-op.
if [[ "${requested_output}" =~ ^[A-Za-z]:[\\/] ]]; then
  if command -v cygpath >/dev/null 2>&1; then
    requested_output="$(cygpath -u "${requested_output}")"
  else
    drive="$(printf '%s' "${requested_output:0:1}" | tr '[:upper:]' '[:lower:]')"
    requested_output="/${drive}$(printf '%s' "${requested_output:2}" | tr '\\' '/')"
  fi
fi

if [[ "${requested_output}" != /* || "$(basename "${requested_output}")" != "static-replay-viewer" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

if [[ "${requested_output}" != "${repo_dir}"/* ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

# Reject traversal before creating anything: the resolved-path checks below
# only run after mkdir, so without this a path like <repo>/../../tmp/... would
# create directories outside the repo and only then be refused.
if [[ "${requested_output}" == *"/../"* || "${requested_output}" == *"/.." ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

mkdir -p "$(dirname "${requested_output}")"
output_parent="$(cd "$(dirname "${requested_output}")" && pwd -P)"
output_dir="${output_parent}/static-replay-viewer"
if [[ "${output_dir}" != "${repo_dir}"/* || -L "${output_dir}" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"
cp "${repo_dir}/game/client/global_client.html" "${output_dir}/index.html"
cp "${repo_dir}/game/client/snappyjs.min.js" "${output_dir}/snappyjs.min.js"
cp "${repo_dir}/game/client/replay_viewer.js" "${output_dir}/replay_viewer.js"

test -f "${output_dir}/index.html"
