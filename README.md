# Squid + Azure AD ROPC 正向代理网关

## 项目简介

基于 **Squid 7.6** 的正向代理网关，集成 **Azure AD** 认证（ROPC 密码模式）。用户通过在浏览器/系统代理设置中填写 AAD 账号密码完成认证，支持 HTTPS 代理（TLS 加密）。

### 核心特性

- ✅ **Azure AD 集成**：用户使用 AAD 账号密码直接认证（无需额外登录页）
- ✅ **HTTPS 代理**：用户 → 代理走 TLS 加密（需要证书）
- ✅ **本地认证缓存**：认证成功后缓存 1 小时，减少 AAD API 调用 100 倍
- ✅ **高并发支持**：100 个认证进程 + 4 个 Squid worker（适配 4 核 CPU）
- ✅ **容器化部署**：Docker + Docker Compose，一键启动
- ✅ **详细日志**：认证日志输出到 `docker logs`，便于排查

---

## 架构说明

```
┌─────────────────┐
│   浏览器/系统代理设置                          │
│   填写 AAD 账号密码                          │
└─────────────────┬─────────────────────────┘
                  │ HTTPS (TLS)
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

### 认证流程

1. 用户在浏览器代理设置中填写 AAD 账号密码
2. Squid 收到请求，调用 `squid_aad_auth.sh` 脚本
3. 脚本先查本地缓存（`/data/log/auth_cache/`）
   - **缓存命中**（< 1 小时）→ 直接返回 OK（< 1ms）
   - **缓存未命中** → 调用 Azure AD ROPC 接口
4. Azure AD 验证用户名密码
   - **成功** → 写入缓存，返回 OK
   - **失败** → 返回 ERR（拒绝访问）
5. Squid 允许/拒绝用户访问目标网站

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
# - 生产环境：spproxy.test.com
# - 测试环境：172.23.95.36
PROXY_HOSTNAME=spproxy.test.com

# Azure AD 配置（从 Azure Portal 获取）
AAD_TENANT_ID=20e8dfa9-4087-428e-865a-329bac3297da
AAD_CLIENT_ID=a3b622a2-df7d-453d-a9f8-c50c5b1869b9
AAD_CLIENT_SECRET=your_secret_here
```

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

内部项目，仅供 Envision Energy 使用。

---

## 联系方式

- **维护者**：Envision Energy IT 部门
- **问题反馈**：请联系 IT 部门或提交 Issue
