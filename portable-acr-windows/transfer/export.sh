#!/usr/bin/env bash
set -Eeuo pipefail

required_variables=(
  ACR_REGISTRY
  ACR_USERNAME
  ACR_PASSWORD
  ARTIFACT_REPOSITORY
  ARTIFACT_TAG
  SOURCE_NAMESPACE
  SOURCE_PVC
  SOURCE_RUNTIME_IMAGE
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Required environment variable ${variable} is missing." >&2
    exit 1
  fi
done

if [[ ! -f /source/data.img ]]; then
  echo "The source PVC does not contain /storage/data.img." >&2
  exit 1
fi

archive=/staging/windows-storage.tar.zst
metadata=/staging/metadata.json

rm -f "${archive}" "${metadata}"

echo "Compressing the golden storage..."
tar \
  --sparse \
  --numeric-owner \
  --one-file-system \
  --directory /source \
  --use-compress-program='zstd -T0 -10' \
  --create \
  --file "${archive}" \
  .

archive_sha256="$(sha256sum "${archive}" | awk '{print $1}')"
archive_bytes="$(stat -c '%s' "${archive}")"
disk_logical_bytes="$(stat -c '%s' /source/data.img)"

jq --null-input \
  --arg formatVersion "1" \
  --arg createdUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sourceNamespace "${SOURCE_NAMESPACE}" \
  --arg sourcePvc "${SOURCE_PVC}" \
  --arg runtimeImage "${SOURCE_RUNTIME_IMAGE}" \
  --arg archiveSha256 "${archive_sha256}" \
  --argjson archiveBytes "${archive_bytes}" \
  --argjson diskLogicalBytes "${disk_logical_bytes}" \
  '{
    formatVersion: $formatVersion,
    createdUtc: $createdUtc,
    sourceNamespace: $sourceNamespace,
    sourcePvc: $sourcePvc,
    runtimeImage: $runtimeImage,
    archiveSha256: $archiveSha256,
    archiveBytes: $archiveBytes,
    diskLogicalBytes: $diskLogicalBytes
  }' > "${metadata}"

printf '%s' "${ACR_PASSWORD}" |
  oras login "${ACR_REGISTRY}" \
    --username "${ACR_USERNAME}" \
    --password-stdin

trap 'oras logout "${ACR_REGISTRY}" >/dev/null 2>&1 || true' EXIT

artifact="${ACR_REGISTRY}/${ARTIFACT_REPOSITORY}:${ARTIFACT_TAG}"
echo "Pushing ${artifact}..."
(
  cd /staging
  oras push "${artifact}" \
    --artifact-type application/vnd.aks-windows.golden-disk.v1 \
    "windows-storage.tar.zst:application/vnd.aks-windows.golden-disk.layer.v1.tar+zstd" \
    "metadata.json:application/vnd.aks-windows.golden-disk.metadata.v1+json"
)

echo "Golden disk artifact uploaded successfully."
cat "${metadata}"
