#!/usr/bin/env bash
# Download or package one release without executing interpolated Terraform input.
set -euo pipefail

version=${CHART_VERSION:?CHART_VERSION is required}
cache_dir=${CHART_CACHE_DIR:?CHART_CACHE_DIR is required}
if [[ ! "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid chart release tag: $version" >&2
  exit 2
fi

mkdir -p -- "$cache_dir"
work_dir=$(mktemp -d "$cache_dir/.download.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
archive="$work_dir/chart.tgz"
url="https://github.com/opensearch-project/opensearch-migrations/releases/download/$version/migration-assistant-$version.tgz"

# Transport errors and server errors must not silently switch the source.
status=$(curl --silent --show-error --location --connect-timeout 10 --max-time 120 \
  --output "$archive" --write-out '%{http_code}' "$url")
case "$status" in
  200) ;;
  404)
    echo "Release has no packaged chart; packaging the exact source tag."
    git clone --depth 1 --branch "$version" \
      https://github.com/opensearch-project/opensearch-migrations.git "$work_dir/repo"
    mkdir "$work_dir/packages"
    helm package "$work_dir/repo/deployment/k8s/charts/aggregates/migrationAssistantWithArgo" \
      --destination "$work_dir/packages"
    shopt -s nullglob
    packages=("$work_dir/packages/"*.tgz)
    if [[ ${#packages[@]} -ne 1 ]]; then
      echo "Expected exactly one packaged chart, found ${#packages[@]}" >&2
      exit 1
    fi
    mv -- "${packages[0]}" "$archive"
    ;;
  *)
    echo "Chart download failed with HTTP $status" >&2
    exit 1
    ;;
esac

# Reject an HTML/error response or invalid chart before replacing a cached file.
helm show chart "$archive" >/dev/null
mv -- "$archive" "$cache_dir/migration-assistant-$version.tgz"
