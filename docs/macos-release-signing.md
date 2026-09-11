# macOS GitHub / 官网公证发布

GitHub Release 和官网下载的 Mac 包是 **Developer ID 签名 + 公证** 的直发包，不是 Mac App Store 包。会员购买走官网卡密与小店，不初始化 StoreKit，也不交苹果抽成。

Mac App Store 包必须走另一条脚本，见 [App Store 对接与发布](app-store-release.md)。不要把本页的公证包提交到 Mac App Store。

## 两条路径

| | 官网 / GitHub | Mac App Store |
| --- | --- | --- |
| 脚本 | `tool/macos/build_website.sh` | `tool/macos/build_app_store.sh` |
| 签名 | Developer ID + Notary | Apple Distribution |
| `OPEN_READING_MACOS_APP_STORE` | `false` | `true` |
| 高级版购买 | 卡密 / 小店 | App Store 内购 |
| 应用内更新 | 官网 / GitHub 检查更新 | 仅 App Store 更新 |
| CI | `.github/workflows/release.yml` 的 `macos` job | 不进 GitHub Release；本地脚本归档/上传 |

## 发布产物

- 文件名：`OpenReading-macOS-universal-<version>.zip`
- 架构：Apple Silicon `arm64` + Intel `x86_64`
- 应用身份：`com.niki.xxread`
- 签名：Developer ID Application
- 安全：Hardened Runtime、Apple Notary Service、公证票据 stapling
- 校验：bundle 版本、双架构、`codesign --strict`、`stapler validate`、Gatekeeper `spctl`、**生成配置里没有商店 dart-define**

ZIP 内是已经签名并 stapled 的 `.app`。ZIP 本身只作为保留扩展属性和资源分叉的传输容器。

## 本地构建

从仓库根目录执行。官网脚本会带上 `--dart-define=OPEN_READING_MACOS_APP_STORE=false`，覆盖本机残留的商店开关，并拒绝 `true`。构建后读取 `macos/Flutter/ephemeral/Flutter-Generated.xcconfig` 再确认一次。

```bash
# 只检查工具，不构建。
bash tool/macos/build_website.sh --check

# 本地完整构建（会先 locked pub get）。
bash tool/macos/build_website.sh

# CI 已完成 pub get / gen-l10n 时：
bash tool/macos/build_website.sh --no-pub
```

不要手写：

```bash
flutter build macos --release --dart-define=OPEN_READING_MACOS_APP_STORE=true
```

那会把官网包编成商店内购包。GitHub `macos` job 只调用 `tool/macos/build_website.sh --no-pub`。

## GitHub `release` Environment

macOS 正式包由 `.github/workflows/release.yml` 的可选 `macos` job 构建。该 job 仅在仓库变量 `MACOS_RELEASE_ENABLED` 严格等于 `true` 时运行；未启用时，现有 Android、Windows、Linux 和官网镜像流程保持不变。

在已有 `release` Environment 中增加以下 Secrets：

```text
MACOS_DEVELOPER_ID_P12_BASE64
MACOS_DEVELOPER_ID_P12_PASSWORD
MACOS_NOTARY_KEY_ID
MACOS_NOTARY_ISSUER_ID
MACOS_NOTARY_PRIVATE_KEY_BASE64
MACOS_PROVISIONING_PROFILE_BASE64
```

- P12 必须包含 `Developer ID Application` 证书及其私钥，不能使用 Apple Distribution 证书代替。
- 两个 Base64 Secret 都必须是原始文件字节的无换行标准 Base64，不能包含文件路径或说明文字。
- 公证凭据使用 App Store Connect API Key：Key ID、Issuer ID 和对应 `.p8` 私钥。
- Developer ID 描述文件必须匹配 `com.niki.xxread` 和导入的 Developer ID 证书。
- 工作流只把材料写入 runner 临时目录和临时 keychain，并在 job 结束时删除。

## 启用顺序

1. 确认 `miloquinn/open-reading-web` 已部署 manifest 驱动的动态资产校验器，并允许：

   ```text
   (macos, zip, universal) -> OpenReading-macOS-universal-{version}.zip
   ```

2. 确认官网导入器仍会严格校验平台、包类型、架构、规范文件名、GitHub Release 资产集合和 SHA-256；资产总数不得重新锁死。
3. 写入上述 GitHub Environment Secrets。
4. 设置仓库变量：

   ```bash
   gh variable set MACOS_RELEASE_ENABLED \
     --repo miloquinn/open-reading \
     --body true
   ```

5. 只对新的版本 Tag 启用。已经发布的 Tag 受不可变资产集合保护，不能在重跑时追加 macOS 包。

若官网仍使用固定资产数量校验，不得打开变量；否则 GitHub Release 会生成 macOS 资产，但官网镜像导入会失败。

## 关闭

需要临时停用 macOS 构建时，将仓库变量改为 `false`。Secrets 可以继续保留在受审批保护的 `release` Environment 中：

```bash
gh variable set MACOS_RELEASE_ENABLED \
  --repo miloquinn/open-reading \
  --body false
```

## 脚本自检

```bash
python3 -m unittest discover -s tool/macos -p 'test_*.py' -v
bash -n tool/macos/build_website.sh
bash -n tool/macos/build_app_store.sh
```
