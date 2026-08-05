#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

requested_output="$1"
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
