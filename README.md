# Squid + Azure AD ROPC + MFA 正向代理网关

## 项目简介

基于 **Squid 7.6** 的正向代理网关，集成 **Azure AD** 认证，支持两种认证模式：

1. **ROPC 模式**（Resource Owner Password Credentials）：适合脚本、非浏览器应用
2. **MFA 模式**（Authorization Code Flow + MFA）：适合浏览器用户，支持 Azure AD MFA 验证

### 核心特性

- ✅ **双模式认证**：ROPC（3128 端口）+ MFA（3129 端口）
- ✅ **Azure AD MFA 支持**：用户通过浏览器登录，支持多因素认证
- ✅ **HTTPS 代理**：用户 → 代理走 TLS 加密（需要证书）
- ✅ **本地认证缓存**：认证成功后缓存 1 小时，减少 AAD API 调用 100 倍
- ✅ **高并发支持**：100 个认证进程 + 4 个 Squid worker（适配 4 核 CPU）
- ✅ **容器化部署**：Docker + Docker Compose，一键启动
- ✅ **详细日志**：认证日志输出到 `docker logs`，便于排查

---

## 架构说明

### 模式 1：ROPC 认证（3128 端口）

```
┌─────────────────┐
│   浏览器/系统代理设置                          │
│   填写 AAD 账号密码（Basic Auth）             │
└─────────────────┬─────────────────────────┘
                  │ HTTPS (TLS) - 端口 3128
                  ▼
┌─────────────────┐
│   Squid 7.6 (Docker 容器)                │
│   - 监听 3128 端口 (HTTPS)              │
│   - 调用 AAD ROPC 验证账号密码           │
│   - 认证成功 → 允许访问目标网站          │
└─────────────────┬─────────────────────────┘
                  │
                  ▼
┌─────────────────┐
│   Azure AD (Microsoft Entra ID)            │
│   - 验证用户名密码                        │
│   - 返回 access_token (成功)             │
└─────────────────┘
```

**使用场景**：自动化脚本、curl 请求、非浏览器应用

---

### 模式 2：MFA 认证（3129 端口）

```
┌─────────────────┐
│   浏览器用户                                  │
│   访问 http://<proxy>:3129/login            │
└─────────────────┬─────────────────────────┘
                  │
                  ▼
┌─────────────────┐
│   OAuth2 Proxy (Docker 容器)               │
│   - 重定向到 Azure AD 登录页面             │
│   - 用户输入账号密码 + MFA 验证            │
│   - 登录成功 → 设置 Cookie                │
└─────────────────┬─────────────────────────┘
                  │
                  ▼
┌─────────────────┐
│   Squid 7.6 (Docker 容器)                │
│   - 监听 3129 端口 (HTTPS)              │
│   - 验证 OAuth2 Proxy Cookie            │
│   - Cookie 有效 → 允许访问目标网站       │
└─────────────────┘
```

**使用场景**：浏览器访问、需要 MFA 验证的场景

---

## 认证模式对比

| 特性 | ROPC 模式（3128） | MFA 模式（3129） |
|------|-------------------|------------------|
| 认证方式 | Basic Auth（用户名/密码） | OAuth2 Cookie（浏览器登录） |
| MFA 支持 | ❌ 不支持 | ✅ 支持 |
| 使用场景 | 脚本、curl、非浏览器应用 | 浏览器用户 |
| 安全性 | 中（密码传输） | 高（Cookie + MFA） |
| 用户体验 | 需要配置代理用户名密码 | 浏览器登录（友好） |
| Azure AD 应用配置 | 需要 ROPC 权限 | 需要 Redirect URI |

---

## 环境要求

- **宿主机**：4 核 16GB 内存（推荐）
- **操作系统**：Linux（Ubuntu 20.04+）或 Windows（Docker Desktop）
- **Docker**：20.10+
- **Docker Compose**：v2.0+
- **证书**：`*.test.com` 通配符证书（TLS 加密用）
- **Azure AD 配置**：
  - 租户 ID（Tenant ID）
  - 应用 ID（Client ID）
  - 应用密钥（Client Secret）
  - 已开启 ROPC 流程（需要管理员权限）

---

## 快速开始

### 1. 克隆/下载项目

```bash
git clone <repository-url>
cd squid-proxy
```

### 2. 配置环境变量

复制 `.env.example` 为 `.env`，填入真实的 AAD 配置：

```bash
cp .env.example .env
vim .env
```

**.env 配置说明**：

```bash
# 代理服务器主机名（域名或 IP）
# - 生产环境：proxy.test.com
# - 测试环境：172.23.95.36
PROXY_HOSTNAME=proxy.test.com

# Azure AD 配置（从 Azure Portal 获取）
# 用于 ROPC 认证（3128 端口）和 MFA 认证（3129 端口）
AAD_TENANT_ID=your-tenant-id-here
AAD_CLIENT_ID=your-client-id-here
AAD_CLIENT_SECRET=your-client-secret-here

# OAuth2 Proxy Cookie 加密密钥（必须 43+ 字符）
# 生成方式：python3 -c "import secrets; print(secrets.token_urlsafe(43))"
OAUTH2_PROXY_COOKIE_SECRET=your-cookie-secret-here-minimum-43-characters-long
```

**注意**：
- `OAUTH2_PROXY_COOKIE_SECRET` 必须 ≥ 43 个字符
- 不要使用特殊字符（如 `@`, `#`, `$` 等），可能导致配置错误

### 3. 放置证书

将证书文件放到 `config/certs/` 目录：

```bash
config/certs/
├── STAR_test_com.crt    # 证书（包含完整证书链）
└── STAR_test_com.key    # 私钥
```

**注意**：证书已打包进 Docker 镜像，无需单独挂载。

### 4. 构建并启动

```bash
# 首次部署：构建基础镜像（编译 Squid 7.6，需要 5-10 分钟）
docker build -f Dockerfile.build --build-arg SQUID_VER=7.6 -t squid-proxy-aad:7.6 .

# 启动服务
docker compose up -d --build

# 查看日志
docker logs -f squid-proxy-aad
```

---

## 配置说明

### Squid 配置（`config/squid.conf`）

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `workers` | Squid worker 进程数（利用多核） | `4` |
| `auth_param basic children` | 认证进程数（支持高并发） | `100` |
| `auth_param basic credentialsttl` | 认证缓存时间（Squid 侧） | `1 hour` |
| `https_port` | HTTPS 代理端口（需要证书） | `3128` |
| `dns_nameservers` | DNS 服务器（内部 DNS） | `10.93.64.117 10.93.64.118` |
| `cache_mem` | 内存缓存大小 | `512 MB` |

**修改配置后重启**：

```bash
docker compose restart squid
```

### 认证脚本（`scripts/squid_aad_auth.sh`）

| 配置 | 说明 | 默认值 |
|--------|------|--------|
| `CACHE_DIR` | 本地认证缓存目录 | `/data/log/auth_cache` |
| `CACHE_TTL` | 缓存有效期（秒） | `3600`（1 小时） |

**缓存机制**：
- 认证成功后，在 `CACHE_DIR` 创建空文件（文件名 = 用户名 MD5）
- 下次认证时，检查文件修改时间
  - **< 1 小时** → 直接返回 OK（不调 AAD）
  - **≥ 1 小时** → 删除缓存文件，调用 AAD

### OAuth2 Proxy 配置（`config/oauth2-proxy.cfg`）

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `provider` | OAuth2 提供程序 | `azure` |
| `azure_tenant_id` | Azure AD 租户 ID | 从环境变量读取 |
| `client_id` | Azure AD 应用 ID | 从环境变量读取 |
| `client_secret` | Azure AD 应用密钥 | 从环境变量读取 |
| `cookie_secret` | Cookie 加密密钥 | 从环境变量读取 |
| `redirect_url` | 回调 URL | `https://<proxy>:3129/oauth2/callback` |
| `cookie_expire` | Cookie 有效期 | `24h` |

**修改配置后重启**：

```bash
docker compose restart oauth2-proxy
```

---

## MFA 认证使用说明

### 1. 登录（获取 Cookie）

用户需要先登录，获取 OAuth2 Proxy Cookie：

1. 在浏览器中访问：
   ```
   https://<proxy-hostname>:3129/login
   ```

2. 点击"登录"按钮，跳转到 Azure AD 登录页面

3. 输入账号密码，完成 MFA 验证（如果需要）

4. 登录成功后，OAuth2 Proxy 设置 Cookie（`_oauth2_proxy`）

5. 用户访问任何网站，Squid 验证 Cookie → 允许访问

### 2. 配置浏览器使用 MFA 认证（3129 端口）

**注意**：MFA 认证需要浏览器支持 Cookie，不能通过 Basic Auth 配置。

**推荐方案**：使用浏览器扩展（如 SwitchyOmega）配置代理：

1. 安装 SwitchyOmega 扩展
2. 添加代理服务器：
   - 协议：HTTPS
   - 服务器：`<proxy-hostname>`
   - 端口：`3129`
3. 启用代理，访问任何网站
4. 首次访问会提示登录（重定向到登录页面）
5. 登录成功后，自动访问目标网站

### 3. 登出

用户可以通过以下 URL 登出：

```
https://<proxy-hostname>:3129/oauth2/sign_out
```

登出后，Cookie 被删除，需要重新登录。

---

## 常用命令

### 服务管理

```bash
# 启动服务
docker compose up -d

# 停止服务
docker compose down

# 重启服务
docker compose restart squid

# 查看日志
docker logs -f squid-proxy-aad

# 查看认证日志（Squid cache.log）
docker exec squid-proxy-aad tail -f /data/log/cache.log | grep -E "OK user|REJECT|CACHE_HIT"
```

### 测试代理

```bash
# 测试 HTTP 目标网站
curl -x https://spproxy.test.com:3128 \
     -U "user@example.com:${PASSWORD}" \
     http://www.baidu.com -o /dev/null -s -w "%{http_code}\n"

# 测试 HTTPS 目标网站
curl --insecure -x https://spproxy.test.com:3128 \
     -U "user@example.com:${PASSWORD}" \
     https://www.baidu.com -o /dev/null -s -w "%{http_code}\n"
```

### 压力测试（PowerShell）

```powershell
# 保存为 stress_test.ps1
.\stress_test.ps1 -TotalRequests 1000 -Concurrency 100
```

---

## 升级 Squid 版本

```bash
# 1. 下载新版源码（从 https://github.com/squid-cache/squid/releases）
#    文件名格式：squid-<VERSION>.tar.xz
#    例如：squid-7.7.tar.xz

# 2. 放到项目目录

# 3. 重新构建基础镜像
docker build -f Dockerfile.build --build-arg SQUID_VER=7.7 -t squid-proxy-aad:7.7 .

# 4. 修改 docker-compose.yml 中的 SQUID_VER
#    args:
#      SQUID_VER: "7.7"
#    image: squid-proxy-aad:7.7

# 5. 重启服务
docker compose up -d --build
```

---

## 注意事项

### 1. Azure AD ROPC 限制

- **ROPC 需要管理员开启**：在 Azure Portal → 应用注册 → 身份验证 → 勾选"允许公共客户端流"
- **不支持 MFA**：ROPC 流程不支持多因素认证（如果需要 MFA，需改用授权码流程）
- **不支持联合认证**：如果用户账号配置了联合认证（如 ADFS），ROPC 可能失败

### 2. 安全建议

- ✅ **使用 HTTPS 代理**：用户 → 代理走 TLS 加密，密码不会明文传输
- ✅ **限制来源 IP**：修改 `squid.conf` 中的 `acl localnet src`，只允许内网 IP
- ✅ **定期轮换 AAD 密钥**：在 Azure Portal 中重新生成 Client Secret
- ⚠️ **不要在日志中记录密码**：当前脚本不记录密码（只记录用户名）

### 3. 性能优化

- **认证 QPS**：单次 AAD 认证 ~1.15 秒，100 个认证进程 ≈ 87 QPS
- **本地缓存**：开启后，1 小时内同用户只认证 1 次，QPS 提升到 ~400+
- **DNS 优化**：如果内部 DNS 无法解析公网域名，改为公网 DNS（`8.8.8.8 114.114.114.114`）

### 4. 故障排查

**认证失败**：

```bash
# 查看认证日志
docker logs squid-proxy-aad 2>&1 | grep -E "REJECT|AUTH_HELPER"

# 手动测试 AAD ROPC
curl -s -X POST "https://login.microsoftonline.com/${AAD_TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${AAD_CLIENT_ID}" \
  --data-urlencode "client_secret=${AAD_CLIENT_SECRET}" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "scope=User.Read offline_access" \
  --data-urlencode "username=user@example.com" \
  --data-urlencode "password=${PASSWORD}"
```

**TLS 握手失败**：

```bash
# 检查证书和私钥是否匹配
openssl x509 -noout -modulus -in config/certs/STAR_test_com.crt | md5sum
openssl rsa -noout -modulus -in config/certs/STAR_test_com.key | md5sum
# 两个 MD5 必须一致
```

---

## 项目结构

```
squid-proxy/
├── config/                          # 配置文件
│   ├── squid.conf                   # Squid 主配置（已优化，含详细注释）
│   └── certs/                     # TLS 证书
│       ├── STAR_test_com.crt
│       └── STAR_test_com.key
├── scripts/                        # 脚本文件
│   ├── entrypoint.sh              # 容器启动脚本（初始化 + 配置生成）
│   └── squid_aad_auth.sh         # AAD 认证脚本（ROPC + 本地缓存）
├── docker-compose.yml              # Docker Compose 配置
├── Dockerfile                      # 应用镜像（秒级 rebuild）
├── Dockerfile.build               # 基础镜像（编译 Squid，只构建一次）
├── .env.example                  # 环境变量模板
├── stress_test.ps1               # Windows 压力测试脚本（PowerShell）
└── README.md                     # 项目文档（本文件）
```

---

## 版本历史

### v1.0.0 (2026-06-30)

**新增**：
- ✅ Squid 7.6 源码编译（支持 OpenSSL）
- ✅ Azure AD ROPC 认证集成
- ✅ HTTPS 代理支持（TLS 加密）
- ✅ 本地认证缓存（减少 AAD 调用 100 倍）
- ✅ 高并发支持（100 认证进程 + 4 worker）
- ✅ 详细中文注释（所有配置文件和脚本）
- ✅ 压力测试脚本（PowerShell）

**修复**：
- ✅ 修复 Windows `\r\n` 换行符问题
- ✅ 修复 URL 双重编码 bug
- ✅ 修复证书和私钥权限问题
- ✅ 修复 `dns_nameservers` 拼写错误

---

## 许可证

内部项目，仅供使用。

---

## 联系方式

- **维护者**： 部门
- **问题反馈**：请联系 IT 部门或提交 Issue
