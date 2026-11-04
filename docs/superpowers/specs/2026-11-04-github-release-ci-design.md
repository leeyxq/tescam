# GitHub Actions 自动发版设计

日期：2026-11-04  
状态：已定稿（待实现）

## 目标

推送符合 semver 的 git tag（`vX.Y.Z`）后，由 GitHub Actions 在 macOS runner 上自动构建各平台安装包，并上传到对应的 GitHub Release。

## 已确认决策

| 项 | 选择 |
| --- | --- |
| 触发方式 | 仅推送 `v*` tag 时构建并发布（方案 A） |
| 签名 | 本阶段 ad-hoc / 未公证；预留 Developer ID + 公证 Secrets 接口（方案 C） |
| 版本号 | CI 用 tag 同步改写 `MARKETING_VERSION` 后再打包（方案 C） |
| 实现形态 | 单 Job + 复用 `Scripts/package.sh` |

## 触发与流程

```
推送 tag v0.1.0
        │
        ▼
.github/workflows/release.yml  (macos-15)
  1. checkout
  2. 解析 tag → 版本号（去掉前缀 v），校验为 X.Y.Z
  3. 改写 App/Tescam.xcodeproj 中 MARKETING_VERSION（仅 CI 工作区，不 push 回仓库）
  4. 运行 Scripts/package.sh（可读 SIGN_IDENTITY；无则 ad-hoc）
  5. softprops/action-gh-release 创建或更新 Release
  6. 上传 dist/*，Release 正文含产物列表与安装提示
```

规则：

- 仅匹配 `v*`；本阶段只支持 `vX.Y.Z`（不支持 `-beta` 等预发布后缀）
- 非合法版本号 → job 失败，不创建 Release
- 不在 PR / `push` 到 `main` 时构建安装包
- Release 为正式版（非 prerelease）
- 同名 tag 已有 Release 时更新附件（便于重跑）

## 产物

与本地 `Scripts/package.sh` 一致：

| 文件 | 说明 |
| --- | --- |
| `TesCam-<ver>-macOS.dmg` | macOS 15+ 通用包，本地/ad-hoc 签名，未公证 |
| `TesCam-<ver>-iOS-unsigned.ipa` | iOS/iPadOS 18+ 未签名，需用户自签安装 |
| `tescam-<ver>-macOS-cli.zip` | 命令行工具通用二进制 |
| `SHA256SUMS.txt` | 各包 SHA-256 |

## 改动范围

### 新增

- `.github/workflows/release.yml`：发版流水线
- `Scripts/set-version.sh`：将 `X.Y.Z` 写入 `project.pbxproj` 的 `MARKETING_VERSION`（供 CI 与本地复用）

### 调整

- `Scripts/package.sh`：仅在 CI 兼容性需要时做最小改动；版本仍从 `MARKETING_VERSION` 读取
- `README.md`：补充打 tag 发版步骤与 CI 产物说明

### 不做

- 不改 App / TeslaCamKit 业务代码
- 不引入 Fastlane
- 本阶段不做 Developer ID 签名与公证（仅预留）
- 不在 main/PR 上打安装包

## 签名预留

本阶段行为与本地一致：`SIGN_IDENTITY` 默认为 `-`（ad-hoc）。

后续可接的 Secrets（写入注释 / README，workflow 用条件判断，有值再导入钥匙串）：

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID`（公证用）
- 或沿用环境变量 `SIGN_IDENTITY` 在已导入证书的 runner 上签名

## 失败策略

- tag 非 `vX.Y.Z` → fail
- `xcodebuild` / `swift build` / `hdiutil` / 打包任一步失败 → fail，不上传残缺产物
- 仅 tag 触发，控制 macOS runner 分钟消耗

## 发版操作

```bash
git tag v0.1.0
git push origin v0.1.0
```

## 验收标准

1. 推送 `vX.Y.Z` 后 Actions 中 `Release` workflow 成功
2. 对应 GitHub Release 含上述 4 个文件，文件名版本与 tag 一致
3. macOS 打开 DMG 后可启动 App（未公证的「仍要打开」流程与本地一致）
4. CLI zip 解压后工具可运行
5. 本地 `Scripts/package.sh` 行为与现有一致

## 实现顺序建议

1. 添加 `Scripts/set-version.sh` 并本地验证改写 `MARKETING_VERSION`
2. 添加 `.github/workflows/release.yml`
3. 按需微调 `package.sh`
4. 更新 README
5. 推送文档与 CI 后，用测试 tag 或正式 tag 验证
