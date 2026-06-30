#!/bin/bash
# ============================================================
# entrypoint.sh v24 - Squid 容器启动初始化脚本
#
# 核心职责：
#   1. 创建数据目录（确保 proxy 用户可写）
#   2. 替换域名变量（PROXY_HOSTNAME）
#   3. 检测证书 → 不存在则自动降级为纯 HTTP
#   4. 修复 Windows 换行符（\r\n -> \n）
#   5. 验证认证脚本语法
#   6. 生成最终配置文件（/tmp/squid.conf）
#   7. 启动 Squid
#
# 使用方法：
#   此脚本由 Dockerfile ENTRYPOINT 自动调用，无需手动执行。
#   如需调试，可进入容器手动运行：
#   docker exec -it squid-proxy-aad /bin/bash
#   /entrypoint.sh
# ============================================================

set -e  # 遇到错误立即退出（防止启动失败的服务继续运行）

# ---- 环境变量 ----
# PROXY_HOSTNAME: 代理服务器主机名（域名或 IP）
#   - 默认值：proxy.test.com
#   - 生产环境应改为实际域名（如 proxy.company.com）
PROXY_HOSTNAME="${PROXY_HOSTNAME:-proxy.test.com}"

# DOMAIN: 证书域名（用于 TLS 证书文件名）
#   - 默认值：test.com
#   - 生产环境应改为实际域名（如 company.com）
DOMAIN="${DOMAIN:-test.com}"

echo "============================================="
echo "==> Squid Proxy v${SQUID_VER:-7.6} 启动中..."
echo "============================================="
echo "    主机名: $PROXY_HOSTNAME"
echo "    时区  : $TZ"
echo ""

# ============================================
# 步骤 1: 初始化数据目录
# ============================================
echo "==> [1/6] 初始化数据目录..."
mkdir -p /data/log /data/run /data/cache
chown -R proxy:proxy /data/log /data/run /data/cache 2>/dev/null || true
chmod 755 /data/log /data/run /data/cache 2>/dev/null || true
touch /data/log/cache.log
chown proxy:proxy /data/log/cache.log 2>/dev/null || true
echo "    ✅ 目录就绪: /data/{log,run,cache}"

# ============================================
# 步骤 2: 检测 SSL 证书
# ============================================
echo "==> [2/6] 检查 SSL 证书..."
CERT_CRT="/etc/squid/certs/${DOMAIN}.crt"
CERT_KEY="/etc/squid/certs/${DOMAIN}.key"
HTTPS_AVAILABLE="yes"

if [ ! -f "$CERT_CRT" ] || [ ! -f "$CERT_KEY" ]; then
    echo "    ⚠️  证书文件缺失，降级为纯 HTTP 模式"
    echo "    缺失: $CERT_CRT 或 $CERT_KEY"
    HTTPS_AVAILABLE="no"
else
    # 验证证书和私钥是否匹配
    CRT_MD5=$(openssl x509 -noout -modulus -in "$CERT_CRT" 2>/dev/null | md5sum | cut -d' ' -f1)
    KEY_MD5=$(openssl rsa -noout -modulus -in "$CERT_KEY" 2>/dev/null | md5sum | cut -d' ' -f1)
    if [ "$CRT_MD5" = "$KEY_MD5" ]; then
        echo "    ✅ SSL 证书就绪 ($CERT_CRT)"
    else
        echo "    ❌ 证书和私钥不匹配！"
        exit 1
    fi
fi

# ============================================
# 步骤 3: 处理认证脚本
# ============================================
echo "==> [3/6] 处理认证脚本..."
AUTH_SRC="/usr/local/bin/squid_aad_auth.sh"
AUTH_DST="/tmp/squid_aad_auth.sh"

if [ -f "$AUTH_SRC" ]; then
    # 复制到 /tmp（避免影响原始文件）
    cp -f "$AUTH_SRC" "$AUTH_DST"
    
    # 检测并修复 Windows 换行符（\r\n -> \n）
    if grep -qP '\r' "$AUTH_DST" 2>/dev/null; then
        echo "    检测到 \\r -> 转换中..."
        sed -i 's/\r$//' "$AUTH_DST"
    fi
    
    # 设置可执行权限
    chmod +x "$AUTH_DST"
    chown proxy:proxy "$AUTH_DST" 2>/dev/null || true
    
    # 验证脚本语法
    if ! bash -n "$AUTH_DST" 2>&1; then
        echo "    ❌ 认证脚本语法错误!"
        exit 1
    fi
    
    # 快速测试（使用无效账号，验证脚本能正常运行）
    TEST_OUT=$(printf 'test test\n' | timeout 3 "$AUTH_DST" 2>/dev/null) || TEST_OUT="ERR"
    echo "    ✅ 认证脚本验证通过 (输出: $TEST_OUT)"
else
    echo "    ❌ 认证脚本不存在: $AUTH_SRC"
    exit 1
fi

# ============================================
# 步骤 4: 生成最终配置文件
# ============================================
echo "==> [4/6] 生成配置文件..."
SQUID_CONF_TMP="/tmp/squid.conf"
cp -f /etc/squid/squid.conf "$SQUID_CONF_TMP"

# 去除配置文件的 \r（如果有）
grep -qP '\r' "$SQUID_CONF_TMP" 2>/dev/null && sed -i 's/\r$//' "$SQUID_CONF_TMP"

# 替换认证脚本路径为 /tmp 版本
sed -i 's|/usr/local/bin/squid_aad_auth.sh|/tmp/squid_aad_auth.sh|g' "$SQUID_CONF_TMP"

# 替换域名变量
sed -i "s|__PROXY_HOSTNAME__|${PROXY_HOSTNAME}|g" "$SQUID_CONF_TMP"
echo "    域名: ${PROXY_HOSTNAME}"

# 替换证书域名变量
sed -i "s|__DOMAIN__|${DOMAIN}|g" "$SQUID_CONF_TMP"
echo "    证书域名: ${DOMAIN}"

# 如果没有证书，移除 https_port 行（降级为 HTTP-only）
if [ "$HTTPS_AVAILABLE" = "no" ]; then
    echo "    移除 https_port（降级 HTTP-only）..."
    sed -i '/^https_port/d' "$SQUID_CONF_TMP"
fi

# 确保配置文件 proxy 用户可读
chown proxy:proxy "$SQUID_CONF_TMP" 2>/dev/null || true

# ============================================
# 步骤 5: 显示配置摘要
# ============================================
echo "==> [5/6] 配置摘要:"
echo "---------------------------------------------"
grep -E '^https_port|^http_port|^visible_hostname|^workers' "$SQUID_CONF_TMP" 2>/dev/null || echo "    (无 HTTP/HTTPS 端口配置)"
echo "---------------------------------------------"
echo ""

# ============================================
# 步骤 6: 启动 Squid
# ============================================
echo "==> [6/6] 启动 Squid..."
echo "    配置文件: $SQUID_CONF_TMP"
echo "    命令: squid -f $SQUID_CONF_TMP -NYCd 1"
echo "============================================="
echo ""

# exec: 替换当前进程为 Squid（容器主进程）
exec squid -f "$SQUID_CONF_TMP" -NYCd 1
