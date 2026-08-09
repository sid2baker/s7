#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly NETSHOOT_IMAGE="nicolaka/netshoot@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70"
readonly WORK_DIR="$(mktemp -d)"
readonly PCAP="${WORK_DIR}/s7-snap7.pcap"
readonly CAPTURE_CONTAINER="s7-snap7-capture-$$"
readonly PORT="${S7_TEST_PORT:-11102}"

cleanup() {
  if docker inspect "${CAPTURE_CONTAINER}" >/dev/null 2>&1; then
    docker stop --timeout 10 "${CAPTURE_CONTAINER}" >/dev/null 2>&1 || true
    docker rm --force "${CAPTURE_CONTAINER}" >/dev/null 2>&1 || true
  fi

  rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

docker run --detach \
  --name "${CAPTURE_CONTAINER}" \
  --network host \
  --cap-add NET_RAW \
  --cap-add NET_ADMIN \
  --volume "${WORK_DIR}:/captures" \
  "${NETSHOOT_IMAGE}" \
  tcpdump -i lo -U -s 0 -w /captures/s7-snap7.pcap "tcp port ${PORT}" >/dev/null

sleep 1
S7_TEST_PORT="${PORT}" bash "${ROOT}/scripts/run_snap7_integration.sh"

sleep 1
docker stop --timeout 10 "${CAPTURE_CONTAINER}" >/dev/null
docker wait "${CAPTURE_CONTAINER}" >/dev/null
docker rm "${CAPTURE_CONTAINER}" >/dev/null

DECODED="$({
  docker run --rm \
    --volume "${WORK_DIR}:/captures" \
    "${NETSHOOT_IMAGE}" \
    tshark -r /captures/s7-snap7.pcap -d "tcp.port==${PORT},tpkt" -Y s7comm
} 2>/dev/null)"

MALFORMED="$({
  docker run --rm \
    --volume "${WORK_DIR}:/captures" \
    "${NETSHOOT_IMAGE}" \
    tshark -r /captures/s7-snap7.pcap -d "tcp.port==${PORT},tpkt" \
      -Y _ws.malformed -T fields -e frame.number
} 2>/dev/null)"

grep -q "Setup communication" <<<"${DECODED}"
grep -q "Function:\[Read Var\]" <<<"${DECODED}"
grep -q "Function:\[Write Var\]" <<<"${DECODED}"
grep -q "Read SZL" <<<"${DECODED}"
grep -Fq "[Block functions] -> [List blocks]" <<<"${DECODED}"
grep -Fq "[Block functions] -> [List blocks of type]" <<<"${DECODED}"
grep -Fq "[Block functions] -> [Get block info]" <<<"${DECODED}"
grep -Fq "[Time functions] -> [Set clock]" <<<"${DECODED}"
grep -Fq "[Security] -> [PLC password]" <<<"${DECODED}"
test -z "${MALFORMED}"

if [[ -n "${S7_CAPTURE_FILE:-}" ]]; then
  install -m 0644 "${PCAP}" "${S7_CAPTURE_FILE}"
fi

printf 'tshark decoded %s S7comm frames with no malformed packets\n' \
  "$(grep -c S7COMM <<<"${DECODED}")"
