## 本项目介绍
- 1.本项目基于Freeradius和freeradius-oauth2-perl（二开版本），支持了Freeradius通过证书对接AzureAD（现为EntraID）
- 2.本项目集成了一个audit-exporter 用来传出相关审计日志，接收端通过apitoken校验配置后端连接。

当前推荐的部署方式是证书模式，即 FreeRADIUS 使用 Entra ID 应用证书与 Azure 通信。

## 部署前准备

请先确认以下条件：

- 目标主机已安装 Docker Engine 和 Docker Compose
- 一个可用的 Microsoft Entra ID 租户
- FreeRADIUS 需要单独作为一个 Entra ID 应用注册
- 已经明确用户认证时使用的邮箱域名后缀，例如 `example.com`
- 已有 支持配置RADIUS或者802.1X协议的 网络设备，例如交换机、AC、AP 控制器或测试终端
- AC配置: 本项目以华为9700S-S举例:
   - huawei ac 中需要开启 计费功能
   - 计费方案需要开启 实时计费：
      - 路径: AP组配置-wlan-access-VAP配置-wlan名称-认证模板-RADIUS服务器配置
      - 按时长计费切换为实时计费:
      - 计费时间间隔15min，请求无响应最大次数3
      - 实时计费失败后策略&开始计费失败策略：测试阶段允许用户上线，测试没问题了，灰度开始选择拒绝用户上线。

注意事项：

- `REALM_NAME` 必须和用户认证时的后缀一致，例如 `user@example.com`
- `Azure_App_Client_ID` 必须保留，不能删除
- 证书模式下必须同时提供 `Azure_App_Client_Key_Path` 和 `Azure_App_Client_Cert_Path`
- 该集成依赖 ROPC 流程，因此 802.1X 认证过程中无法完成交互式 MFA
- 如果你的租户或用户被 MFA 策略保护，必须为这条 RADIUS 登录链路配置 Conditional Access 放行策略

## 第 1 步：创建 Entra ID 应用

在 Entra 管理中心执行以下操作：

1. 进入 `Entra ID` -> `App registrations` -> `New registration`
2. 创建单租户应用
3. 记录应用的 `Client ID`
4. 进入 `API permissions`
5. 添加 `Microsoft Graph` -> `Application permissions` -> `Directory.Read.All`
6. 检查User.Read 权限
7. 执行管理员同意

本仓库当前推荐使用证书模式，不建议再把 `client secret` 作为主要接入方式。 client secret 最长2年一轮换，安全性不错但2年维护一次容易影响服务。

## 第 2 步：为 RADIUS 登录链路放行 MFA

### 2.1 前置检查

在开始之前，请先确认以下几点：

1. 你的租户具备 `Microsoft Entra ID P1`、`P2` 或 `Microsoft 365 Business Premium`
2. 你使用的是 `Conditional Access`，而不是只依赖 `Security defaults`
3. 你准备了一个专门用于 802.1X / FreeRADIUS 的测试用户

如果你没有 `P1/P2` 或 Business Premium，通常无法用 Conditional Access 做这种精细放行。

### 2.2 检查并关闭 Security defaults

如果租户启用了 `Security defaults`，它会对 MFA 做租户级的统一控制，不适合这种“只对部分用户放行”的场景。此时应先关闭，再改用 Conditional Access。

Azure 门户路径：

1. 进入 `Microsoft Entra admin center`
2. 打开 `Entra ID` -> `Overview` -> `Properties`
3. 选择 `Manage security defaults`
4. 如果当前是 `Enabled`，改成 `Disabled`
5. 保存

### 2.3 创建一个专门的 MFA 放行组 or 复用现在的包含所有成员的组 比如 all hands（配置动态成员规则，只允许user.accountEnabled -eq true 以及排除掉组邮箱）

建议不要直接排除大量单个用户，而是创建一个专门的安全组，后续只把需要通过 FreeRADIUS 认证的用户加入进去。

推荐组名：

- `RADIUS-ROPC-MFA-EXEMPT`

Azure 门户路径：

1. 进入 `Entra ID` -> `Groups` -> `All groups`
2. 点击 `New group`
3. `Group type` 选择 `Security`
4. `Membership type` 选择 `Assigned`
5. 输入组名，例如 `RADIUS-ROPC-MFA-EXEMPT`
6. 先只加入 1 个测试用户
7. 保存创建


### 2.5 创建 MFA 策略

如果当前租户还没有正式的 MFA Policy 策略，可以新建一条。

推荐策略设计：

- 策略名：`Require MFA - All users except RADIUS ROPC`
- 适用用户：`All users`
- 排除对象：`RADIUS-ROPC-MFA-EXEMPT` 和 break-glass 管理员账户
- 目标资源：`All resources`
- 授权要求：`Require multifactor authentication`

Azure 门户路径：

1. 进入 `Entra ID` -> `Microsoft Azure Policy Insights | 条件访问` -> `Policies`
2. 点击 `New policy`
3. 填写策略名，例如 `Require MFA - All users except RADIUS ROPC`
4. 在 `用户或智能体(预览版)` 中：
   - `Include` 选择 `All users`
   - `Exclude` 选择 `Users and groups`
5. 在 `目标资源` 中:
   - 包括所有资源 
   - `Exclude` 中选择 `RADIUS-ROPC-MFA-EXEMPT`
6. 在 `Access controls` -> `Grant` 中：
   - 选择 `Grant access授予访问权限`
   - 勾选 `Require multifactor authentication需要多重身份验证`
7. `对于多个控件` 选择 `需要某一已选控件`
8. 创建策略

### 2.6 验证放行是否生效

建议按下面顺序做验证：

1. 先只放行 1 个测试用户
2. 确认该用户已经加入 `RADIUS-ROPC-MFA-EXEMPT`
3. 确认 `Security defaults` 已关闭
4. 确认没有其他策略仍在对该用户强制 MFA
5. 用该测试用户做一次 RADIUS 认证
6. 验证通过后，再把更多用户加入这个组

你可以在服务器上执行：

```bash
radtest user@example.com user_password 127.0.0.1 0 testing123
```

如果用户名密码正确，但仍被拒绝，通常需要回头检查：

- 用户是否真的在 `RADIUS-ROPC-MFA-EXEMPT` 组里
- 是否还有其他 MFA 策略命中该用户
- `Security defaults` 是否还处于开启状态
- 用户是否属于联邦/混合身份场景，因为部分 federation 场景下 ROPC 本身就不支持

运维建议：

- 建议把 Wi-Fi 或有线 802.1X 用户放入专门的 Entra ID 组，再通过这个组管理 MFA 放行
- 放行范围应尽可能小，并在文档中注明原因和适用对象

## 第 3 步：生成并上传 Entra ID 应用证书

在本地生成应用私钥和证书：

```bash
openssl genrsa -out azure_app_radius_key.pem 2048
openssl req -new -x509 \
  -key azure_app_radius_key.pem \
  -out azure_app_radius_cert.pem \
  -days 3650 \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=company/CN=Azure App Radius"
```

然后将 `azure_app_radius_cert.pem` 上传到 Entra ID 应用：

`Certificates & secrets` -> `Certificates` -> `Upload certificate`

说明：

- 上传到 Entra ID 的是公钥证书
- `azure_app_radius_key.pem` 私钥只保留在 RADIUS 主机
- 不要上传私钥

## 第 4 步：生成 FreeRADIUS 服务端证书

该证书用于 FreeRADIUS 自身的 EAP-TTLS 服务端认证。

```bash
openssl genrsa -out radius.key 2048
openssl req -new -key radius.key -out radius.csr
openssl genrsa -out radius_ca.key 2048
openssl req -new -x509 -key radius_ca.key -out radius_ca.pem -days 3650 -sha256
openssl x509 -req -in radius.csr -CA radius_ca.pem -CAkey radius_ca.key -CAcreateserial -out radius.crt -days 3650 -sha256
openssl verify -CAfile radius_ca.pem radius.crt
```

生产环境建议使用规范的服务端证书名称，并确保客户端正确校验证书链和服务端名称。

## 第 5 步：准备本地目录和文件

在仓库根目录执行：

```bash
mkdir ssl
mkdir logs
```

将以下文件放到 `ssl/` 目录：

- `azure_app_radius_key.pem`
- `azure_app_radius_cert.pem`
- `radius.key`
- `radius.crt`
- `radius_ca.pem`

Linux 下建议权限如下：

```bash
chmod 644 ssl/*
chmod 600 ssl/*_key.pem
chmod 600 ssl/*.key
```

## 第 6 步：更新 RADIUS 客户端配置

当前 Compose 会将 [dockerfile/clients.conf](dockerfile/clients.conf) 挂载进容器。

你需要根据现场环境修改这个文件：

- 增加或修改 NAS、AC、AP 控制器的 IP 地址
- 将测试用短密码替换为强随机共享密钥
- 保留 `localhost` 相关条目，这样内置健康检查和本地 `radtest` 才能正常工作

## 第 7 步：更新 docker-compose.yml

编辑 [docker-compose.yml](docker-compose.yml)，至少设置以下变量：

```yaml
environment:
  - REALM_NAME=example.com
  - Azure_App_Client_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  - Azure_App_Client_Key_Path=/etc/freeradius/ssl/azure_app_radius_key.pem
  - Azure_App_Client_Cert_Path=/etc/freeradius/ssl/azure_app_radius_cert.pem
```

说明：

- `REALM_NAME` 必须保留
- `Azure_App_Client_ID` 必须保留
- 证书模式下必须保留 `Azure_App_Client_Key_Path` 和 `Azure_App_Client_Cert_Path`
- `Azure_App_Client_Secret` 只有在你明确使用 secret 模式时才需要保留
- `AUDIT_API_TOKEN` 请在生产环境中替换为你自己的随机值

生成随机 `AUDIT_API_TOKEN` 的命令：

```bash
openssl rand -hex 24
```

如果你没有修改 `ssl/` 下文件名，通常不需要调整挂载路径。

## 第 8 步：启动服务

在仓库根目录执行：

```bash
docker compose up -d --build
```
本地编译镜像并且push到docker hub
```
cd dockerfile 
docker build -f dockerfile/Dockerfile-v5-audit -t radius-ent:azure-v5.0  .
```

查看容器状态：

```bash
docker compose ps
```

查看 FreeRADIUS 日志：

```bash
docker logs -f radius-azure-v5
```

## 第 9 步：验证认证流程

如未安装测试工具，可先安装：

```bash
sudo apt install freeradius-utils
```

然后执行基础测试：

```bash
radtest user@example.com user_password 127.0.0.1 0 testing123
```

注意：

- 服务刚启动后的第一次认证可能比较慢，因为模块会先同步 Entra ID 用户和组信息
- 如果第一次超时，可以再重试一到两次，不要立即判定为配置错误

## 第 10 步：验证审计接口

`audit-exporter` 会读取共享目录 `logs/` 中的 `/var/log/freeradius/audit_stream.jsonl`。

你可以这样测试审计 API：

```bash
curl -i -H "Authorization: Bearer <AUDIT_API_TOKEN>" "http://localhost:9090/api/logs"
```

如果你同时部署了 dashboard，可以继续参考 [audit-readme.md](audit-readme.md)。


## 第 11 步: 审计面板image构建
```
docker build -f audit-dashboard/Dockerfile -t radius-ent:audit-dashboard-v5.0  .
```


## 常见问题

### `missing client_id, or both client_secret and client_key_path are missing/invalid`

通常是以下原因之一：

- `REALM_NAME` 和用户后缀不一致
- `Azure_App_Client_ID` 为空或填写错误
- `Azure_App_Client_Key_Path` 指向的私钥文件没有正确挂载
- `Azure_App_Client_Cert_Path` 指向的证书文件没有正确挂载

### `BlastRADIUS` 或 `require_message_authenticator` 相关告警

请检查并更新 [dockerfile/clients.conf](dockerfile/clients.conf)，确保客户端条目使用现代安全配置。

### 用户名密码正确但仍因 MFA 失败

这通常说明用户、用户组或租户范围内仍有 MFA 策略生效。请重新检查 Conditional Access 的放行设计，确认 802.1X / FreeRADIUS 这条认证链路已经真正被排除在 MFA 强制范围之外。

### 共享密钥过短告警

例如 `testing123` 这类测试值只适合实验环境，生产环境请更换为强随机字符串。

### OAuth2 调试日志过多

[freeradius-oauth2-perl-cert/module](freeradius-oauth2-perl-cert/module) 当前仍是 `debug = yes`，排障完成后建议改成 `debug = no`，避免日志中出现敏感请求信息。

## 相关文件

- OAuth2 模块说明：[freeradius-oauth2-perl-cert/README.md](freeradius-oauth2-perl-cert/README.md)
- 旧版项目说明：[readme-old.md](readme-old.md)
- 审计说明：[audit-readme.md](audit-readme.md)
