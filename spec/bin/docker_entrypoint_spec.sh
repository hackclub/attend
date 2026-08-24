#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
calls_file="$test_root/calls"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/bin"

cat > "$test_root/bin/rails" <<'SCRIPT'
#!/bin/bash
printf 'rails:%s\n' "$*" >> "$CALLS_FILE"
SCRIPT

cat > "$test_root/bin/jobs" <<'SCRIPT'
#!/bin/bash
printf 'jobs:%s\n' "$*" >> "$CALLS_FILE"
SCRIPT

cat > "$test_root/bin/thrust" <<'SCRIPT'
#!/bin/bash
printf 'thrust:%s\n' "$*" >> "$CALLS_FILE"
SCRIPT

chmod +x "$test_root/bin/rails" "$test_root/bin/jobs" "$test_root/bin/thrust"

(
  cd "$test_root"
  CALLS_FILE="$calls_file" PROCESS_TYPE=worker \
    "$repo_root/bin/docker-entrypoint" ./bin/thrust ./bin/rails server >/dev/null
)

if ! grep -qx 'jobs:' "$calls_file"; then
  echo "worker process did not start bin/jobs" >&2
  exit 1
fi
if grep -q '^rails:db:prepare$' "$calls_file"; then
  echo "worker process ran db:prepare" >&2
  exit 1
fi
if grep -q '^thrust:' "$calls_file"; then
  echo "worker process started the web server" >&2
  exit 1
fi

: > "$calls_file"

set +e
(
  cd "$test_root"
  CALLS_FILE="$calls_file" PROCESS_TYPE=workre \
    "$repo_root/bin/docker-entrypoint" ./bin/thrust ./bin/rails server >/dev/null 2>&1
)
invalid_status=$?
set -e

if [ "$invalid_status" -eq 0 ]; then
  echo "invalid process type did not fail" >&2
  exit 1
fi
if [ -s "$calls_file" ]; then
  echo "invalid process type started a container process" >&2
  exit 1
fi

: > "$calls_file"

(
  cd "$test_root"
  CALLS_FILE="$calls_file" \
    "$repo_root/bin/docker-entrypoint" ./bin/thrust ./bin/rails server >/dev/null
)

grep -qx 'rails:db:prepare' "$calls_file"
grep -qx 'rails:db:ensure_secondary_schemas' "$calls_file"
grep -qx 'thrust:./bin/rails server' "$calls_file"
