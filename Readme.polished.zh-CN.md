## Radius-Ent 部署与运维指南（中文润色版）

> 本文档是对现有 README 的润色与重排版本，原有技术方案不变，仅优化表达、结构与可读性。

## 1. 项目简介

本项目主要用于将 FreeRADIUS 与 Microsoft Entra ID（原 Azure AD）对接，实现基于 802.1X / RADIUS 的企业身份认证，同时提供审计日志导出与可视化能力。

核心组成如下：

1. `freeradius`（基于开源方案二次开发）
2. `audit-exporter`（导出审计日志并通过 API Token 保护访问）
3. `audit-dashboard`（审计日志可视化面板）

当前推荐使用证书模式（`client certificate`），不建议将 `client secret` 作为长期主方案。

## 2. 部署前准备

请先确认以下前置条件：

- 目标主机已安装 `Docker Engine` 与 `Docker Compose`
- 拥有可用的 Microsoft Entra ID 租户
- 已为 FreeRADIUS 单独注册一个 Entra 应用
- 已确定认证账号使用的邮箱后缀（例如 `example.com`）
- 网络设备支持 RADIUS / 802.1X（如交换机、AC、AP 控制器或测试终端）

如果你使用华为 AC（示例：`9700S-S`），建议检查：

- 已启用计费功能
- 计费方案已切换到实时计费
- 认证模板中的 RADIUS 服务器配置路径正确
- 计费间隔与超时重试策略已按测试环境验证

## 3. 关键注意事项

- `REALM_NAME` 必须与用户登录后缀一致（例如 `user@example.com`）
- `Azure_App_Client_ID` 必填，不可删除
- 证书模式必须同时配置：
  - `Azure_App_Client_Key_Path`
  - `Azure_App_Client_Cert_Path`
- 本集成基于 `ROPC` 流程，802.1X 认证链路中无法完成交互式 MFA
- 若租户已启用 MFA 策略，需要通过 条件访问[Conditional Access] 对该 RADIUS 链路做放行设计

## 4. 第 1 步：创建 Entra 应用

本项目支持两种接入模式：

1. `Client_ID + Client_Secret`（传统模式）
2. 证书模式（推荐）

### 4.1 在 Entra 管理中心创建应用

1. 使用管理员账号登录 Microsoft Entra 管理中心
2. 进入 `Azure Active Directory`（Microsoft Entra ID）
3. 打开 `应用注册`，点击 `新注册`
4. 注册建议：
   - 应用名称：`Azure-radius-ent`（可自定义）
   - 支持的账户类型：单租户
   - 重定向 URI：留空
5. 记录 `Client ID`

### 4.2 选择认证材料：客户端密钥或证书

- 如果使用客户端密钥，进入 `客户端凭据`，新增 `客户端密码`
- 如果使用证书模式，跳转到下一节生成并上传证书

客户端密钥模式注意：

- 记录生成后显示的 `Value`（仅首次可见）
- 设置合理到期周期，避免过期影响认证

### 4.3 证书模式（推荐）

在 Linux 环境执行：

```bash
openssl genrsa -out azure_app_radius_key.pem 2048
openssl req -new -x509 \
  -key azure_app_radius_key.pem \
  -out azure_app_radius_cert.pem \
  -days 3650 \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=company/CN=Azure App Radius"
```

然后在 Entra 应用中上传 `azure_app_radius_cert.pem`（公钥证书）。

注意：

- `azure_app_radius_key.pem` 私钥仅保留在 RADIUS 主机
- 严禁上传私钥

### 4.4 配置 API 权限

1. 进入应用的 `API permissions`
2. 添加 `Microsoft Graph` 的 应用程序权限[Application permissions]
3. 添加权限：`Directory.Read.All`
4. 确认 `User.Read` 存在（通常为委派权限）
5. 由管理员执行 授予管理员同意[Grant admin consent]

## 5. 第 2 步：为 RADIUS 认证链路放行 MFA

### 5.1 先决条件检查

请确认：

1. 租户具备 `Azure AD P1/P2` 或 `Microsoft 365 Business Premium`
2. 使用的是 条件访问[Conditional Access]（而非仅 `Security defaults`）
3. 已准备专用测试用户

### 5.2 关闭 Security defaults（如已开启）

若 `Security defaults` 开启，会对 MFA 做租户级统一控制，不适合“仅对特定链路放行”的场景。

操作路径：

1. `Microsoft Entra admin center`
2. `AzureAD -> Overview -> Properties`
3. `Manage security defaults`
4. 将 `Enabled` 改为 `Disabled`
5. 保存

### 5.3 创建放行组（推荐）

建议使用组管理，不要直接排除大量单用户。

1. `AzureAD -> Groups -> All groups`
2. 点击 `New group`
3. `Group type`: `Security`
4. `Membership type`: `Assigned`
5. 组名示例：`RADIUS-ROPC-MFA-EXEMPT`
6. 先加入 1 个测试用户并保存

### 5.4 创建 条件访问[Conditional Access] 策略

策略示例名称：`Require MFA - All users except RADIUS ROPC`

建议配置：

1. 用户范围：`Include = All users`（包括[Include] 所有用户[All users]）
2. 排除范围：`Exclude = Users and groups`（排除[Exclude] 用户和组[Users and groups]，选择放行组）
3. 目标资源：包含所有资源，并将 RADIUS 相关应用按设计加入排除
4. 授权[Access controls]：
   - 选择 授予访问权限[Grant access]
   - 勾选 需要多重身份验证[Require multifactor authentication]
5. 多项控制关系选择 需要某一已选控件[Require one of the selected controls]

上线建议：

- 先灰度到小范围用户
- 至少排除 1 个管理员账户，避免误锁管理入口

## 6. 第 3 步：启动服务

### 6.1 准备 FreeRADIUS 证书与 `AUDIT_API_TOKEN`

#### 6.1.1 生成 FreeRADIUS EAP-TTLS 服务端证书

```bash
mkdir ssl/
openssl genrsa -out radius.key 2048
openssl req -new -key radius.key -out radius.csr
openssl genrsa -out radius_ca.key 2048
openssl req -new -x509 -key radius_ca.key -out radius_ca.pem -days 3650 -sha256
openssl x509 -req -in radius.csr -CA radius_ca.pem -CAkey radius_ca.key -CAcreateserial -out radius.crt -days 3650 -sha256
openssl verify -CAfile radius_ca.pem radius.crt
```

#### 6.1.2 复制 Entra 应用证书文件

```bash
cp azure_app_radius_key.pem ssl/
cp azure_app_radius_cert.pem ssl/
```

#### 6.1.3 设置证书权限

```bash
chmod 644 ssl/*
chmod 600 ssl/*_key.pem
chmod 600 ssl/*.key
```

#### 6.1.4 检查证书文件

```bash
ls -l ssl/
```

预期至少包含：

- `azure_app_radius_key.pem`
- `azure_app_radius_cert.pem`
- `radius.key`
- `radius.crt`
- `radius_ca.pem`

#### 6.1.5 生成审计 API Token

```bash
openssl rand -hex 24
```

请将输出值写入 `AUDIT_API_TOKEN`，生产环境务必使用高强度随机值。

### 6.2 启动 `freeradius` 与 `audit-exporter`

#### 6.2.1 修改 `clients.conf`

```bash
cd freeeradius
mkdir logs
vim clients.conf
```

根据设备实际情况补充：

- AC / NAS 客户端地址
- 对应共享密钥
- 本地测试客户端 IP

#### 6.2.2 修改 `docker-compose.yml`

重点变量：

- `REALM_NAME`
- `Azure_App_Client_ID`
- `Azure_App_Client_Key_Path`
- `Azure_App_Client_Cert_Path`
- `Azure_App_Client_Secret`（仅 secret 模式需要）
- `AUDIT_API_TOKEN`

示例：

```yaml
environment:
  - REALM_NAME=example.com
  - Azure_App_Client_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  - Azure_App_Client_Key_Path=/etc/freeradius/ssl/azure_app_radius_key.pem
  - Azure_App_Client_Cert_Path=/etc/freeradius/ssl/azure_app_radius_cert.pem
```

#### 6.2.3 启动容器

```bash
docker-compose up -d
```

### 6.3 功能验证

#### 6.3.1 验证放行策略是否生效

建议顺序：

1. 先放行 1 个测试用户
2. 确认用户已加入 `RADIUS-ROPC-MFA-EXEMPT`
3. 确认 `Security defaults` 已关闭
4. 确认无其他策略强制 MFA
5. 执行一次 RADIUS 认证
6. 验证成功后再逐步扩大范围

#### 6.3.2 在 RADIUS 服务器本地测试

```bash
sudo apt update
sudo apt -y install freeradius-utils
radtest user@example.com user_password 127.0.0.1 1812 testing123
```

#### 6.3.3 在外部测试机验证

```bash
sudo apt update
sudo apt -y install freeradius-utils
radtest user@example.com user_password <freeradius-server-ip> 1812 testing123
```

## 7. 第 4 步：验证审计接口

`audit-exporter` 会读取共享目录 `logs/` 中的 `/var/log/freeradius/audit_stream.jsonl`。

测试接口：

```bash
curl -i -H "Authorization: Bearer <AUDIT_API_TOKEN>" "http://localhost:9090/api/logs"
```

## 8. 第 5 步：启动审计面板

```bash
cd audit-dashboard
docker-compose up -d
```

## 9. 常见问题（FAQ）

### 9.1 `missing client_id, or both client_secret and client_key_path are missing/invalid`

常见原因：

- `REALM_NAME` 与登录后缀不一致
- `Azure_App_Client_ID` 为空或错误
- `Azure_App_Client_Key_Path` 挂载异常
- `Azure_App_Client_Cert_Path` 挂载异常

### 9.2 `BlastRADIUS` 或 `require_message_authenticator` 告警

请检查并更新 [dockerfile/clients.conf](dockerfile/clients.conf)，确保客户端条目采用现代安全配置。

### 9.3 用户名密码正确但仍因 MFA 失败

通常说明仍有 MFA 策略命中用户、用户组或租户范围。请重新核对 条件访问[Conditional Access] 放行设计，确认 802.1X / FreeRADIUS 认证链路已被正确排除。

### 9.4 共享密钥过短告警

如 `testing123` 仅适用于实验环境，生产环境请替换为高强度随机字符串。

### 9.5 OAuth2 调试日志过多

若 [freeradius-oauth2-perl-cert/module](freeradius-oauth2-perl-cert/module) 中仍为 `debug = yes`，建议在排障完成后改为 `debug = no`，避免日志暴露敏感请求信息。
