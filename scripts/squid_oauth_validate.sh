#!/bin/bash
# ============================================================
# OAuth2 Proxy Token 验证脚本
#
# 作用：验证用户请求中的 Token 是否有效
# 使用场景：Squid MFA 认证模式（3129 端口）
#
# 工作原理：
#   1. Squid 通过 auth_param basic 调用此脚本
#   2. 脚本接收用户名和密码（密码 = Token）
#   3. 脚本检查 Token 文件是否存在且未过期
#   4. 如果 Token 有效 → 返回 "OK user=<username>"
#   5. 如果 Token 无效 → 返回 "ERR"
#
# Token 生成方式：
#   - 用户完成 MFA 登录后，调用生成脚本
#   - 生成脚本将 Token 保存到 /data/log/tokens/<token>
#   - Token 文件内容：<username>|<expire_timestamp>
#
# 使用方式（用户配置代理）：
#   用户名: token
#   密码: <token-string>
#
# 版本：v1.0（MFA 认证支持）
# ============================================================

# Token 存储目录
TOKEN_DIR="/data/log/tokens"

# 确保目录存在
mkdir -p "$TOKEN_DIR" 2>/dev/null
chown -R proxy:proxy "$TOKEN_DIR" 2>/dev/null || true

# 日志文件
LOG_FILE="/data/log/oauth_validate.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [oauth_validate] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# ============================================
# 主循环：读取 Squid 请求并验证 Token
# ============================================
while IFS= read -r line; do
    # Squid basic auth 格式：<username> <password>
    user=$(echo "$line" | awk '{print $1}')
    token=$(echo "$line" | awk '{print $2}')
    
    log "DEBUG: Received request - user: $user, token: ${token:0:20}..."
    
    # 检查用户名是否为 "token"
    if [ "$user" != "token" ]; then
        log "ERROR: Invalid username (must be 'token' for MFA mode)"
        echo "ERR"
        continue
    fi
    
    # 检查 Token 是否为空
    if [ -z "$token" ]; then
        log "ERROR: Empty token"
        echo "ERR"
        continue
    fi
    
    # Token 文件路径
    TOKEN_FILE="$TOKEN_DIR/$token"
    
    # 检查 Token 文件是否存在
    if [ ! -f "$TOKEN_FILE" ]; then
        log "ERROR: Token not found: $token"
        echo "ERR"
        continue
    fi
    
    # 读取 Token 信息
    TOKEN_INFO=$(cat "$TOKEN_FILE" 2>/dev/null)
    
    if [ -z "$TOKEN_INFO" ]; then
        log "ERROR: Failed to read token file: $TOKEN_FILE"
        echo "ERR"
        continue
    fi
    
    # 解析 Token 信息（格式：<username>|<expire_timestamp>）
    TOKEN_USER=$(echo "$TOKEN_INFO" | cut -d'|' -f1)
    TOKEN_EXPIRE=$(echo "$TOKEN_INFO" | cut -d'|' -f2)
    
    # 检查 Token 是否过期
    CURRENT_TIME=$(date +%s)
    
    if [ "$CURRENT_TIME" -gt "$TOKEN_EXPIRE" ]; then
        log "ERROR: Token expired (expire: $TOKEN_EXPIRE, current: $CURRENT_TIME)"
        # 删除过期 Token
        rm -f "$TOKEN_FILE" 2>/dev/null
        echo "ERR"
        continue
    fi
    
    # Token 有效
    log "SUCCESS: Token valid for user: $TOKEN_USER"
    echo "OK user=$TOKEN_USER"
    
done
