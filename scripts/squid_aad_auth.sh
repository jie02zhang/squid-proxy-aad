#!/bin/bash
# ============================================================
# Squid Azure AD ROPC 验证脚本 v10（增加本地缓存）
#
# 功能说明：
#   此脚本作为 Squid 的 external ACL helper，负责验证用户的 AAD 账号密码。
#   输入格式：stdin 每行 "username password"
#   输出格式：stdout 每行 "OK" 或 "ERR"
#   日志输出：stderr -> squid cache.log（可在 docker logs 中查看）
#
# 认证流程：
#   1. 检查本地缓存（/data/log/auth_cache/{user_md5}）
#      - 缓存命中（< 1小时）-> 直接返回 OK（< 1ms，不调 AAD）
#      - 缓存未命中 -> 调用 AAD ROPC 接口
#   2. 调用 Azure AD ROPC 端点：
#      POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
#   3. 认证成功 -> 写入缓存，返回 OK
#   4. 认证失败 -> 返回 ERR（不写缓存）
#
# 性能优化：
#   - 本地缓存：减少 AAD API 调用 100 倍（1小时内同用户只认证 1 次）
#   - 并发支持：Squid 可启动多个此脚本的副本（children 参数）
#
# 使用方法：
#   此脚本由 Squid 自动调用，无需手动执行。
#   手动测试：
#     echo "user@example.com password" | /tmp/squid_aad_auth.sh
# ============================================================

# ---- 缓存配置 ----
CACHE_DIR="/data/log/auth_cache"     # 缓存目录（由 entrypoint.sh 确保 proxy 用户可写）
CACHE_TTL=3600                      # 缓存有效期（秒，1小时）

# ---- 从环境变量读取 AAD 配置 ----
# 注意：这些环境变量由 docker-compose.yml 从 .env 文件注入
TENANT="${AAD_TENANT_ID:-}"        # Azure AD 租户 ID
CLIENT="${AAD_CLIENT_ID:-}"         # Azure AD 应用 ID
SECRET="${AAD_CLIENT_SECRET:-}"     # Azure AD 应用密钥

# ---- 启动时输出配置状态到 stderr ----
# 此日志会出现在 squid cache.log 中，用于确认脚本已加载
echo "AUTH_HELPER_STARTED v10 tenant=${TENANT:-(empty)} client=${CLIENT:-(empty)} cache_dir=${CACHE_DIR}" >&2

# ---- 初始化缓存目录 ----
mkdir -p "$CACHE_DIR" 2>/dev/null
chmod 755 "$CACHE_DIR" 2>/dev/null

# ---- URL 编码函数（纯 bash 实现，无需外部工具）----
# 注意：此函数当前未使用（因为 --data-urlencode 会自动编码）
# 保留此函数用于未来扩展（如需要手动编码的场景）
encode() {
    local s="$1" o="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) o+="$c" ;;
            *) o+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$o"
}

# ---- 检查缓存 ----
# 参数：$1 = 用户名
# 返回：0 = 缓存命中，1 = 缓存未命中
check_cache() {
    local u="$1"
    local cache_file="${CACHE_DIR}/$(echo -n "$u" | md5sum | cut -d' ' -f1)"
    
    if [ -f "$cache_file" ]; then
        # 计算缓存文件年龄（秒）
        local file_age=$(( $(date +%s) - $(stat -c%Y "$cache_file" 2>/dev/null || echo 0) ))
        if [ "$file_age" -lt "$CACHE_TTL" ]; then
            # 缓存命中，直接返回 OK（不调 AAD）
            echo "CACHE_HIT user=$u age=${file_age}s" >&2
            return 0
        else
            # 缓存过期，删除缓存文件
            rm -f "$cache_file" 2>/dev/null
        fi
    fi
    return 1
}

# ---- 写入缓存 ----
# 参数：$1 = 用户名
write_cache() {
    local u="$1"
    local cache_file="${CACHE_DIR}/$(echo -n "$u" | md5sum | cut -d' ' -f1)"
    touch "$cache_file" 2>/dev/null
}

# ---- 验证单个用户 ----
# 参数：$1 = 用户名，$2 = 密码
# 返回：0 = 认证成功，1 = 认证失败
check() {
    local u="$1" p="$2"

    # 空值快速拒绝（避免无效请求）
    [ -z "$u" ] && return 1
    [ -z "$p" ] && return 1

    # 配置缺失时拒绝（不崩，只拒绝）
    if [ -z "$TENANT" ] || [ -z "$CLIENT" ]; then
        echo "REJECT_CONFIG_EMPTY user=$u" >&2
        return 1
    fi

    # ⚡ 先查缓存（命中则直接返回 OK，不调 AAD）
    if check_cache "$u"; then
        return 0
    fi

    # 🌐 缓存未命中，调用 AAD ROPC
    local resp_file="/tmp/aad_resp_$$.txt"
    local http_code resp_body

    # 调用 Azure AD ROPC 端点
    # 注意：不使用 encode() 函数，让 --data-urlencode 自动处理（避免双重编码）
    http_code=$(curl -s -o "$resp_file" -w '%{http_code}' --max-time 15 \
        --post301 --post302 --post303 \
        -X POST "https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "client_id=${CLIENT}" \
        --data-urlencode "client_secret=${SECRET}" \
        --data-urlencode "grant_type=password" \
        --data-urlencode "scope=https://graph.microsoft.com/.default offline_access" \
        --data-urlencode "username=${u}" \
        --data-urlencode "password=${p}" \
        2>/dev/null)

    # 读取响应体（用于错误诊断）
    if [ -f "$resp_file" ]; then
        resp_body=$(cat "$resp_file" 2>/dev/null)
        rm -f "$resp_file"
    else
        resp_body="(no response body)"
    fi

    # 根据 HTTP 状态码判断认证结果
    case "$http_code" in
        200)
            # 认证成功
            echo "OK user=$u" >&2
            # ✅ 写入缓存（1小时内不再调 AAD）
            write_cache "$u"
            return 0
            ;;
        *)
            # 认证失败（记录详细错误信息，便于排查）
            local aad_error aad_desc
            aad_error=$(echo "$resp_body" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)
            aad_desc=$(echo "$resp_body" | grep -o '"error_description":"[^"]*"' | head -1 | cut -d'"' -f4)
            echo "REJECT user=$u http=${http_code} aad_err=${aad_error:-unknown} aad_desc=${aad_desc:-none}" >&2
            return 1
            ;;
    esac
}

# ============================================================
# 主循环：持续读取 stdin，永不退出（除非管道断开）
# ============================================================
while IFS= read -r line || [ -n "$line" ]; do
    # 解析：第一个空格前是用户名，之后是密码
    user="${line%% *}"
    rest="${line#* }"
    if [ "$rest" = "$line" ]; then
        pass=""
    else
        pass="$rest"
    fi

    # 执行验证并输出结果
    if check "$user" "$pass"; then
        echo "OK"
    else
        echo "ERR"
    fi
done

# stdin 关闭时正常退出（不应到达这里）
exit 0
