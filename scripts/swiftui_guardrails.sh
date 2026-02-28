#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
    echo "error: ripgrep (rg) is required" >&2
    exit 2
fi

SWIFT_FILES=()
while IFS= read -r file; do
    SWIFT_FILES+=("$file")
done < <(rg --files -g '*.swift' App Core Features)

if [[ ${#SWIFT_FILES[@]} -eq 0 ]]; then
    echo "No Swift files found under App/Core/Features."
    exit 0
fi

FAILURES=0

echo "1) Checking for deprecated one-parameter .onChange..."
ON_CHANGE_PATTERN='\.onChange\s*\(\s*of:[^)]*\)\s*\{\s*(?:\(\s*)?[_A-Za-z][_A-Za-z0-9]*(?:\s*:\s*[^,)]+)?(?:\s*\))?\s+in'
if ON_CHANGE_HITS="$(rg -n -U --pcre2 "$ON_CHANGE_PATTERN" "${SWIFT_FILES[@]}" || true)"; [[ -n "$ON_CHANGE_HITS" ]]; then
    echo "Found deprecated one-parameter .onChange usage:"
    echo "$ON_CHANGE_HITS"
    FAILURES=1
else
    echo "OK"
fi

echo "2) Checking GeometryReader justification markers..."
for file in "${SWIFT_FILES[@]}"; do
    if ! awk -v file="$file" '
        {
            if ($0 ~ /GeometryReader[[:space:]]*\{/) {
                if (prev !~ /swiftui-allow:geometryreader/) {
                    printf "%s:%d: GeometryReader requires a preceding // swiftui-allow:geometryreader reason\n", file, NR
                    bad = 1
                }
            }
            prev = $0
        }
        END { exit bad }
    ' "$file"; then
        FAILURES=1
    fi
done
if [[ $FAILURES -eq 0 ]]; then
    echo "OK"
fi

echo "3) Checking nested scroll containers (ScrollView/List/Form)..."
for file in "${SWIFT_FILES[@]}"; do
    if ! awk -v file="$file" '
        BEGIN {
            depth = 0
            stackSize = 0
            bad = 0
        }
        {
            line = $0

            if (line ~ /^[[:space:]]*\/\//) {
                next
            }

            isContainer = (line ~ /(^|[^A-Za-z0-9_])(ScrollView|List|Form)[[:space:]]*\(/)
            opens = gsub(/\{/, "{", line)
            closes = gsub(/\}/, "}", line)

            if (isContainer) {
                if (stackSize > 0) {
                    printf "%s:%d: nested scroll container detected (%s)\n", file, NR, line
                    bad = 1
                }
                if (opens > 0) {
                    stackSize += 1
                    stack[stackSize] = depth + 1
                }
            }

            depth += opens
            depth -= closes
            if (depth < 0) {
                depth = 0
            }

            while (stackSize > 0 && stack[stackSize] > depth) {
                stackSize -= 1
            }
        }
        END { exit bad }
    ' "$file"; then
        FAILURES=1
    fi
done

if [[ $FAILURES -ne 0 ]]; then
    echo "SwiftUI guardrails failed."
    exit 1
fi

echo "SwiftUI guardrails passed."
