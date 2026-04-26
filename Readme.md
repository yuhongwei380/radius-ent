## 本项目介绍
1. 本项目基于Freeradius和freeradius-oauth2-perl（二开版本），支持了Freeradius通过证书对接AzureAD（现为EntraID）
2. 本项目集成了一个audit-exporter 用来传出相关审计日志，接收端通过apitoken校验配置后端连接。

当前推荐的部署方式是证书模式，即 FreeRADIUS 使用 AzureAD 应用证书与 Azure 通信。

## 部署前准备

请先确认以下条件：

- 目标主机已安装 Docker Engine 和 Docker Compose
- 一个可用的 Microsoft AzureAD 租户
- FreeRADIUS 需要单独作为一个 AzureAD 应用注册
- 已经明确用户认证时使用的邮箱域名后缀，例如 `example.com`
- 已有 支持配置RADIUS或者802.1X协议的 网络设备，例如交换机、AC、AP 控制器或测试终端
- AC配置: 本项目以华为9700S-S举例:
   - huawei ac 中需要开启 `计费功能`
   - 计费方案需要开启 `实时计费`：
      - 路径: `AP组配置-wlan-access-VAP配置-wlan名称-认证模板-RADIUS服务器配置`
      - 按`时长计费`切换为`实时计费`:
      - `计费时间间隔15min`，`请求无响应最大次数3`
      - `实时计费失败后策略&开始计费失败策略：测试阶段允许用户上线，测试没问题了，灰度开始选择拒绝用户上线。`

注意事项：

- `REALM_NAME` 必须和用户认证时的后缀一致，例如 `user@example.com`
- `Azure_App_Client_ID` 必须保留，不能删除
- 证书模式下必须同时提供 `Azure_App_Client_Key_Path` 和 `Azure_App_Client_Cert_Path`
- 该集成依赖 ROPC 流程，因此 802.1X 认证过程中无法完成交互式 MFA
- 如果你的租户或用户被 MFA 策略保护，必须为这条 RADIUS 登录链路配置 Conditional Access 放行策略

本仓库当前推荐使用证书模式，不建议再把 `client secret` 作为主要接入方式。 client secret 最长2年一轮换，安全性不错但2年维护一次容易影响服务。

## 第 1 步：创建 AzureAD 应用

目前这个项目分为2种模式：
   - `Client_ID` 和 `Client_Secret` 传统模式
   - 证书模式：通过自签证书，来和Azure进行校验

传统模式请直接按照`第1步`下的步骤进行操作，根据6中的指引进行操作
证书模式先进行自签证书的创建:


在 Entra 管理中心执行以下操作：
1. 以管理员身份登录您的 Microsoft Azure 账户
2. 打开'Azure Active Directory' 服务
3. 在左侧面板的“管理”中，进入“应用注册”，选择“新注册”
4. 请使用以下设置，然后点击“注册”：
   - `Azure-radius-ent`(修改为你想要的任何名字)
   - 支持的账户类型： 仅限于该组织目录中的账户 - （单租户）
   - 重定向 URI（可选）：[空白]
5. 记下`Client ID`以备后用
6. 根据你选择的模式选择是`创建客户端密码`还是`上传证书`
   - 如果是客户端密钥请按照步骤7进行操作
   - 如果是自签证书，直接跳转到步骤8进操作
7. 对于您的新应用，请进入`客户端凭据`，点击`添加证书或机密`，再点击`新客户端密码`，
   - 输入对应的`说明` 和 `截止期限` ，这里我们举例填写:说明:Azure-radius-ent-key, 截止期限选择 `730天(24个月)`
   - 根据创建出来的记录，记录好`值`的参数（`值`只有首次创建的时候可以复制），留作备用
8. 证书模式

   - 创建自签证书参照:
找1个linux 环境，可以是你要部署radius服务的那台服务器,输入以下的命令，即可在本地生成应用私钥和证书：
   - 上传到 AzureAD 的是公钥证书
   - `azure_app_radius_key.pem` 私钥只保留在 RADIUS 主机
   - 不要上传私钥

```bash
openssl genrsa -out azure_app_radius_key.pem 2048
openssl req -new -x509 \
  -key azure_app_radius_key.pem \
  -out azure_app_radius_cert.pem \
  -days 3650 \
  -subj "/C=CN/ST=Shanghai/L=Shanghai/O=company/CN=Azure App Radius"
```
   - 回到第6步中的页面，选择`上传证书`
将 `azure_app_radius_cert.pem` 上传

9. 进入API权限 `API permissions`
10. 选择添加权限:请求获取 API 权限
   - 选择`Microsoft Graph` -> 应用程序权限`Application permissions` -> 找到`Directory.Read.All`
11. 检查`User.Read`权限，`User.Read` 应该是一个已经存在的“委派”权限类型
12. 以上权限执行: 代表XXXX授予管理员同意



## 第 2 步：为 RADIUS 登录链路放行 MFA

### 2.1 检查

在开始之前，请先确认以下几点：

1. 你的租户具备 `Microsoft AzureAD P1`、`P2` 或 `Microsoft 365 Business Premium`
2. 你使用的是 `条件访问[Conditional Access]`，而不是只依赖 `Security defaults`
3. 你准备了一个专门用于 802.1X / FreeRADIUS 的测试用户

如果你没有 `P1/P2` 或 Business Premium，通常无法用 Conditional Access 做这种放行。可以通过申请试用来获得P1/P2 权限。

### 2.2 检查并关闭 Security defaults

非常重要！！！如果租户启用了 `Security defaults`，它会对 MFA 做租户级的统一控制，不适合这种“只对部分用户放行”的场景。此时应先关闭，再改用 `条件访问[Conditional Access]`。

关闭全局的安全策略`Security defaults`:
1. 进入 `Microsoft Entra admin center`
2. 打开 `AzureAD` -> `Overview` -> `Properties`
3. 选择 `Manage security defaults`
4. 如果当前是 `Enabled`，改成 `Disabled`
5. 保存

### 2.3 创建一个专门的 MFA 放行组 or 复用现在的包含所有成员的组 比如 all hands（配置动态成员规则，只允许user.accountEnabled -eq true 以及排除掉组邮箱）

建议不要直接排除大量单个用户，而是创建一个专门的组，后续只把需要通过 FreeRADIUS 认证的用户加入进去。

配置组：
1. 进入 `AzureAD` -> `Groups` -> `All groups`
2. 点击 `New group`
3. `Group type` 选择 `Security`
4. `Membership type` 选择 `Assigned`
5. 输入组名，例如 `RADIUS-ROPC-MFA-EXEMPT`
6. 先只加入 1 个测试用户
7. 保存创建


### 2.5 创建 MFA 策略
访问Azure Directory，并且搜索: `条件访问[Conditional Access]`, 如果当前租户还没有正式的 MFA Policy 策略，可以新建一条。

步骤:

1. 进入 `AzureAD` -> `Microsoft Azure Policy Insights | 条件访问` -> `Policies`
2. 点击 `New policy`
3. 填写策略名，例如 `Require MFA - All users except RADIUS ROPC`
4. 在 `用户或智能体(预览版)` 中：
   - `Include` 选择 `All users`
   - `Exclude` 选择 `Users and groups`
5. 在 `目标资源` 中:
   - 包括所有资源.,
   - `Exclude` 中,选择`选择特定资源`,找到`Azure-radius-ent`这个资源
6. 在 `授权[Access controls]` -> `Grant` 中：
   - 选择 `授予访问权限[Grant access]`
   - 勾选 `需要多重身份验证[Require multifactor authentication]`
7. `对于多个控件` 选择 `需要某一已选控件`

注意提示:不要置身事外! 建议先将策略应用于一小部分用户，以验证它是否按预期运行。还建议至少将一名管理员从此策略中排除。这可确保你仍具有访问权限并可在需要更改时更新策略。请查看受影响的用户和应用。

这里选择`我了解我的帐户将受此策略的影响。仍要继续。`
8. 创建策略

## 第 3 步 启动服务

本项目代码主要分为3个内容:
1. `freeradius`采用开源方案 [freeradius-oauth2-perl](https://github.com/jimdigriz/freeradius-oauth2-perl/) 二次修改，用于集成AzureAD
2. `audit-exporter` 采用exporter的形式展示数据，并且通过apitoken校验才可以访问
3. `audit-dashboard` 用于审计用户登录的记录。

### 3.1 准备freeradius 自签证书 和 AUDIT_API_TOKEN

#### 3.1.1 该证书用于 FreeRADIUS 自身的 EAP-TTLS 服务端认证。

```bash
mkdir ssl/
openssl genrsa -out radius.key 2048
openssl req -new -key radius.key -out radius.csr
openssl genrsa -out radius_ca.key 2048
openssl req -new -x509 -key radius_ca.key -out radius_ca.pem -days 3650 -sha256
openssl x509 -req -in radius.csr -CA radius_ca.pem -CAkey radius_ca.key -CAcreateserial -out radius.crt -days 3650 -sha256
openssl verify -CAfile radius_ca.pem radius.crt
```

#### 3.1.2 需要准备证书和用到之前Azure证书`azure_app_radius_key.pem` 以及`azure_app_radius_cert.pem`
```bash
cp azure_app_radius_key.pem  ssl/
cp azure_app_radius_cert.pem ssl/ 
```

#### 3.1.3 配置证书权限
```bash
chmod 644 ssl/*
chmod 600 ssl/*_key.pem
chmod 600 ssl/*.key
```

#### 3.1.4 检查证书文件

```bash
ls -l ssl/
   azure_app_radius_key.pem
   azure_app_radius_cert.pem
   radius.key
   radius.crt
   radius_ca.pem
```

#### 3.1.5 生成API-TOKEN
`AUDIT_API_TOKEN` 请在生产环境中替换为你自己的随机值
生成随机 `AUDIT_API_TOKEN` 的命令：

```bash
openssl rand -hex 24
```

### 3.2 启动freeradius服务
`freeradius` 和`audit-exporter`  在一个项目内启动:
#### 3.2.1 修改Clients.conf
```bash
cd freeeradius 
mkdir logs
vim clients.conf 
# 参照格式添加or修改你的AC控制器地址以及对应的校验密钥、再添加一个用来本地测试的客户端IP地址
```
#### 3.2.2 修改docker-compose.yml文件
按照前面预留的信息，填写对应的变量参数:
- `REALM_NAME` 必须保留
- `Azure_App_Client_ID` 必须保留
- 证书模式下必须保留 `Azure_App_Client_Key_Path` 和 `Azure_App_Client_Cert_Path`
- `Azure_App_Client_Secret` 只有在你明确使用 secret 模式时才需要保留
- `AUDIT_API_TOKEN` 请在生产环境中替换为你自己的随机值，采用3.1.5中生成出来的随机值即可。
`vim  docker-compose.yml `
```yaml
environment:
  - REALM_NAME=example.com
  - Azure_App_Client_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  - Azure_App_Client_Key_Path=/etc/freeradius/ssl/azure_app_radius_key.pem
  - Azure_App_Client_Cert_Path=/etc/freeradius/ssl/azure_app_radius_cert.pem
```

#### 3.2.3 启动服务
```bash
docker-compose up -d 
```

### 3.3 测试客户端验证放行是否生效

#### 3.3.1 检查用户加入组
建议按下面顺序做验证：
1. 先只放行 1 个测试用户
2. 确认该用户已经加入 `RADIUS-ROPC-MFA-EXEMPT`
3. 确认 `Security defaults` 已关闭
4. 确认没有其他策略仍在对该用户强制 MFA
5. 用该测试用户做一次 RADIUS 认证
6. 验证通过后，再把更多用户加入这个组

#### 3.3.2 服务器本地执行

你可以在服务器上执行：

```bash
sudo apt update
sudo apt -y install freeradius-utils
radtest user@example.com user_password 127.0.0.1 1812 testing123
```

#### 3.3.3 测试服务器执行
```bash
sudo apt update
sudo apt -y install freeradius-utils
radtest user@example.com user_password <freeradius-server-ip> 1812 testing123
```


#### Q&A: 
如果用户名密码正确，但仍被拒绝，通常需要回头检查：

- 用户是否真的在 `RADIUS-ROPC-MFA-EXEMPT` 组里
- 是否还有其他 MFA 策略命中该用户
- `Security defaults` 是否还处于开启状态
- 用户是否属于联邦/混合身份场景，因为部分 federation 场景下 ROPC 本身就不支持

生产环境建议使用规范的服务端证书名称，并确保客户端正确校验证书链和服务端名称。

注意：

- 服务刚启动后的第一次认证可能比较慢，因为模块会先同步 AzureAD 用户和组信息
- 如果第一次超时，可以再重试一到两次，不要立即判定为配置错误


## 第 4 步：验证审计接口

`audit-exporter` 会读取共享目录 `logs/` 中的 `/var/log/freeradius/audit_stream.jsonl`。

你可以这样测试审计 API：

```bash
curl -i -H "Authorization: Bearer <AUDIT_API_TOKEN>" "http://localhost:9090/api/logs"
```

## 第 5 步：审计面板服务运行
```bash
cd audit-dashboard
docker-compose up -d
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
