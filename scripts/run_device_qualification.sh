#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly NETSHOOT_IMAGE="nicolaka/netshoot@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70"
readonly HOST="${S7_QUAL_HOST:-}"
readonly PORT="${S7_QUAL_PORT:-102}"
readonly INTERFACE="${S7_QUAL_INTERFACE:-any}"
readonly FAMILY="${S7_QUAL_FAMILY:-unknown}"
readonly TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly CAPTURE_CONTAINER="s7-device-qualification-$$"

required_environment=(
  S7_QUAL_HOST
  S7_QUAL_FAMILY
  S7_QUAL_ORDER_NUMBER
  S7_QUAL_FIRMWARE
  S7_QUAL_ACCESS
  S7_QUAL_DB
  S7_QUAL_DB_OFFSET
)

for variable in "${required_environment[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "${variable} is required" >&2
    exit 2
  fi
done

case "${FAMILY}" in
plcsim_advanced | s7_300 | s7_400 | s7_1200 | s7_1500) ;;
*)
  echo "S7_QUAL_FAMILY must be plcsim_advanced, s7_300, s7_400, s7_1200, or s7_1500" >&2
  exit 2
  ;;
esac

if [[ "${S7_QUAL_CONFIRM_WRITES:-}" != "qualified_scratch_db" ]]; then
  echo "Set S7_QUAL_CONFIRM_WRITES=qualified_scratch_db after reserving and backing up the scratch DB range" >&2
  exit 2
fi

required_commands=(docker git mix realpath sha256sum tee)

for command in "${required_commands[@]}"; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "${command} is required for device qualification" >&2
    exit 2
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "A running Docker daemon is required for the pinned tcpdump/tshark image" >&2
  exit 2
fi

OUTPUT_DIR="${S7_QUAL_OUTPUT_DIR:-${ROOT}/tmp/qualification-${FAMILY}-${TIMESTAMP}}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"
readonly OUTPUT_DIR
readonly PCAP="${OUTPUT_DIR}/s7-qualification.pcap"
readonly REPORT="${OUTPUT_DIR}/qualification-report.md"
readonly DECODED="${OUTPUT_DIR}/tshark-s7comm.txt"
readonly TEST_LOG="${OUTPUT_DIR}/exunit.log"

cleanup() {
  if docker inspect "${CAPTURE_CONTAINER}" >/dev/null 2>&1; then
    docker stop --timeout 10 "${CAPTURE_CONTAINER}" >/dev/null 2>&1 || true
    docker rm --force "${CAPTURE_CONTAINER}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

capture_filter="${S7_QUAL_CAPTURE_FILTER:-host ${HOST} and tcp port ${PORT}}"

docker run --detach \
  --name "${CAPTURE_CONTAINER}" \
  --network host \
  --cap-add NET_RAW \
  --cap-add NET_ADMIN \
  --volume "${OUTPUT_DIR}:/captures" \
  "${NETSHOOT_IMAGE}" \
  tcpdump -i "${INTERFACE}" -U -s 0 -w /captures/s7-qualification.pcap \
  "${capture_filter}" >/dev/null

sleep 1

set +e
(
  cd "${ROOT}"
  S7_QUAL_REPORT_DIR="${OUTPUT_DIR}" \
    mix test --include qualification test/qualification/classic_client_test.exs --trace
) 2>&1 | tee "${TEST_LOG}"
test_status="${PIPESTATUS[0]}"
set -e

sleep 1
docker stop --timeout 10 "${CAPTURE_CONTAINER}" >/dev/null
docker wait "${CAPTURE_CONTAINER}" >/dev/null
docker rm "${CAPTURE_CONTAINER}" >/dev/null

set +e
docker run --rm \
  --volume "${OUTPUT_DIR}:/captures" \
  "${NETSHOOT_IMAGE}" \
  tshark -r /captures/s7-qualification.pcap -d "tcp.port==${PORT},tpkt" \
  -Y s7comm >"${DECODED}" 2>"${OUTPUT_DIR}/tshark-stderr.txt"
decode_status=$?

malformed="$({
  docker run --rm \
    --volume "${OUTPUT_DIR}:/captures" \
    "${NETSHOOT_IMAGE}" \
    tshark -r /captures/s7-qualification.pcap -d "tcp.port==${PORT},tpkt" \
    -Y _ws.malformed -T fields -e frame.number
} 2>/dev/null)"
malformed_status=$?
set -e

decoded_count="$(wc -l <"${DECODED}")"
capture_hash="$(sha256sum "${PCAP}" | cut -d ' ' -f 1)"
revision="$(git -C "${ROOT}" rev-parse HEAD)"
missing_protocol=()

for pattern in "Setup communication" "Function:[Read Var]" "Function:[Write Var]"; do
  if ! grep -Fq "${pattern}" "${DECODED}"; then
    missing_protocol+=("${pattern}")
  fi
done

missing_protocol_text="none"

if [[ "${#missing_protocol[@]}" -gt 0 ]]; then
  missing_protocol_text="$(IFS='; '; echo "${missing_protocol[*]}")"
fi

status="PASS"

if [[ "${test_status}" -ne 0 ]] || [[ "${decode_status}" -ne 0 ]] || \
  [[ "${malformed_status}" -ne 0 ]] || [[ -n "${malformed}" ]] || \
  [[ "${decoded_count}" -eq 0 ]] || [[ "${#missing_protocol[@]}" -gt 0 ]]; then
  status="FAIL"
fi

{
  printf '# Classic S7comm Qualification Report\n\n'
  printf -- '- Status: `%s`\n' "${status}"
  printf -- '- Date (UTC): `%s`\n' "${TIMESTAMP}"
  printf -- '- Git revision: `%s`\n' "${revision}"
  printf -- '- Target family: `%s`\n' "${FAMILY}"
  printf -- '- Configured order number: `%s`\n' "${S7_QUAL_ORDER_NUMBER}"
  printf -- '- Firmware: `%s`\n' "${S7_QUAL_FIRMWARE}"
  printf -- '- Access configuration: `%s`\n' "${S7_QUAL_ACCESS}"
  printf -- '- Endpoint: `%s:%s`, rack `%s`, slot `%s`\n' \
    "${HOST}" "${PORT}" "${S7_QUAL_RACK:-0}" "${S7_QUAL_SLOT:-2}"
  printf -- '- Declared capabilities: `%s`\n' "${S7_QUAL_CAPABILITIES:-core}"
  printf -- '- ExUnit exit status: `%s`\n' "${test_status}"
  printf -- '- tshark exit status: `%s`\n' "${decode_status}"
  printf -- '- Decoded S7comm frames: `%s`\n' "${decoded_count}"
  printf -- '- Malformed frame numbers: `%s`\n' "${malformed:-none}"
  printf -- '- Missing core protocol labels: `%s`\n' "${missing_protocol_text}"
  printf -- '- Capture SHA-256: `%s`\n\n' "${capture_hash}"
  printf '## Negotiation\n\n```text\n'
  cat "${OUTPUT_DIR}/session-metadata.txt" 2>/dev/null || true
  cat "${OUTPUT_DIR}/observed-identity.txt" 2>/dev/null || true
  printf '```\n\n'
  printf 'The complete ExUnit output is in `exunit.log`; decoded frames are in `tshark-s7comm.txt`.\n\n'
  printf 'The packet capture may contain operational metadata and must be handled according to `SECURITY.md`.\n'
} >"${REPORT}"

printf 'Qualification %s: %s\n' "${status}" "${REPORT}"
printf 'Capture: %s (%s)\n' "${PCAP}" "${capture_hash}"

if [[ "${status}" != "PASS" ]]; then
  exit 1
fi
