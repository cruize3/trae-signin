#!/usr/bin/env bash
# signin.sh — TRAE 批量签到脚本
set -e
cd "$(dirname "$0")"

# 构建签到程序（仅在源码比二进制新或二进制不存在时重新编译）
# 清理可能过期的 GOROOT（防止 go 版本与 GOROOT 不匹配导致编译失败）
unset GOROOT
if [ ! -f signin_bin ] || [ -n "$(find ./cmd ./internal -name '*.go' -newer signin_bin 2>/dev/null | head -1)" ]; then
  go clean -cache 2>/dev/null || true
  go build -o signin_bin ./cmd/signin
fi

# 执行签到
./signin_bin "${1:-auths}"
