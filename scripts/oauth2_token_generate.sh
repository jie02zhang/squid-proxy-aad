#!/bin/bash
# ============================================================
# OAuth2 Proxy Token 生成脚本
#
# 作用：用户完成 MFA 登录后，生成 Token
# 使用场景：MFA 认证模式（用户登录后获取 Token）
#
# 工作原理：
#   1. 用户输入用户名和 Token 有效期
#   2. 脚本生成随机 Token
#   3. 脚本将 Token 保存到 /data/log/tokens/<token>
#   4. 脚本显示 Token 给用户
#
# 使用方法：
#   ./oauth2_token_generate.sh <username> <expire_hours>
#   示例：./oauth2_token_generate.sh user@example.com 24
#
# 版本：v1.0（MFA 认证支持）
# ============================================================

# 参数检查
if [ $# -lt 2 ]; then
    echo "Usage: $0 <username> <expire_hours>"
    echo "Example: $0 user@example.com 24"
    exit 1
fi

USERNAME="$1"
EXPIRE_HOURS="$2"

# Token 存储目录
TOKEN_DIR="/data/log/tokens"

# 确保目录存在
mkdir -p "$TOKEN_DIR" 2>/dev/null
chown -R proxy:proxy "$TOKEN_DIR" 2>/dev/null || true

# 生成随机 Token（43 字符，与 OAuth2 Proxy Cookie Secret 长度一致）
TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(43))" 2>/dev/null || openssl rand -base64 43 2>/dev/null | tr -d '\n')

if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to generate token"
    exit 1
fi

# 计算过期时间
EXPIRE_TIMESTAMP=$(( $(date +%s) + EXPIRE_HOURS * 3600 ))

# 保存 Token 信息（格式：<username>|<expire_timestamp>）
echo "$USERNAME|$EXPIRE_TIMESTAMP" > "$TOKEN_DIR/$TOKEN"

# 设置文件权限
chown proxy:proxy "$TOKEN_DIR/$TOKEN" 2>/dev/null || true
chmod 600 "$TOKEN_DIR/$TOKEN"

# 显示 Token 给用户
echo "============================================"
echo "Token generated successfully!"
echo "============================================"
echo "Username: $USERNAME"
echo "Token: $TOKEN"
echo "Expire: $(date -d @$EXPIRE_TIMESTAMP '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $EXPIRE_TIMESTAMP '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""
echo "使用方法（配置代理）："
echo "  用户名: token"
echo "  密码: $TOKEN"
echo "============================================"

exit 0
