#!/bin/zsh
# Protocol tests: pairing, reconnect, stranger refused, closed window refused, man-in-the-middle, tampering. No hardware needed.
set -e
cd "$(dirname $0)/.."
mkdir -p build
swiftc -O Tests/handshake/main.swift Sources/Shared/Wire.swift -o build/handshake-tests
out=$(build/handshake-tests)
echo "$out"
echo "$out" | grep -q "completed: true true" && echo "$out" | grep -q "reconnect completed: true true" && echo "$out" | grep -q "stranger refused" && echo "$out" | grep -q "closed refused" && echo "$out" | grep -q "differ" && echo "$out" | grep -q "tampered reveal refused" && echo "PASS" || { echo "FAIL"; exit 1; }
