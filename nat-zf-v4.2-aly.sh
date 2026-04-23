#!/usr/bin/env bash
# 兼容入口：aliyun 增强版功能已合并到主脚本。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/nat-zf-v4.2.sh" "$@"
