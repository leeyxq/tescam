# TesCam · Tesla 行车记录仪导出工具

读取特斯拉行车记录 U 盘（TeslaCam），把多路摄像头按需组合，叠加时间、车速、刹车、转向等水印，
自动识别风险事件点，导出可用于**交通违法举报**或**事故纠纷取证**的视频片段。
一套 SwiftUI 代码同时支持 **iOS / iPadOS / macOS**。

## 需求

1. 读取 Tesla 行车记录 U 盘内容，按不同组合拼接行车摄像头画面；识别风险事件点；自由组合速度、刹车、转向等数据水印；
   支持哨兵、紧急事件、行车记录；可在不同时间点批量合成片段，导出带水印的视频，用于违法行为举报或事故纠纷证据。
2. 统一架构平台，支持 iOS、Mac。

## 功能

| 模块 | 能力 |
| --- | --- |
| 读取 U 盘 | 选择 U 盘根目录、`TeslaCam` 或任一子目录即可；识别 `RecentClips` / `SavedClips` / `SentryClips`；解析 `event.json`（时间、城市、坐标、触发原因）和 `thumb.png`；RecentClips 按间隔自动切分为多次行程 |
| 事件分类 | 行车记录、手动保存、哨兵事件、紧急事件（碰撞/紧急制动/车身震动） |
| 摄像头 | 前视、后视、左/右侧后方（翼子板）、左/右 B 柱（新款车型） |
| 画面组合 | 单画面、左右并排、画中画、宫格（1–6 路）、主视+三联（仿车机） |
| 车辆数据 | 解析视频每帧 SEI 中的车速、档位、刹车、油门、方向盘转角、转向灯、辅助驾驶状态、GPS、加速度（需 2025 年后固件录制） |
| 风险识别 | 事件触发点、急刹车、急加速、急转向、高速行驶、辅助驾驶退出；阈值可配置 |
| 水印 | 顶栏：时间戳、事件类型/城市、自定义文字（如“交通违法举报证据”）、标识；底栏：车速、档位、刹车/油门、方向盘、转向灯、驾驶模式、GPS；每路画面标注摄像头名称。水印放在画面外的上下栏，不遮挡原始画面 |
| 导出 | 任选起止时间（可跨多个 1 分钟分段）、单个风险点前后 N 秒、或批量导出全部风险片段；720p/1080p/1440p/原始分辨率；H.264/HEVC |
| 证据清单 | 每个导出视频附带 `*.manifest.json`：所用源文件名、SHA-256、文件大小、时间区间、事件信息与导出参数，便于证明来源与完整性 |
| 所见即所得 | App 内预览与导出使用同一个合成器 |

## 架构

```
┌──────────────────────── App (SwiftUI, iOS + macOS 一套代码) ────────────────────────┐
│ 侧边栏(分类) → 事件列表(缩略图) → 详情：同步多路预览 / 车速时间轴 / 风险点 / 导出面板 │
└───────────────────────────────────────┬─────────────────────────────────────────────┘
                                        │                      ┌──────────────────────┐
                                        ▼                      │ tescam 命令行 (macOS) │
┌──────────────────────────────── TeslaCamKit (Swift Package) ─┴──────────────────────┤
│ Library    TeslaCamScanner → TeslaCamLibrary / DashcamEvent / ClipSegment / EventInfo │
│ Telemetry  SEIExtractor(MP4 box → NAL → SEI → protobuf) → TelemetryTrack              │
│ Risk       RiskDetector(加减速度 / 方向盘转速 / 横向加速度 / 状态变化) → RiskPoint      │
│ Export     LayoutPlan → CompositionBuilder(AVMutableComposition)                      │
│            → DashcamCompositor(Core Image 拼接 + OverlayRenderer 水印)                │
│            → DashcamExporter(AVAssetExportSession + 证据清单)                         │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

- 只依赖系统框架（AVFoundation、Core Image、Core Text、CryptoKit、Swift Charts），无第三方依赖。
- 车辆数据 SEI 解析参考特斯拉公开的 [teslamotors/dashcam](https://github.com/teslamotors/dashcam) 格式：
  `user_data_unregistered` 载荷为若干 `0x42` + `0x69` + `SeiMetadata` protobuf；同时兼容“16 字节 UUID + protobuf”。

## 目录

```
Package.swift                  TeslaCamKit 库 + tescam 命令行 + 测试
Sources/TeslaCamKit/
  Library/                     U 盘扫描、文件名/event.json 解析、事件模型
  Telemetry/                   MP4/SEI/protobuf 解析，车辆数据时间序列
  Risk/                        风险事件识别
  Export/                      布局、水印渲染、自定义合成器、导出与证据清单
Sources/tescam-cli/            命令行工具
Tests/TeslaCamKitTests/        单元测试 + 端到端导出测试
App/Tescam.xcodeproj           多平台 App 工程（iOS 18+ / macOS 15+）
App/Tescam/                    SwiftUI 界面
Scripts/make-sample-teslacam.sh  用 ffmpeg 生成模拟 U 盘数据
```

## 使用

### App

用 Xcode 16+ 打开 `App/Tescam.xcodeproj`，选择 Mac 或 iPhone/iPad 运行（真机需在 Signing 中选择自己的 Team）。

1. 点击“打开”，选择 U 盘根目录或 `TeslaCam` 文件夹（iPhone/iPad 通过 USB-C 读卡器在“文件”中选择）。
2. 选择事件，在车速时间轴上拖动绿色开始线、红色结束线框选区间（或播放到某处按 I / O 设置），风险点列表中“框选”可快速把两条线移到风险点前后。
3. 点“导出选区”（⌘E），导出范围始终以两条线为准。
4. 选择布局、摄像头、水印项和自定义文字后导出；工具栏“批量导出风险片段”一次导出全部风险点。
5. 导出完成后可分享、存储到指定位置，或在 macOS 的访达中显示。

### 命令行（macOS）

```bash
swift build -c release
B=.build/release/tescam

$B scan /Volumes/TESLA                       # 列出事件及序号
$B risks /Volumes/TESLA --event 0            # 识别风险点
$B telemetry /Volumes/TESLA/TeslaCam/SavedClips/<目录>/<文件>-front.mp4 > data.csv

# 导出事件 0 中第 30 秒起的 20 秒，主视+三联，带举报水印
$B export /Volumes/TESLA --event 0 --offset 30 --duration 20 \
   --layout teslaStyle --text "交通违法举报证据" --out report.mp4

# 每个风险点前 10 秒、后 5 秒批量导出
$B batch /Volumes/TESLA --event 0 --before 10 --after 5 --out-dir clips/
```

### 安装包

```bash
Scripts/package.sh        # 输出到 dist/
```

| 文件 | 说明 |
| --- | --- |
| `TesCam-<版本>-macOS.dmg` | macOS 15+，Apple 芯片与 Intel 通用。本地签名、未公证，首次打开需在“系统设置 › 隐私与安全性”中点“仍要打开”（或右键 › 打开） |
| `TesCam-<版本>-iOS-unsigned.ipa` | iOS / iPadOS 18+ 未签名包，需用 Xcode、AltStore、Sideloadly 等以自己的 Apple ID 重签后安装（免费账号 7 天有效） |
| `tescam-<版本>-macOS-cli.zip` | 命令行工具，通用二进制 |
| `SHA256SUMS.txt` | 各安装包校验值 |

有付费开发者账号时，可设置 `SIGN_IDENTITY="Developer ID Application: …"` 后打包并自行公证；iOS 正式分发需通过 Xcode Archive 上传 TestFlight / App Store。
`Scripts/make-icon.swift` 用于重新生成 App 图标。

### 开发与测试

```bash
swift test                                            # 单元测试
Scripts/make-sample-teslacam.sh /tmp/usb 10           # 生成模拟 U 盘（无车辆数据）
TESCAM_SAMPLE=/tmp/usb TESCAM_OUT=/tmp/out swift test # 含端到端导出测试（模拟车辆数据）
xcodebuild -project App/Tescam.xcodeproj -scheme Tescam -destination 'platform=macOS' build
xcodebuild -project App/Tescam.xcodeproj -scheme Tescam -destination 'generic/platform=iOS Simulator' build
```

Debug 版 App 支持启动参数 `-TesCamOpen <目录>` 自动打开目录（沙盒下仅限已授权目录）、`-TesCamSelect <序号>` 自动选中事件。正式使用时 App 会记住上次选择的目录，插入 U 盘后自动加载。

## 路线图

- [x] M1 核心库：U 盘扫描、event.json、SEI 车辆数据、风险识别
- [x] M2 合成导出：5 种布局、动态水印、跨分段拼接、批量导出、证据清单
- [x] M3 多平台 App：浏览、同步预览、车速时间轴、风险点、导出面板
- [x] M4 命令行工具与测试
- [x] 真实 U 盘验证（HW4 六摄像头、2026 年固件，138 个事件 / 228 GB）：SEI 解析、风险阈值、分段对齐
- [x] 记住上次打开的目录（安全作用域书签），插拔 U 盘自动加载/清空
- [ ] 导出到“照片”、横屏全屏播放、iPad 键盘快捷键
- [ ] 车牌区域放大 / 局部打码、地图轨迹叠加
- [ ] 风险阈值设置界面、多事件合并导出
- [x] App 图标、各平台安装包
- [ ] 本地化、Developer ID 签名与公证

## 真实数据验证结论

在一块真实 U 盘（HW4、6 路摄像头、228 GB、138 个事件，含 2 次 AEB）上测试：

| 项目 | 结论 |
| --- | --- |
| SEI 格式 | 与 teslamotors/dashcam 一致：`42 42 42 69` + protobuf；字段 1–6、14–16 已用实测核对 |
| GPS | 该车 SEI 中不含 GPS（字段 11–13 缺失），位置仅来自 event.json |
| IMU 轴向 | `ay` 为纵向（与车速变化相关 −0.96），`ax` 为横向（与 v²·转角相关 0.91）；急转向用 `ax` |
| 刹车信号 | 只反映踩踏板；单踏板回收和 AEB 自动制动都不会点亮，急刹以减速度判定 |
| 停车录像 | 不含 SEI；读取时每秒抽查一帧，无数据即跳过 |
| 帧率 | 行驶 36fps，停车约 24fps，同一文件内可变帧率；时间取自 stts 而非平均帧间隔 |
| 分段对齐 | 停车→起步、AEB 保存的分段时长可能超过与下一段的间隔，按下一段起点前移 |
| AEB 事件 | 两次 AEB 的触发时间与检测到的急刹（0.66g / 0.44g）均在 1 秒内吻合 |
| 性能 | 扫描 138 个事件 0.8 秒；单段 SEI 读取约 0.35–0.9 秒；12 秒 4 路导出约 7 秒 |

## 注意事项

- 车机按本地时间命名文件，App 按设备当前时区解释时间。
- 较早固件录制的视频和停车录像不含 SEI 车辆数据，此时只显示事件触发点，水印只有时间与摄像头信息。
- 水印中的“刹车”表示驾驶员踩下制动踏板，AEB 与动能回收减速不会点亮。
- 导出的证据视频是对原始视频的再编码；如需提交原始文件，可依据证据清单中的文件名和 SHA-256 找到对应源文件。
