# who-is-faster 云区域测速（Windows / PowerShell）

在本机测试到 **Oracle Cloud、Azure、AWS** 各区域的网络延迟和丢包，按小时积累数据，用本地网页查看统计、热力图和趋势，并可追踪**去程 / 回程**路由——帮你判断"从我的网络到哪家云、哪个区域最快最稳"，尤其是晚高峰。

> **三步上手**（Windows 10 / 11，无需安装任何软件）
> 1. 点本页右上方绿色 **Code** 按钮 → **Download ZIP**，解压到任意文件夹。
> 2. 双击 **`启动测速网站.cmd`**，浏览器会自动打开测速网站（使用期间不要关闭弹出的黑色窗口）。
> 3. 勾选要测的区域，点「开始测速」。
>
> 双击时如果出现 Windows 安全提示，点「仍要运行」或「运行」即可。

## 特点

- **零依赖**：只用 Windows 自带的 PowerShell 5.1 和 `tracert`；图表库（Apache ECharts）已随附，离线可用。
- **覆盖三家云**：Oracle 32 个区域、AWS 34 个区域、Azure 8 个亚洲主要区域（可自行添加）。
- **测得准**：依次发起 TCP 连接测"建立连接"往返时间（含去程和回程）；统计超时和"超过 1 秒"（首包丢失重传）的次数。
- **本地网站**：执行测速（实时进度、结果表、路径）、统计总览（排名表、区域 × 24 小时热力图）、趋势折线、明细。只监听 `localhost`，带随机口令防止其他网页调用。
- **定时测速**：Windows 任务计划每小时自动测一次。可以直接在网站"定时任务"页选择测哪些区域（按云厂商、按大洲批量勾选）、是否追踪路径、每天哪几个整点测，以及暂停/恢复、立即运行一次、卸载；"定时任务"页还能看到每次运行的记录（成功 / 中断 / 出错 / 跳过、用时），定时测速进行中时各页面顶部会提示进度；网页测速与定时任务互斥，不会同时测互相干扰。
- **数据管理**：网站"数据管理"页可按"N 天以前 / 某一次测速 / 某个区域 / 全部"清理数据，并清理旧日志；每次清理前自动备份（保留最近 10 份），可一键恢复。
- **路径分析**：每一跳 IP 换算成"运营商@城市"，常见运营商显示中文简称（电信163、电信CN2、NTT、PCCW、SK宽带……），亚欧区域绕经美国会标记 `[经美国]`；在自己的服务器上可测回程。

## 长期积累数据

单次测速只反映当时的网络状况。想知道哪个区域长期最稳，可以在网站"定时任务"页选好时间点，点「保存并安装」（也可以双击 `tools\安装定时任务.cmd`）。默认只在你登录 Windows 时运行，无需管理员。
攒几天后在网站"统计总览"看**晚高峰（21-24 点）**那一列。

## 目录

```
├─ 启动测速网站.cmd     双击启动网站并打开浏览器（关闭命令行窗口即停止）
├─ app\                 程序：latency.ps1（测速）、dashboard.ps1（网站）、定时任务相关脚本
├─ tools\               安装定时任务 / 卸载定时任务 / 立即测速一次 / 命令行报告
├─ web\                 网页（index.html）和 ECharts
├─ config\              配置示例 config.example.psd1（个人配置见下方"配置"一节）
└─ data\                运行后生成：latency.csv（测速数据，可用 Excel 打开）、日志、自动备份
```

## 配置（可选）

复制 `config\config.example.psd1` 为 `config\config.psd1` 后修改：

| 项 | 作用 |
|---|---|
| `SiteLabel` | 网站标题里显示的站点名 |
| `DashboardPort` | 网站端口（默认 8765） |
| `Schedule` | 定时任务名、时间点、随机推迟、运行方式（`Interactive` 个人电脑 / `S4U` 服务器不登录也运行，需管理员安装）。时间点和随机推迟也可在网站上改 |
| `Regions` | 命令行默认测哪些区域（空 = 全部，约 74 个，每次约 6~8 分钟）；定时任务在网站上保存过区域后，以网站上的设置为准 |
| `Reference` / `ReferenceNames` | 把你自己的服务器作为对照组一起测 |
| `ReturnProbes` / `SshKey` | 在某区域有自己的 Linux 服务器时测回程（需装 `mtr`） |
| `IpinfoToken` | ipinfo.io 令牌（查询量大时） |

区域代码：Oracle 用原生代码（如 `ap-tokyo-1`），Azure 加 `azure-` 前缀（如 `azure-japaneast`），AWS 加 `aws-` 前缀（如 `aws-ap-northeast-1`）。

## 命令行用法

```powershell
powershell -ExecutionPolicy Bypass -File app\latency.ps1                       # 测速（默认区域）
powershell -ExecutionPolicy Bypass -File app\latency.ps1 -Trace                # 测速 + 路径
powershell -ExecutionPolicy Bypass -File app\latency.ps1 -Report               # 按时段汇总
powershell -ExecutionPolicy Bypass -File app\latency.ps1 -Regions ap-osaka-1,aws-ap-northeast-1 -Rounds 20
```

## 网站上管理定时任务的说明

- `LogonType = 'S4U'`（服务器不登录也运行）时，在网站上安装、暂停、卸载都需要管理员权限：右键 `启动测速网站.cmd` →「以管理员身份运行」。
- 如果任务是从另一个文件夹安装的（例如移动过文件夹），"定时任务"页会提示，点「保存并安装」即可指向当前文件夹。
- 定时任务或网页测速正在运行时，不能清理或恢复数据（避免同时写同一个文件）。

## 测量原理与局限

| 云 | 测速地址 |
|---|---|
| Oracle | `objectstorage.<区域>.oraclecloud.com:443` |
| Azure | `s8<区域>.blob.core.windows.net:443`（azurespeed.com 在各区域部署的测速存储账号） |
| AWS | `dynamodb.<区域>.amazonaws.com:443` |

- 同一区域的云服务器通常走相同线路，但**不保证完全一致**；正式部署前请对实际服务器再测一次。
- 测的是 TCP 建连时间（往返延迟），不等于下载带宽。
- 路由追踪在延迟测量**之后**进行（并发的 tracert 会干扰测速、把丢包率测高）。
- 回程只能在你拥有服务器的区域测量；"@城市"来自 ipinfo.io 地理库，骨干网节点的城市常不准。
- 结果只代表运行时**你所在的网络和时段**。

## 隐私说明

- 路径追踪时，沿途**公网路由器 IP** 会发送给 ipinfo.io 查询归属（私有地址不会），结果缓存在 `data\ip-cache.json`。
- 测回程时，会访问 myip.ipip.net / 4.ipw.cn / ip.3322.net / api.ipify.org 之一获取你的公网 IP，并作为 mtr 目标传给你自己的服务器。
- `data\latency.csv` 的路径列包含你所在运营商的路由信息，公开分享前请自行检查。
- 网站只监听本机；工具不会上传测速结果到任何地方。

## 系统要求

Windows 10 / 11，PowerShell 5.1 及以上（系统自带）；测回程需 Windows 自带的 OpenSSH 客户端。

## 许可证

MIT，见 [LICENSE](LICENSE)。附带的 `web\echarts.min.js` 为 Apache ECharts（Apache License 2.0）。

---

## English summary

Zero-dependency PowerShell tool that measures TCP connect latency and loss from your machine to Oracle Cloud (32), AWS (34) and Azure (8 Asian) regions, stores results in a CSV, and serves a local-only web dashboard (run tests with live progress, ranking table, region × hour heatmap, trends, raw details, forward/return path tracing). Optional hourly Windows scheduled task. Start with `启动测速网站.cmd`; personal settings go in `config\config.psd1` (see `config.example.psd1`). UI text is in Chinese.
