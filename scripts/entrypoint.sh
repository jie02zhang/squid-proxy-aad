#!/bin/bash
# ============================================================
# Squid 代理启动脚本（支持 ROPC + MFA 双模式认证）
#
# 作用：
#   1. 检测 SSL 证书是否存在
#   2. 替换 squid.conf 中的环境变量占位符
#   3. 复制认证脚本到 /tmp 并处理 Windows 换行符
#   4. 启动 Squid
#
# 版本：v11（支持 MFA 认证）
# ============================================================

echo "============================================"
echo "Squid + Azure AD ROPC + MFA 启动脚本"
echo "============================================"

# ---- 环境变量 ----
# PROXY_HOSTNAME: 代理服务器主机名（域名或 IP）
#   - 默认值：proxy.test.com
#   - 测试环境可改为 IP（如 172.23.95.36）
PROXY_HOSTNAME="${PROXY_HOSTNAME:-proxy.test.com}"

# DOMAIN: 证书域名（用于替换 __DOMAIN__ 占位符）
#   - 默认值：test.com（自签名证书）
#   - 生产环境改为实际域名（如 envision-energy.com）
DOMAIN="${DOMAIN:-test.com}"

# OAUTH2_PROXY_URL: OAuth2 Proxy 服务地址（用于 Token 验证）
#   - 默认值：http://oauth2-proxy:4180（容器内通信）
OAUTH2_PROXY_URL="${OAUTH2_PROXY_URL:-http://oauth2-proxy:4180}"

echo "==> 环境变量检查"
echo "    代理主机名: $PROXY_HOSTNAME"
echo "    证书域名: $DOMAIN"
echo "    OAuth2 Proxy URL: $OAUTH2_PROXY_URL"
echo ""

# ============================================
# 步骤 1: 准备 Squid 配置文件
# ============================================
echo "==> [1/7] 准备 Squid 配置文件..."

SQUID_CONF_SRC="/etc/squid/squid.conf"
SQUID_CONF_TMP="/tmp/squid.conf"

# 复制配置文件到 /tmp
cp "$SQUID_CONF_SRC" "$SQUID_CONF_TMP"

# 替换域名变量（证书路径）
sed -i "s|__DOMAIN__|$DOMAIN|g" "$SQUID_CONF_TMP"
echo "    ✓ 证书域名已替换: $DOMAIN"

# 替换代理主机名
sed -i "s|__PROXY_HOSTNAME__|$PROXY_HOSTNAME|g" "$SQUID_CONF_TMP"
echo "    ✓ 代理主机名已替换: $PROXY_HOSTNAME"

# 替换 OAuth2 Proxy URL
sed -i "s|__OAUTH2_PROXY_URL__|$OAUTH2_PROXY_URL|g" "$SQUID_CONF_TMP"
echo "    ✓ OAuth2 Proxy URL 已替换: $OAUTH2_PROXY_URL"

# 检查配置文件语法
echo "==> [2/7] 检查 Squid 配置文件语法..."
squid -z 2>&1 | grep -v "Creating missing" || true
if squid -k parse 2>&1 | grep -q "ERROR"; then
    echo "    ✗ 配置文件语法错误"
    squid -k parse
    exit 1
fi
echo "    ✓ 配置文件语法正确"

# ============================================
# 步骤 3: 准备认证脚本
# ============================================
echo "==> [3/7] 准备认证脚本..."

# 复制 ROPC 认证脚本
if [ -f "/usr/local/bin/squid_aad_auth.sh" ]; then
    cp /usr/local/bin/squid_aad_auth.sh /tmp/squid_aad_auth.sh
    sed -i 's/\r$//' /tmp/squid_aad_auth.sh
    chmod +x /tmp/squid_aad_auth.sh
    echo "    ✓ ROPC 认证脚本已准备"
fi

# 复制 MFA Token 验证脚本
if [ -f "/usr/local/bin/squid_oauth_validate.sh" ]; then
    cp /usr/local/bin/squid_oauth_validate.sh /tmp/squid_oauth_validate.sh
    sed -i 's/\r$//' /tmp/squid_oauth_validate.sh
    chmod +x /tmp/squid_oauth_validate.sh
    echo "    ✓ MFA Token 验证脚本已准备"
fi

# ============================================
# 步骤 4: 创建必要目录
# ============================================
echo "==> [4/7] 创建必要目录..."

mkdir -p /data/log/auth_cache
mkdir -p /data/log/tokens
mkdir -p /data/run
mkdir -p /data/cache

chown -R proxy:proxy /data/log /data/run /data/cache 2>/dev/null || true

echo "    ✓ 目录创建完成"

# ============================================
# 步骤 5: 初始化 Squid 缓存目录
# ============================================
echo "==> [5/7] 初始化 Squid 缓存目录..."
squid -z 2>&1 | grep -v "Creating missing" || true
echo "    ✓ 缓存目录初始化完成"

# ============================================
# 步骤 6: 启动 OAuth2 Proxy（如果配置了）
# ============================================
echo "==> [6/7] 检查 OAuth2 Proxy 配置..."

if [ -n "$AAD_TENANT_ID" ] && [ -n "$AAD_CLIENT_ID" ] && [ -n "$AAD_CLIENT_SECRET" ]; then
    echo "    ✓ OAuth2 Proxy 配置完整（MFA 模式可用）"
    echo "    登录 URL: https://$PROXY_HOSTNAME:3129/login"
else
    echo "    ⚠ OAuth2 Proxy 配置不完整（MFA 模式不可用）"
    echo "    请确保 .env 文件中配置了 AAD_TENANT_ID, AAD_CLIENT_ID, AAD_CLIENT_SECRET"
fi

# ============================================
# 步骤 7: 启动 Squid
# ============================================
echo "==> [7/7] 启动 Squid..."
echo "    端口 3128: ROPC 认证（Basic Auth）"
echo "    端口 3129: MFA 认证（Token 验证）"

# 前台运行 Squid（Docker 容器需要前台进程）
exec squid -N -d 1 2>&1
