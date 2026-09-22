#!/usr/bin/env bash
set -Eeuo pipefail

required_variables=(
  ACR_REGISTRY
  ACR_USERNAME
  ACR_PASSWORD
  ARTIFACT_REPOSITORY
  ARTIFACT_TAG
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Required environment variable ${variable} is missing." >&2
    exit 1
  fi
done

unexpected_entry="$(
  find /target -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit
)"
if [[ -n "${unexpected_entry}" ]]; then
  echo "The destination PVC is not empty: ${unexpected_entry}" >&2
  exit 1
fi

rm -rf /staging/*

printf '%s' "${ACR_PASSWORD}" |
  oras login "${ACR_REGISTRY}" \
    --username "${ACR_USERNAME}" \
    --password-stdin

trap 'oras logout "${ACR_REGISTRY}" >/dev/null 2>&1 || true' EXIT

artifact="${ACR_REGISTRY}/${ARTIFACT_REPOSITORY}:${ARTIFACT_TAG}"
echo "Pulling ${artifact}..."
oras pull "${artifact}" --output /staging

archive=/staging/windows-storage.tar.zst
metadata=/staging/metadata.json

if [[ ! -f "${archive}" || ! -f "${metadata}" ]]; then
  echo "The artifact is missing windows-storage.tar.zst or metadata.json." >&2
  exit 1
fi

expected_sha256="$(jq --raw-output '.archiveSha256' "${metadata}")"
actual_sha256="$(sha256sum "${archive}" | awk '{print $1}')"
if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
  echo "Archive checksum mismatch." >&2
  echo "Expected: ${expected_sha256}" >&2
  echo "Actual:   ${actual_sha256}" >&2
  exit 1
fi

echo "Extracting the golden storage..."
tar \
  --sparse \
  --numeric-owner \
  --directory /target \
  --use-compress-program=zstd \
  --extract \
  --file "${archive}"

if [[ ! -f /target/data.img ]]; then
  echo "The restored PVC does not contain data.img." >&2
  exit 1
fi

cp "${metadata}" /target/.portable-golden-metadata.json
sync

echo "Golden storage imported successfully."
du -sh /target
cat /target/.portable-golden-metadata.json
