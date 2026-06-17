#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_URL="${GATEWAY_BASE_URL:-https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4.1}"
JWT_ISSUER="${JWT_ISSUER:-kong-poc}"
JWT_SECRET="${JWT_SECRET:-poc-secret-change-me}"
JWT_SUBJECT="${JWT_SUBJECT:-poc-user}"
JWT_TTL_SECONDS="${JWT_TTL_SECONDS:-3600}"
SSE_TIMEOUT_SECONDS="${SSE_TIMEOUT_SECONDS:-20}"
MESSAGE_TIMEOUT_SECONDS="${MESSAGE_TIMEOUT_SECONDS:-60}"
CHAT_TIMEOUT_SECONDS="${CHAT_TIMEOUT_SECONDS:-60}"
KEEP_TEST_ARTIFACTS="${KEEP_TEST_ARTIFACTS:-0}"
TMP_DIR="${SCRIPT_DIR}/.tmp-mcp-gateway-$$"
SSE_RAW="${TMP_DIR}/sse-stream.txt"
SSE_STDERR="${TMP_DIR}/sse-stderr.txt"
INVALID_JSON_FILE="${TMP_DIR}/invalid-json.txt"

PASS_COUNT=0
FAIL_COUNT=0
SSE_PID=""
SESSION_ID=""

mkdir -p "${TMP_DIR}"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Python 3 is required." >&2
  exit 1
fi

cleanup() {
  if [[ -n "${SSE_PID}" ]] && kill -0 "${SSE_PID}" 2>/dev/null; then
    kill "${SSE_PID}" 2>/dev/null || true
    wait "${SSE_PID}" 2>/dev/null || true
  fi

  if [[ "${KEEP_TEST_ARTIFACTS}" != "1" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

trap cleanup EXIT

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_command curl

make_jwt() {
  local secret="$1"
  "${PYTHON_BIN}" - "$JWT_ISSUER" "$JWT_SUBJECT" "$secret" "$JWT_TTL_SECONDS" <<'PY'
import base64
import hashlib
import hmac
import json
import sys
import time

issuer, subject, secret, ttl = sys.argv[1], sys.argv[2], sys.argv[3].encode(), int(sys.argv[4])

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

header = {"alg": "HS256", "typ": "JWT"}
payload = {
    "iss": issuer,
    "sub": subject,
    "exp": int(time.time()) + ttl
}

signing_input = ".".join(
    [
        b64url(json.dumps(header, separators=(",", ":")).encode()),
        b64url(json.dumps(payload, separators=(",", ":")).encode())
    ]
).encode()

signature = hmac.new(secret, signing_input, hashlib.sha256).digest()
print(signing_input.decode() + "." + b64url(signature))
PY
}

TOKEN="${JWT_TOKEN:-$(make_jwt "${JWT_SECRET}")}"
INVALID_TOKEN="${INVALID_JWT_TOKEN:-$(make_jwt "${JWT_SECRET}-invalid")}"

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "[PASS] $1"
}

record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "[FAIL] $1"
  if [[ $# -ge 2 && -n "${2:-}" ]]; then
    echo "       $2"
  fi
}

http_status() {
  local headers_file="$1"
  awk 'toupper($1) ~ /^HTTP\// { code=$2 } END { if (code) print code }' "${headers_file}"
}

json_assert_file() {
  local file_path="$1"
  local expression="$2"

  "${PYTHON_BIN}" - "${file_path}" "${expression}" <<'PY'
import json
import sys

path, expression = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    obj = json.load(handle)

safe_builtins = {
    "len": len,
    "all": all,
    "any": any,
    "bool": bool,
    "isinstance": isinstance,
    "str": str,
    "int": int,
    "float": float
}

if not eval(expression, {"__builtins__": safe_builtins}, {"obj": obj}):
    raise SystemExit(1)
PY
}

extract_session_id() {
  "${PYTHON_BIN}" - "${SSE_RAW}" <<'PY'
import re
import sys

try:
    text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
except FileNotFoundError:
    raise SystemExit(1)

match = re.search(r"sessionId=([A-Za-z0-9-]+)", text)
if not match:
    raise SystemExit(1)

print(match.group(1))
PY
}

wait_for_session_id() {
  local attempts=40
  local session=""

  for ((i = 0; i < attempts; i++)); do
    if session=$(extract_session_id 2>/dev/null); then
      echo "${session}"
      return 0
    fi

    sleep 0.5
  done

  return 1
}

wait_for_headers() {
  local file_path="$1"
  local attempts=20

  for ((i = 0; i < attempts; i++)); do
    if [[ -s "${file_path}" ]]; then
      return 0
    fi

    sleep 0.5
  done

  return 1
}

extract_jsonrpc_response() {
  local request_id="$1"
  local output_file="$2"

  "${PYTHON_BIN}" - "${SSE_RAW}" "${request_id}" "${output_file}" <<'PY'
import json
import sys

body_path, request_id, output_path = sys.argv[1], str(sys.argv[2]), sys.argv[3]

try:
    lines = open(body_path, encoding="utf-8", errors="ignore").read().splitlines()
except FileNotFoundError:
    raise SystemExit(1)

event_name = None
data_lines = []
match = None

for line in lines + [""]:
    if line.startswith("event:"):
        event_name = line.split(":", 1)[1].strip()
    elif line.startswith("data:"):
        data_lines.append(line.split(":", 1)[1].lstrip())
    elif line == "":
        if event_name == "message" and data_lines:
            payload = "\n".join(data_lines).strip()
            if payload.startswith("{"):
                try:
                    parsed = json.loads(payload)
                except json.JSONDecodeError:
                    parsed = None
                if parsed is not None and str(parsed.get("id")) == request_id:
                    match = parsed
        event_name = None
        data_lines = []

if match is None:
    raise SystemExit(1)

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(match, handle)
PY
}

wait_for_jsonrpc_response() {
  local request_id="$1"
  local output_file="$2"
  local attempts=60

  for ((i = 0; i < attempts; i++)); do
    if extract_jsonrpc_response "${request_id}" "${output_file}" 2>/dev/null; then
      return 0
    fi

    sleep 0.5
  done

  return 1
}

send_mcp_request() {
  local request_id="$1"
  local payload="$2"
  local prefix="$3"
  local body_file="${TMP_DIR}/${prefix}-body.txt"
  local status

  status=$(curl -sS \
    --max-time "${MESSAGE_TIMEOUT_SECONDS}" \
    -o "${body_file}" \
    -w "%{http_code}" \
    -X POST "${BASE_URL}/mcp/messages?sessionId=${SESSION_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-raw "${payload}")
  if [[ "${status}" != "200" && "${status}" != "202" ]]; then
    return 1
  fi

  if [[ -n "${request_id}" ]]; then
    wait_for_jsonrpc_response "${request_id}" "${TMP_DIR}/${prefix}-response.json"
  fi
}

echo "MCP Gateway test suite"
echo "Base URL    : ${BASE_URL}"
echo "OpenAI model: ${OPENAI_MODEL}"
echo ""

INVALID_AUTH_BODY="${TMP_DIR}/invalid-auth-body.txt"

INVALID_AUTH_STATUS=$(curl -sS \
  --max-time 15 \
  -o "${INVALID_AUTH_BODY}" \
  -w "%{http_code}" \
  "${BASE_URL}/mcp/sse" \
  -H "Authorization: Bearer ${INVALID_TOKEN}" || true)
if [[ "${INVALID_AUTH_STATUS}" == "401" || "${INVALID_AUTH_STATUS}" == "403" ]]; then
  record_pass "Invalid JWT is rejected by /mcp/sse"
else
  record_fail "Invalid JWT is rejected by /mcp/sse" "Expected HTTP 401/403, got ${INVALID_AUTH_STATUS:-<none>}"
fi

curl -sS -N -i \
  "${BASE_URL}/mcp/sse" \
  -H "Authorization: Bearer ${TOKEN}" \
  >"${SSE_RAW}" 2>"${SSE_STDERR}" &
SSE_PID=$!

if wait_for_headers "${SSE_RAW}"; then
  SSE_STATUS=$(http_status "${SSE_RAW}")
else
  SSE_STATUS=""
fi

if [[ "${SSE_STATUS}" == "200" ]]; then
  record_pass "SSE endpoint accepts a valid JWT"
else
  record_fail "SSE endpoint accepts a valid JWT" "Expected HTTP 200, got ${SSE_STATUS:-<none>}"
fi

if SESSION_ID=$(wait_for_session_id); then
  record_pass "SSE handshake returns a sessionId"
else
  SESSION_ID=""
  record_fail "SSE handshake returns a sessionId" "Timed out waiting for sessionId in ${SSE_RAW}"
fi

if [[ -n "${SESSION_ID}" ]]; then
  if send_mcp_request \
    "1" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-gateway-test","version":"1.0.0"}}}' \
    "initialize" \
    && json_assert_file "${TMP_DIR}/initialize-response.json" \
      "obj['jsonrpc'] == '2.0' and obj['id'] == 1 and obj['result']['serverInfo']['name'] == 'mock-api-mcp-server' and obj['result']['protocolVersion']"; then
    record_pass "MCP initialize returns server metadata"
  else
    record_fail "MCP initialize returns server metadata"
  fi

  if send_mcp_request \
    "" \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    "initialized-notification"; then
    :
  fi

  if send_mcp_request \
    "2" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    "tools-list" \
    && json_assert_file "${TMP_DIR}/tools-list-response.json" \
      "obj['jsonrpc'] == '2.0' and obj['id'] == 2 and any(tool['name'] == 'get_weather' for tool in obj['result']['tools']) and any(tool['name'] == 'calculate' for tool in obj['result']['tools'])"; then
    record_pass "tools/list returns get_weather and calculate"
  else
    record_fail "tools/list returns get_weather and calculate"
  fi

  if send_mcp_request \
    "3" \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_weather","arguments":{"location":"Seattle"}}}' \
    "tool-weather" \
    && json_assert_file "${TMP_DIR}/tool-weather-response.json" \
      "obj['jsonrpc'] == '2.0' and obj['id'] == 3 and obj['result']['structuredContent']['location'] == 'Seattle' and isinstance(obj['result']['structuredContent']['temperature'], int) and isinstance(obj['result']['structuredContent']['condition'], str)"; then
    record_pass "tools/call get_weather returns structured weather data"
  else
    record_fail "tools/call get_weather returns structured weather data"
  fi

  if send_mcp_request \
    "4" \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"calculate","arguments":{"operation":"multiply","a":6,"b":7}}}' \
    "tool-calculate" \
    && json_assert_file "${TMP_DIR}/tool-calculate-response.json" \
      "obj['jsonrpc'] == '2.0' and obj['id'] == 4 and obj['result']['structuredContent']['result'] == 42 and obj['result']['structuredContent']['operation'] == 'multiply'"; then
    record_pass "tools/call calculate returns the expected result"
  else
    record_fail "tools/call calculate returns the expected result"
  fi
fi

MISSING_SESSION_BODY="${TMP_DIR}/missing-session-body.json"

MISSING_SESSION_STATUS=$(curl -sS \
  --max-time "${MESSAGE_TIMEOUT_SECONDS}" \
  -o "${MISSING_SESSION_BODY}" \
  -w "%{http_code}" \
  -X POST "${BASE_URL}/mcp/messages" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-raw '{"jsonrpc":"2.0","id":99,"method":"tools/list","params":{}}' || true)
if [[ "${MISSING_SESSION_STATUS}" == "400" ]] \
  && json_assert_file "${MISSING_SESSION_BODY}" "obj['error'] == 'Missing sessionId query parameter'"; then
  record_pass "Missing sessionId is rejected with HTTP 400"
else
  record_fail "Missing sessionId is rejected with HTTP 400" "Expected HTTP 400 and missing sessionId error"
fi

if [[ -n "${SESSION_ID}" ]]; then
  printf '%s' '{"jsonrpc":' >"${INVALID_JSON_FILE}"
  INVALID_JSON_BODY="${TMP_DIR}/invalid-json-body.json"

  INVALID_JSON_STATUS=$(curl -sS \
    --max-time "${MESSAGE_TIMEOUT_SECONDS}" \
    -o "${INVALID_JSON_BODY}" \
    -w "%{http_code}" \
    -X POST "${BASE_URL}/mcp/messages?sessionId=${SESSION_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${INVALID_JSON_FILE}" || true)
  if [[ "${INVALID_JSON_STATUS}" =~ ^(400|500)$ ]] \
    && json_assert_file "${INVALID_JSON_BODY}" "'error' in obj and bool(obj['error'])"; then
    record_pass "Invalid JSON is rejected with an error response"
  else
    record_fail "Invalid JSON is rejected with an error response" "Expected HTTP 400/500 and JSON error payload"
  fi
fi

CHAT_BODY="${TMP_DIR}/chat-body.json"

CHAT_STATUS=$(curl -sS \
  --max-time "${CHAT_TIMEOUT_SECONDS}" \
  -o "${CHAT_BODY}" \
  -w "%{http_code}" \
  -X POST "${BASE_URL}/chat" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-raw "$(cat <<JSON
{"model":"${OPENAI_MODEL}","messages":[{"role":"user","content":"Reply with: gateway ok"}]}
JSON
)")
if [[ "${CHAT_STATUS}" == "200" ]] \
  && json_assert_file "${CHAT_BODY}" \
    "len(obj['choices']) > 0 and 'message' in obj['choices'][0] and 'content' in obj['choices'][0]['message'] and 'gateway ok' in obj['choices'][0]['message']['content'].lower()"; then
  record_pass "Azure OpenAI /chat returns a valid completion"
else
  record_fail "Azure OpenAI /chat returns a valid completion" "Expected HTTP 200 and a completion containing 'gateway ok'"
fi

echo ""
echo "Passed: ${PASS_COUNT}"
echo "Failed: ${FAIL_COUNT}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
