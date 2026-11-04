# GitHub Actions Tag Release CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pushing a `vX.Y.Z` tag builds macOS DMG, iOS unsigned IPA, and CLI zip via `Scripts/package.sh`, then uploads them to a GitHub Release.

**Architecture:** One `macos-15` job in `.github/workflows/release.yml`. Before packaging, `Scripts/set-version.sh` rewrites `MARKETING_VERSION` in the Xcode project from the tag (workspace only). Packaging stays in existing `Scripts/package.sh`. Signing remains ad-hoc; secrets hooks are documented comments only.

**Tech Stack:** GitHub Actions, `macos-15` runner, Xcode/`xcodebuild`, SwiftPM, `hdiutil`, `softprops/action-gh-release@v2`, bash.

## Global Constraints

- Trigger: push tags matching `v*` only; validate semver `vX.Y.Z` (no prerelease suffix in this phase).
- Do not build installers on PR or `main` push.
- Version source: CI rewrites `MARKETING_VERSION` from tag; do not push that rewrite back to git.
- Signing: ad-hoc / unsigned IPA this phase; reserve `SIGN_IDENTITY` + future Secrets, do not implement notarization.
- Reuse `Scripts/package.sh`; change it only if CI compatibility requires a minimal fix.
- Spec: `docs/superpowers/specs/2026-11-04-github-release-ci-design.md`.

## File Map

| File | Responsibility |
| --- | --- |
| `Scripts/set-version.sh` | Parse/accept `X.Y.Z`, rewrite all `MARKETING_VERSION` in `App/Tescam.xcodeproj/project.pbxproj` |
| `.github/workflows/release.yml` | Tag trigger, version bump, package, upload Release |
| `Scripts/package.sh` | Unchanged unless a CI blocker is found; keep reading version from pbxproj |
| `README.md` | Document `git tag` / `git push` release flow and CI artifacts |

---

### Task 1: Version bump script

**Files:**
- Create: `Scripts/set-version.sh`
- Test: local shell invocations against a temp copy or the real pbxproj (restore after)

**Interfaces:**
- Consumes: first CLI arg `VERSION` as `X.Y.Z` (no leading `v`)
- Produces: updates every `MARKETING_VERSION = …;` in `App/Tescam.xcodeproj/project.pbxproj`; exit 0 on success, non-zero on bad input or missing file
- Later tasks call: `Scripts/set-version.sh 0.1.0` or `Scripts/set-version.sh "${GITHUB_REF_NAME#v}"`

- [ ] **Step 1: Write `Scripts/set-version.sh`**

```bash
#!/bin/bash
# 将 MARKETING_VERSION 设为给定 X.Y.Z（不带 v 前缀）。供 CI 发版与本地对齐版本使用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/App/Tescam.xcodeproj/project.pbxproj"
VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 1
fi
if [[ ! -f "$PBX" ]]; then
  echo "missing $PBX" >&2
  exit 1
fi

# portable in-place replace (macOS BSD sed + GNU sed)
if sed --version >/dev/null 2>&1; then
  sed -i -E "s/(MARKETING_VERSION = )[^;]+;/\1$VERSION;/" "$PBX"
else
  sed -i '' -E "s/(MARKETING_VERSION = )[^;]+;/\1$VERSION;/" "$PBX"
fi

grep -n "MARKETING_VERSION" "$PBX"
echo "MARKETING_VERSION -> $VERSION"
```

- [ ] **Step 2: Make executable and verify reject / accept**

```bash
chmod +x Scripts/set-version.sh
cp App/Tescam.xcodeproj/project.pbxproj /tmp/tescam-pbxproj.bak
Scripts/set-version.sh not-a-version; echo "exit=$?"
# Expected: usage message, exit=1

Scripts/set-version.sh 9.8.7
grep MARKETING_VERSION App/Tescam.xcodeproj/project.pbxproj
# Expected: both lines show 9.8.7

mv /tmp/tescam-pbxproj.bak App/Tescam.xcodeproj/project.pbxproj
grep MARKETING_VERSION App/Tescam.xcodeproj/project.pbxproj
# Expected: restored to 0.1.0 (or prior value)
```

- [ ] **Step 3: Commit**

```bash
git add Scripts/set-version.sh
git commit -m "$(cat <<'EOF'
Add set-version.sh to sync MARKETING_VERSION for releases.

EOF
)"
```

---

### Task 2: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `Scripts/set-version.sh`, `Scripts/package.sh`; `GITHUB_REF_NAME` like `v0.1.0`; `contents: write` for Release upload
- Produces: GitHub Release named from tag with `dist/TesCam-*-macOS.dmg`, `dist/TesCam-*-iOS-unsigned.ipa`, `dist/tescam-*-macOS-cli.zip`, `dist/SHA256SUMS.txt`
- Signing hook: optional env `SIGN_IDENTITY` from secret `SIGN_IDENTITY` if present; empty → package.sh default `-`

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  package:
    runs-on: macos-15
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Validate tag and set version
        run: |
          TAG="${GITHUB_REF_NAME}"
          if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Tag must be vX.Y.Z (got: $TAG)" >&2
            exit 1
          fi
          VERSION="${TAG#v}"
          echo "VERSION=$VERSION" >> "$GITHUB_ENV"
          Scripts/set-version.sh "$VERSION"

      - name: Select Xcode
        run: |
          # Prefer latest Xcode 16+ on the image
          sudo xcode-select -s /Applications/Xcode.app
          xcodebuild -version

      - name: Build packages
        env:
          # Future: set repo secret SIGN_IDENTITY to a Developer ID identity name
          # after importing a .p12 (MACOS_CERTIFICATE_* secrets — not wired yet).
          SIGN_IDENTITY: ${{ secrets.SIGN_IDENTITY }}
        run: Scripts/package.sh

      - name: List artifacts
        run: ls -lh dist && cat dist/SHA256SUMS.txt

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          name: TesCam ${{ env.VERSION }}
          draft: false
          prerelease: false
          fail_on_unmatched_files: true
          files: |
            dist/TesCam-${{ env.VERSION }}-macOS.dmg
            dist/TesCam-${{ env.VERSION }}-iOS-unsigned.ipa
            dist/tescam-${{ env.VERSION }}-macOS-cli.zip
            dist/SHA256SUMS.txt
          body: |
            ## 安装包

            | 文件 | 说明 |
            | --- | --- |
            | `TesCam-${{ env.VERSION }}-macOS.dmg` | macOS 15+，Apple 芯片与 Intel 通用。未公证，首次打开需在「系统设置 › 隐私与安全性」中允许 |
            | `TesCam-${{ env.VERSION }}-iOS-unsigned.ipa` | iOS / iPadOS 18+ 未签名，需用自己的 Apple ID 重签后安装 |
            | `tescam-${{ env.VERSION }}-macOS-cli.zip` | 命令行工具 |
            | `SHA256SUMS.txt` | 校验和 |

            由 tag `${{ github.ref_name }}` 自动构建。
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: YAML sanity check**

```bash
# If Python PyYAML available:
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo OK
# Or at least:
test -f .github/workflows/release.yml && grep -q 'Scripts/package.sh' .github/workflows/release.yml && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
Add GitHub Actions workflow to publish installers on version tags.

EOF
)"
```

---

### Task 3: package.sh CI readiness

**Files:**
- Modify: `Scripts/package.sh` (only if needed)
- Verify: header comment mentions CI / `SIGN_IDENTITY` secret name for later

**Interfaces:**
- Consumes: `MARKETING_VERSION` already set by `set-version.sh`; optional `SIGN_IDENTITY`
- Produces: same four files under `dist/`

- [ ] **Step 1: Read `Scripts/package.sh` and confirm CI assumptions**

Check that:
1. Version is read from `MARKETING_VERSION` in pbxproj (after Task 1 rewrite this matches the tag).
2. Default `SIGN_IDENTITY=-` works when secret is empty. If empty secret becomes `SIGN_IDENTITY=""` and breaks codesign, fix by normalizing at top of `package.sh`:

```bash
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi
```

3. Header comment documents GitHub Actions usage in one line, e.g. `# CI: .github/workflows/release.yml 在 tag vX.Y.Z 时调用；可设 SIGN_IDENTITY。`

- [ ] **Step 2: Apply only the empty-`SIGN_IDENTITY` guard + one-line CI comment if Step 1 found a gap; otherwise skip code changes**

- [ ] **Step 3: Commit only if files changed**

```bash
git add Scripts/package.sh
git commit -m "$(cat <<'EOF'
Harden package.sh for empty SIGN_IDENTITY in CI.

EOF
)"
```

If unchanged: no commit.

---

### Task 4: README release docs

**Files:**
- Modify: `README.md` — section `### 安装包` (around existing `Scripts/package.sh` docs)

**Interfaces:**
- Documents: tag push flow; links artifacts to GitHub Releases; notes unsigned/notarization; points at workflow path

- [ ] **Step 1: Insert after the local `Scripts/package.sh` table**

Add a subsection:

```markdown
### GitHub 自动发版

推送 semver tag 后，GitHub Actions（`.github/workflows/release.yml`）在 `macos-15` 上调用 `Scripts/set-version.sh` + `Scripts/package.sh`，并把产物上传到 [Releases](https://github.com/leeyxq/tescam/releases)：

```bash
git tag v0.1.0
git push origin v0.1.0
```

- tag 必须为 `vX.Y.Z`；CI 会把工程内 `MARKETING_VERSION` 临时改成该版本再打包（不写回仓库）。
- 当前为 ad-hoc / 未公证；配置仓库 Secret `SIGN_IDENTITY`（及后续证书 Secrets）后可接 Developer ID 签名。
```

Keep existing local packaging table; do not remove it.

- [ ] **Step 2: Skim README for broken fences / duplicate headings**

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
Document tag-based GitHub Actions release flow.

EOF
)"
```

---

### Task 5: Push and verify on GitHub

**Files:**
- None (ops)

- [ ] **Step 1: Push commits to `origin/main`**

```bash
git push origin main
```

Expected: success; remote contains `set-version.sh`, workflow, README updates.

- [ ] **Step 2: Publish a release tag (use real desired version; if `v0.1.0` already used locally only, still fine if remote has no such tag)**

```bash
git tag v0.1.0
git push origin v0.1.0
```

If `v0.1.0` already exists on remote from a prior attempt, either delete and recreate **only with user approval**, or bump to `v0.1.1` after aligning expectations.

- [ ] **Step 3: Watch workflow**

```bash
gh run watch --repo leeyxq/tescam
# or:
gh run list --repo leeyxq/tescam --workflow=release.yml -L 3
```

Expected: job `package` green; Release page lists four assets whose versions match the tag.

- [ ] **Step 4: Spot-check artifacts**

Download from the Release: confirm `SHA256SUMS.txt` matches; on a Mac, open DMG / run CLI briefly per design acceptance criteria.

---

## Spec coverage (self-review)

| Spec requirement | Task |
| --- | --- |
| Tag-only `vX.Y.Z` trigger | Task 2 |
| Rewrite `MARKETING_VERSION` from tag | Task 1 + Task 2 |
| Single job + `package.sh` | Task 2 + Task 3 |
| Four artifacts + Release body | Task 2 |
| Ad-hoc + `SIGN_IDENTITY` / Secrets reserved | Task 2 comments + Task 3 + Task 4 |
| README release ops | Task 4 |
| Acceptance via real tag run | Task 5 |
| No Fastlane / no PR package builds | Task 2 `on:` block |

No placeholders left; `set-version.sh` and workflow YAML are fully specified.
