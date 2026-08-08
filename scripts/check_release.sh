#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WORK_DIR="$(mktemp -d)"
readonly PACKAGE_DIR="${WORK_DIR}/package"

cleanup() {
  rm -rf "${WORK_DIR}"
}

trap cleanup EXIT
cd "${ROOT}"

VERSION="$(MIX_ENV=dev mix run --no-start --no-compile -e 'IO.write(Mix.Project.config()[:version])')"

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]] && [[ "${GITHUB_REF_NAME}" != "v${VERSION}" ]]; then
  echo "Tag ${GITHUB_REF_NAME} does not match package version v${VERSION}" >&2
  exit 1
fi

MIX_ENV=dev mix hex.build --unpack --output "${PACKAGE_DIR}"

for path in lib docs .formatter.exs CHANGELOG.md LICENSE mix.exs README.md SECURITY.md; do
  test -e "${PACKAGE_DIR}/${path}"
done

for excluded in resources test scripts .github; do
  test ! -e "${PACKAGE_DIR}/${excluded}"
done

MIX_ENV=dev mix docs --warnings-as-errors
MIX_ENV=test mix ci

printf 'Release candidate %s passed documentation, package, and quality gates\n' "${VERSION}"
