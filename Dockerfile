# ============================================================
# Squid + Azure AD ROPC 代理网关 - Dockerfile v23
# 使用预编译的 base 镜像（Squid 已编译好）
# ============================================================

ARG SQUID_VER=7.6
FROM squid-proxy-aad:${SQUID_VER}

LABEL maintainer="Envision Energy"
LABEL description="Squid ${SQUID_VER} + Azure AD ROPC Auth + HTTPS"
LABEL version="${SQUID_VER}"

# ---- 复制配置文件 ----
COPY config/squid.conf /etc/squid/squid.conf
COPY scripts/squid_aad_auth.sh /usr/local/bin/squid_aad_auth.sh
COPY scripts/entrypoint.sh /entrypoint.sh
COPY config/certs/ /etc/squid/certs/

# ---- 去除 Windows \r + 设置权限（关键：证书文件必须 proxy 用户可读）----
RUN sed -i 's/\r$//' \
    /usr/local/bin/squid_aad_auth.sh \
    /entrypoint.sh \
    /etc/squid/squid.conf && \
    chmod +x /usr/local/bin/squid_aad_auth.sh /entrypoint.sh && \
    chown -R proxy:proxy /etc/squid/certs/ && \
    chmod 644 /etc/squid/certs/*.crt /etc/squid/certs/*.key

EXPOSE 3128 3129

ENTRYPOINT ["/entrypoint.sh"]
