#!/usr/bin/env bash
#
# Generate a JWT for the Kong MCP Gateway so it can be pasted into a
# Microsoft Foundry project connection.
#
# Usage:
#   bash scripts/generate-foundry-jwt.sh
#   bash scripts/generate-foundry-jwt.sh --ttl 3600 --issuer kong-poc --subject foundry-poc
#
# Environment variable overrides:
#   KONG_JWT_SECRET or JWT_SECRET   HMAC secret (default: poc-secret-change-me)
#   JWT_ISSUER                      issuer claim (default: kong-poc)
#   JWT_TTL_SECONDS                 token lifetime in seconds (default: 3600)
#   JWT_SUBJECT                     optional subject claim
#
# Output:
#   Plain JWT token string only. In Foundry, paste it as:
#   Bearer <token>

set -euo pipefail

TTL_SECONDS="${JWT_TTL_SECONDS:-3600}"
ISSUER="${JWT_ISSUER:-kong-poc}"
SUBJECT="${JWT_SUBJECT:-}"
SECRET="${KONG_JWT_SECRET:-${JWT_SECRET:-poc-secret-change-me}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ttl)
      TTL_SECONDS="$2"
      shift 2
      ;;
    --issuer)
      ISSUER="$2"
      shift 2
      ;;
    --subject)
      SUBJECT="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$TTL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TTL_SECONDS" -le 0 ]]; then
  echo "TTL must be a positive integer." >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Python 3 is required." >&2
  exit 1
fi

"${PYTHON_BIN}" - "$ISSUER" "$SECRET" "$TTL_SECONDS" "$SUBJECT" <<'PY'
import sys
import time

try:
    import jwt
except ImportError as exc:
    raise SystemExit("PyJWT is required to generate the Foundry JWT.") from exc

issuer, secret, ttl, subject = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

payload = {
    "iss": issuer,
    "exp": int(time.time()) + ttl,
}

if subject:
    payload["sub"] = subject

token = jwt.encode(payload, secret, algorithm="HS256")
print(token if isinstance(token, str) else token.decode())
PY
