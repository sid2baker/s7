#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SNAP7_COMMIT="a1845454f5f16f3b127b987807f1cbc59205db70"
readonly SNAP7_URL="https://github.com/valiot/snap7.git"
readonly WORK_DIR="$(mktemp -d)"
readonly SERVER_BIN="${WORK_DIR}/snap7-server"
readonly SERVER_LOG="${WORK_DIR}/snap7-server.log"
readonly PORT="${S7_TEST_PORT:-11102}"

if [[ -n "${S7_SNAP7_SOURCE:-}" ]]; then
  SNAP7_SOURCE="${S7_SNAP7_SOURCE}"
elif [[ -d "${ROOT}/resources/reference-implementations/snap7/src/core" ]]; then
  SNAP7_SOURCE="${ROOT}/resources/reference-implementations/snap7"
else
  SNAP7_SOURCE="${WORK_DIR}/snap7"
  git clone --quiet --filter=blob:none --no-checkout "${SNAP7_URL}" "${SNAP7_SOURCE}"
  git -C "${SNAP7_SOURCE}" sparse-checkout init --cone
  git -C "${SNAP7_SOURCE}" sparse-checkout set src/core src/sys
  git -C "${SNAP7_SOURCE}" checkout --quiet "${SNAP7_COMMIT}"
fi

if [[ -d "${SNAP7_SOURCE}/.git" ]]; then
  ACTUAL_SNAP7_COMMIT="$(git -C "${SNAP7_SOURCE}" rev-parse HEAD)"

  if [[ "${ACTUAL_SNAP7_COMMIT}" != "${SNAP7_COMMIT}" ]]; then
    echo "Snap7 source is at ${ACTUAL_SNAP7_COMMIT}, expected ${SNAP7_COMMIT}" >&2
    exit 1
  fi
fi

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}"
    wait "${SERVER_PID}" || true
  fi

  rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

g++ -std=c++17 -O2 -pthread -Wno-stringop-overread \
  -I"${SNAP7_SOURCE}/src/core" \
  -I"${SNAP7_SOURCE}/src/sys" \
  "${ROOT}/test/interop/snap7_server.cpp" \
  "${SNAP7_SOURCE}/src/sys/snap_threads.cpp" \
  "${SNAP7_SOURCE}/src/sys/snap_sysutils.cpp" \
  "${SNAP7_SOURCE}/src/sys/snap_msgsock.cpp" \
  "${SNAP7_SOURCE}/src/sys/snap_tcpsrvr.cpp" \
  "${SNAP7_SOURCE}/src/core/s7_isotcp.cpp" \
  "${SNAP7_SOURCE}/src/core/s7_peer.cpp" \
  "${SNAP7_SOURCE}/src/core/s7_server.cpp" \
  "${SNAP7_SOURCE}/src/core/s7_text.cpp" \
  -o "${SERVER_BIN}"

"${SERVER_BIN}" "${PORT}" >"${SERVER_LOG}" 2>&1 &
SERVER_PID=$!

for _attempt in $(seq 1 50); do
  if grep -q "^READY ${PORT}$" "${SERVER_LOG}"; then
    break
  fi

  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    cat "${SERVER_LOG}"
    exit 1
  fi

  sleep 0.1
done

grep -q "^READY ${PORT}$" "${SERVER_LOG}"

S7_TEST_HOST="127.0.0.1" S7_TEST_PORT="${PORT}" \
  mix test --include external test/interop/snap7_client_test.exs
