# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Packaging

- **macOS 发布产物由 zip 改为 DMG**：新增 `scripts/package-dmg.sh`，用 hdiutil
  生成 UDZO 压缩 DMG，根目录放 `SwitchMTP Batch.app` 与 `/Applications` 软链
  （标准拖拽安装布局，无背景图定制），附带 `.sha256`，挂载后跑
  `codesign --verify --deep --strict` 校验；架构标签由主二进制的真实切片自动判定。
  Release 工作流、README 安装步骤与归档约定同步改为 DMG；不再并行产出 zip。

### Docs

- 开发期的 AX / 真机 / 压力测试等内部调试记录、取证截图与对照表不再随仓库
  发布；对外文档只保留安装、排障、协议与 CLI 说明。

### CLI

- **两个命令行产物更名为与产品名一致的名字**：macOS 内嵌 Swift CLI
  `switchmtp-cli` → `switchmtp-batch-cli`；跨平台 Go CLI（源码目录
  `backend/cmd/switchmtp/` → `backend/cmd/switchmtp-batch/`）二进制
  `switchmtp` → `switchmtp-batch`。Linux deb / Arch 包名、udev 规则文件名、
  CI 产物与命令示例、文档与 triage 关键词同步更新；bundle id、队列名、偏好键、
  临时文件名等内部标识保持不变。

## 1.7.21 — 2026-11-27

### CLI

逐项复核上游 Go CLI（`backend/cmd/switchmtp/`）后补齐并修正 Swift CLI。

- **对齐上游**：存储选择器按 数字 id → kind 别名 → 显示名精确匹配 → 唯一前缀 解析，
  歧义报错不猜测；`ls -R` 递归、目录优先排序与底部统计；`rm` 多路径/同存储/只读/根保护；
  `mv` 跨目录跨存储拒绝与新名校验；`install --sd/--nand`（长短横线）与本地文件/扩展名
  预校验；全局 `--quiet/-q`、`--yes/-y`；`version --json` 带 os/arch；`storages`
  FREE/TOTAL 容量列；`get` 下载前读能力校验；路径规范化对齐 `path.Clean`。
- **修正偏差**：`mv` 接受完整设备路径作第二个参数（原先被斜杠校验误拦）；`rm` 同存储
  比较大小写不敏感；单源下载前创建本地父目录并展开 `~`；`install` 本地缺失退出码由
  usage(2) 改为 error(1)；`ls` 无时间戳条目显示 `—`。
- **信号处理**：新增会话级 `SignalGuard`，监听 SIGINT/SIGTERM，首次信号取消在途传输，
  二次信号以退出码 4 强制退出；原先仅传输路径监听 SIGINT。
- **格式口径**：字节容量由二进制 1024 改为十进制 1000（kB/MB/GB…），对齐 DBI/SD 厂商；
  进度行文件序号优先 `currentFile`，indefinite 阶段显示 note/working，补 bulk 估算 ETA，
  汇总耗时用紧凑 h/m/s 格式。
- **随包嵌入**：universal `switchmtp-cli` 编入 `Contents/Resources/bin/`，复用宿主
  `Contents/Frameworks/` 的 nxmtp/libusb（不重复打包 dylib）；终端可直接调用，版本号读宿主
  Info.plist；CLI 用独立非沙盒 entitlements 签名。
- 离线健壮性回归 41 passed / 0 failed。

### GUI

- **侧边栏安装区改为跳转批量清单**：侧边栏不再直接发起安装；点选或拖入的文件/文件夹
  连同目标存储一起交给批量工作区，预选目标后在清单里复核、勾选再发送 DBI。
- **抽取无 UI 批量核心层**：扫描、本体/更新/DLC 分组、深度检查移到 `Core/`，GUI 与 CLI
  共用同一套模型与校验逻辑。
- **恢复深检行内进度条**：批量深检改为并发 runner 后，启动时漏了把队列任务置为
  `.running`；行内条的显示条件是 `deepState != .notRun`，导致运行过程中进度条与百分比
  完全不出现，要等结果回来才蹦出满条。现在任务入队即标 `.running`，行内条与百分比随
  引擎实时进度填充，结束后停留为结论色满条。
- **修复「导出 CLI 使用指南」失败**：导出按钮去 bundle 里找从未打包的 `CLI_USAGE.md`，
  必然报「在应用程序包中找不到」。现把 `docs/CLI.md` 作为资源编入 bundle，导出读取它。
- **更新检查区分「暂无发布版本」与网络失败**：私有仓库对匿名 API 返回 404、或仓库还没
  切 GitHub Release 时，原先一律标红「检查更新失败」。现在 404 / 无 release 归为灰色
  「暂无已发布的版本」；只有真正的网络或服务器错误才报失败。

### 清理

- 删除上游旧名时代、与现行工程脱节的构建残留：`scripts/build-app.sh`、
  `scripts/package-dmg.sh`、旧工程 `app/SwitchMTP.xcodeproj/`、旧
  `app/Resources/SwitchMTP.entitlements`、`app/project.yml.upstream-backup`。
- 文档、CI 与 `scripts/hw-validate.sh` 的默认路径对齐现行 `build-xcode-app.sh`
  产物 `SwitchMTP Batch.app`（CLI 在 `Contents/Resources/bin/switchmtp-cli`）；
  GitHub Release 流水线由 DMG 改为 zip 打包。Go CLI 的 Linux deb/Arch 打包链路保留。

### 署名与仓库

- 仓库坐标迁移到 `xiaolizi23/SwitchMTP-Batch`：问题反馈、更新检查、帮助菜单、
  issue 模板、workflow 仓库守卫、triage 脚本、deb/Arch 打包与文档中的仓库链接一并更新；
  Go module path 改为 `github.com/xiaolizi23/SwitchMTP-Batch/backend`。
- 作品级版权追加 `Copyright © 2026 xiaolizi23`（README License、About 面板、
  Info.plist、THIRD_PARTY 变更声明）。按 GPL-2.0 保留 Neighbor_Z、fratei 的上游
  版权行与全部第三方 attribution；bundle ID 沿用上游以兼容已安装配置。
- 面向用户的可见文案与帮助文档统一更名为 SwitchMTP Batch：帮助菜单标题、USB 连接
  说明弹窗、设置页品牌、诊断提示、主窗口状态提示及各语言本地化同步；上游溯源句与
  第三方作品名原样保留。

## 1.7.20 — 2026-11-26

数十包全量深检 × DBI 实机对照后，收敛深度检查的判定口径：能说清的精确到层，
说不清的一律降级表述。

- **IVFC 层级精确化**：`NCACheck` 新增 `failedLevels`，从引擎输出解析具体的
  `Level N (FAIL)`。note 文案由「RomFS 层级表不一致」改为「仅 IVFC Level N 不符
  （其余层级与 Superblock 均通过）」。区分 Level 4（文件级内容被动过）和
  Level 0（分块表本身坏了）——前者通常仍可正常玩，后者装上会报 CRC，风险等级不同。
- **密钥代重试保留证据**：`NSP_NCA_RETRY` 旧逻辑重验成功后整块重建 check，把
  「按 ticket 报的 keygen 首次验失败」这个事实抹掉；现在保留原 check、只清判定位，
  note 写明「已按内容实际密钥代重验（18 → 17）」。明文与实测密钥代不一致本身是
  转换包/非官方重打包的诊断线索，不能丢。
- **BKTR 补丁分区标 `partialHash`**：遇到 `invalid bktr layout` 时置位，包级新增
  note「补丁分区未做内容遍历」，主 note 的哈希计数改为扣除补丁分区的全量通过数。
  13 个带补丁分区的更新包不再被表述成「全量哈希通过」，改为「部分覆盖」（颜色仍绿：
  签名全过、主体分区哈希全过）。某个更新档 实机 DBI 4 NCA 签名全 OK、
  16 秒装完，证实补丁分区未遍历不等于有风险，只是本地没证据。
- 全量复扫 数十包 / 约百 GB / 14.0 分钟：39 绿、3 黄、2 灰、0 红，与 1.7.17
  基线逐项一致。两个「灰」（智慧再现本体、空前盛会本体）确认是「仅 IVFC Level 4
  不符 + 无 CNMT 清单可对照」，继续按证据不足处理，不冒充绿。
- 补完的真机结论（**已更正**）：**某本体本体 NSZ 装得上、能启动**。上一版这里写的是
  「DBI 报完成但没落地」，那是取证错误：DBI 的 MTP responder 启动时建目录树、装完不
  刷新，装完立刻 ls 读到的是旧表；内置 `Contents/registered` 的目录名是序号
  （`00000000`…）且内容经 MTP 读为空，拿它 grep NCA id 等于空扫。重启 responder 后，
  `65540` 与 `InstalledApplications.csv` 里都有 `01000000000AF000`。
  **口径：落地核查只认重启 responder 后的 65540 + 新生成 CSV，或主机 UI 截图。**
- BKTR 全量遍历试到根因后放弃：hactool 的 `Invalid BKTR layout` 是尾部 0x4200
  字节导致的误报，但放宽后仍因缺 titlekey 整个分区读不出来（`Titlekey: Unknown`）。
  13 个更新包继续标「补丁分区未遍历」，源码改动已回滚。
- 版本 `1.7.20` / build 44。

## 1.7.17 — 2026-11-26

修正 1.7.15 的过度改动：组名恢复中文优先，只有包行保持英文。

- **组名**：简体中文 → 繁体中文（转简体显示）→ 英文，三级兜底，和 1.7.14 一致。
  1.7.15 把组名也换成了英文、并删掉中文库下载，界面变成整片英文。
- **包行**：继续用英文官方名，和组名分开；后缀统一小写 `-update`、`-dlc1`、`-dlc2`
  （1.7.16 的 `-DLC1` 大写改成小写，和 `-update` 同一种样式）。
- 中文库恢复后台加载，工具栏回到「正在下载官方中文名称库…」进度提示；英文名请求
  不再等中文库，包行先出英文，组名随后换成中文。
- 版本 `1.7.17` / build 43。

## 1.7.16 — 2026-11-26

批量清单的包行后缀改成更紧凑的写法，把标题宽度让给游戏名本身。

- **本体**：保持组名原样，例如 `Sample Game`。
- **更新**：`<组名>-update`；同一组有多个更新时依次 `-update1`、`-update2`。
- **DLC**：`<组名>-DLC1`、`-DLC2`…，按组内顺序编号。
- 1.7.15 用的是 `Sample Game · Add-on 1`，空格加中点占掉一截宽度，长标题在 890
  宽的清单里更容易被截断；新后缀更短，主标题能多显示几个字符。
- 版本 `1.7.16` / build 42。

## 1.7.15 — 2026-11-26

批量清单的游戏名统一成英文官方名，不再中英混杂。

- **组名英文优先**：`titleNames[id] ?? 文件名`。之前是中文名库优先，为此要下载 16MB 的
  `CN.zh.json` / `HK.zh.json`，下载期间界面还挂着「中文名加载中」。
- **包行标题同源**：新增 `BatchInstallModel.displayTitle(for:)`，包行、详情面板、组详情
  成员清单、确认安装表都用组名做标题；同组同类型多个包追加 `· Base/Update/Add-on N`，
  例如 `Sample Game · Add-on 1`。
- **移除中文名库**：删除 `startCatalogLoad()`、`catalogReady` 等状态与界面提示，不再下载
  中文库；`requestMissingNames()` 对所有缺英文名的组发请求，命中 `CatalogNames.json` 缓存。
- 已知边界：目录未收录的 title 回退文件名（可能仍是中文）；无缓存首次运行会逐条异步替换，
  十几秒内补齐。记录见 `docs/ENGLISH_TITLE_NAMING_2026-11-26.md`。
- 版本 `1.7.15` / build 41。

## 1.7.14 — 2026-11-26

批量清单组行的点击语义调整：单击只选中，展开改到双击或箭头。

- **点整行不再展开**：1.7.13 的一次点击同时选中并展开，导致小三角失去独立意义，
  浏览组详情时列表还会在指针下重排（数十包的长清单滚动位置会跳）。现在单击行只
  选中并显示组概览；双击行才展开/收起；点箭头只展开、不改变选中，三种意图分开。
- AX 回归脚本跟随更新：默认仍 24 PASS / 2 SKIP（点击语义两项因行本体无常驻 AX
  action 而跳过，用箭头覆盖展开/收起）；`AX_TEST_HID_CLICKS=1` 下以单击 / 双击
  验证完整交互，25 PASS。记录见 `docs/GROUP_ROW_CLICK_SEMANTICS_2026-11-26.md`。
- 版本 `1.7.14` / build 40。

## 1.7.13 — 2026-11-26

批量安装清单从 `List` 换成可自动化点击的自绘滚动栈，并把之前一串测试版（1.7.12-ax
～1.7.19-ax）的改动合并进这一版。功能、判定口径、模型与 USB 后端均未改。

- **清单容器**：`List + DisclosureGroup` → `ScrollView + VStack`。`List` 的行在 AX
  树里是 `AXRow`/`AXCell`，电脑操作后端会把行内的复选框吞进行描述，无法逐项点击；
  换成普通容器后每个复选框都是独立 `AXButton`（`package-checkbox-<UUID>`），整组框
  是 `group-checkbox-<id>`，箭头是 `group-expand-<id>`。实测点一次 44/44 → 43/44，
  组框同步 1/2。代价：VoiceOver 失去表格行语义；≤200 行全量进视图树，超过才切
  `LazyVStack`。
- **视觉与 1.7.12 对齐**：分隔线（组行 92pt、包行 79pt 起，右端随列宽伸缩）、行首
  缩进（12.5 / 34.5 / 46pt）、箭头位置、搜索栏位置逐点实测，截图差异折叠态 0.03%、
  展开态 0.02%，全部落在箭头抗锯齿边缘。
- **折叠态点组行看组概览**（新增）：右栏显示封面、名称、Base Title ID、勾选合计、
  成员清单，以及「在 Finder 中显示 / 移除此组」。
- **点组行同时展开**：一次点击既选中又展开，再点收起，和 Finder 大纲行一致。
- **选中底纹**：包行恢复 1.7.12 的 10% accent 浅蓝；组行新增同深度的中性灰（8% 纯黑，
  实测 `(238,238,238)`），两种选中一目可分。
- **窗口**：主窗口下限 1000 → 1010×620；批量窗口默认 880×520 → 890×520（890 是筛选栏
  不被裁的下限），首次打开按父窗口推导并居中体现层级，之后可自由缩放、允许超过主窗口；
  可读性下限 890×498（470 内容 + 28 标题条）。
- **测试夹具保留**：`SWITCHMTP_BATCH_TEST_FOLDER` 预载本地文件夹冒充清单，仅环境变量
  存在时生效，生产构建不受影响；夹具模式不再抑制主机在场探测。
- **AX 回归**：`scripts/ax-scroll-list-test.swift` + `scripts/run-ax-scroll-list-test.sh`，
  25 用例 PASS 25 / FAIL 0。
- **真机回归（2026-11-26 20:37，DBI 标题模式 / USB 2.0 High Speed / SD 剩 剩余空间）：**
  数十包 fixture → 只勾「Another Game 空前盛会」更新包 69.8 MB → 深度检查 1 项判绿（签名 +
  哈希通过）→ 确认页「1 项 / 已验证原版 1」→ 发送 → DBI 屏幕全绿：magic OK、tik OK、
  4 个 nca 传输 + 签名全 OK、旧文件删除 3 个 OK、写盘 OK、4 次内容注册 OK、建库建游戏 OK，
  「Установка игры завершена」，总耗时 6 秒。证据 `docs/dbi-install-1.7.13-2026-11-26.png`、
  深度检查截图 `docs/deep-check-1.7.13-2026-11-26.png`。
- 版本 `1.7.13` / build 39。

## 1.7.12 — 2026-11-26

- 改为「只读发现 + 点击连接」：启动只通过 IORegistry 显示 Switch（不打开设备），点插头才取租约、扫描并连接；占用提示出现在点击时，避免多副本互相 reset。
- 多副本抢 Switch 导致 nxmtp panic：新增进程间设备租约（flock），只有持锁实例碰 USB，其余显示“设备被另一个实例占用”并在其退出后自动接管。

## [Unreleased]

### Changed

- **AX 回归默认零侵入。** 合成键盘 / 鼠标从 `.hidSystemState` + `.cghidEventTap`
  改为 `.privateState` + `postToPid`，事件只投给被测进程；删除 `activate()` 与
  `kAXRaiseAction`。默认跑 24 PASS / 2 SKIP / 0 FAIL，整轮光标零位移。
- 搜索框清空改用逐字符 delete：⌘A 是需要 key window 的菜单快捷键，后台投递无效。
- TC8 行点选（8.2/8.3）默认 SKIP：AppKit 不把投递的鼠标事件路由进窗口内容；
  需要时用 `AX_TEST_HID_CLICKS=1` 恢复原 HID 路径（会移动真实光标，25 PASS）。

## [1.7.11] - 2026-11-26

### Changed

- **硬损坏判定加存疑护栏。** 哈希 FAIL 先分层：superblock / hash table FAIL、`hash mismatch` 记硬损坏；IVFC level 表 FAIL 单独降级“内容无法确认”。判红前先排查解密存疑旁证——密钥代未知、或整包标题密钥未派生（`registered=0` / 同包有缺密钥 NCA）时，哈希 FAIL 降级为“无法确认”，不直接判红；只有密钥代已确认、仍与清单哈希对不上的才判红。CNMT SHA-256 逐字节不符、结构损坏（`is corrupted`）仍维持红色。

## [1.7.10] - 2026-11-26

### Added

- **XCI 卡带镜像支持逐 NCA 深度验签。** 引擎遍历 XCI secure 分区的 HFS0 条目，复用 NSP 同一条 NCA 签名 / 哈希校验通路；深检对 `.xci` 也调用引擎并解析逐 NCA 结论。无 ticket 的 XCI 不再只验容器头，结论不再等同于“未验签”。

### Fixed

- **修复超大 NCA 因 titlekey 代次重试被跳过而离线误判红。** 包内 ticket 用某一代 titlekek 包裹 titlekey、NCA 内容实际用另一代加密时，引擎本会按 NCA 头代次重试一次；早先重试触发条件带 8GB 尺寸上限，11GB 的 某本体 本体超线被跳过，错误密钥一路解成乱码、哈希全 FAIL 被判红。去掉尺寸上限后，大包换代次重解密校验即可通过。

### 备注

- 本轮未改动红 / 绿判定主逻辑。

## [1.7.9] - 2026-11-25

### Changed

- **勾选控件对辅助功能 / 自动化友好。** 列表行与分组头的勾选按钮补上无障碍标签、选中状态值、按钮角色和稳定标识（`package-checkbox-*` / `group-checkbox-*`），行容器保留子元素独立可访问。之前自定义 plain 按钮在无障碍树里不单独暴露，自动化只能点到整行的详情选中手势，勾不到最左的选框。
- **提示文案分层：把“证据不足”和“确认损坏 / 非官方”分开。** 缺 ticket、无法确认标题归属这类本机核对不到签名/授权的情况，从橙色“注意”降为中性待确认，不再借用“非官方”颜色；未验签 / 待确认项明确标注“证据不足、不代表文件损坏，最终以 DBI 实机结果为准”。行提示与安装确认页文案同步调整。

### 备注

- 本轮**未改动红 / 绿判定逻辑**：某本体 本体在离线 hactool 报内容分区哈希 FAIL，但 DBI 实机全 OK 落地、未回滚；根因（超大 RomFS IVFC 遍历 / body key 派生 / DBI 校验覆盖面）待进一步复核。

## [1.7.8] - 2026-11-25

### Fixed

- **主窗口缩回 900×450，批量安装窗口把主窗口整个盖住。** 根因是主窗口放大只做了一次性 seed（`batch.windowSeedApplied` 早已置位，之后不再纠正），而窗口 frame 又被系统自动恢复成上游默认 900×450；批量工作区固定 880×520，打开即覆盖。现在主窗口 frame 每次启动强制不低于 1000×620：设好 `contentMinSize`、把恢复出来的小 frame 撑回（保持左上角并夹在屏幕内）、并在窗口被改小时兜底纠正；打开批量工作区前再校正一次父窗口。批量工作区尺寸改为从父窗口 frame 推导，限制在父窗口 −120/−100 以内，并通过代理在窗口缩放时兜底 clamp。
- **窗口尺寸常量统一。** 新增 `Views/WindowMetrics.swift` 作为唯一尺寸来源，全部按 window frame 计算，避免 content / frame 两套坐标混用（之前按内容区写 1000×620 会把窗口抬到 1000×672，且下限时灵时不灵）。

## [1.7.7] - 2026-11-25

### Fixed

- **修正组复选框三态判定。** 含阻止项的组，只要还有成员勾不上，外层就保持横杠，不再出现「全选对勾」；只有全组成员都勾上才显示对勾。横杠与按结论着色的区分保留。勾选动作仍只作用于可勾成员：点横杠取消可勾项，再点方框重新勾上可勾项。

## [1.7.6] - 2026-11-25

### Fixed

- **组勾选 / 全选不再把检查未通过的项目带勾。** 之前点组头的复选框（或「全选」）会把整个组连同红色阻止项一起设为勾选，需要再靠底部警告拦安装。现在阻止项不参与组三态计算、不可被勾选；组内没有可勾选项时复选框置灰。模型层另加了 `isSelectable` 双保险，手动切换路径同样落不到阻止项上。

## [1.7.5] - 2026-11-25

### Fixed

- **去掉重复的「内容无法确认」备注。** NSZ 解包后校验时，NSP 校验层已生成过一条「内容无法确认」，NSZ 合并层又按 flagged NCA 重新插入了一条，详情页因此出现两条一模一样的警告。现在合并时先丢弃内层同名备注，只保留一条。

## [1.7.4] - 2026-11-25

### Fixed

- **修复勾选状态错乱。** 点复选框后界面不刷新、想再勾也勾不上；整批检查完后积压的翻转一次性冒出来，表现为别的游戏被自动取消勾选。根因是勾选只写回主数组、没有同步到列表渲染用的分组快照。现在单选、整组勾选、全选/全不选、仅可选都实时同步主数组与快照，点击即刻生效。

### Changed

- **验签进度按 NCA 字节数加权。** 原先按完成 NCA 个数计数，几 KB 的 CNMT 和几十 GB 的 RomFS NCA 算一个单位，导致小文件连跳、大文件长时间停顿。现在按已校验字节 / 总字节计算进度，曲线更平滑；结构检查拿不到条目大小时回退按个数计数。单个大 NCA 内部引擎不输出子段进度，校验期间进度条仍会短暂停住，这是校验引擎的粒度限制。

## [1.7.3] - 2026-11-25

### Changed

- **深度检查按钮恢复为普通按钮。** 上一版改成的下拉菜单（待查项 / 重新检查全部）撤回；按钮默认只跑尚未检查的项目。需要整批复检时，清空列表重新扫描后再点一次即可。

## [1.7.2] - 2026-11-25

### Fixed

- **列表行图标与进度条对齐。** 图标位原先没有固定宽度，进行中 / 已验证 / 未验签三态的图标数量和字形宽度不同，右侧整组图标左右漂移；现在两个图标位都预留固定 18pt 槽位，纵向对齐。
- **进度条每行等长。** 左侧文本列原先按最长文字收缩，进度条宽度随文字长短变化；现在文本列撑满剩余空间，各行进度条长度一致。
- **去掉进行中重复的「待定」圈。** 深度检查运行中，主图标位原来同时显示「待检查」虚线圈和沙漏，两者都表示进行中；现在主图标位直接用沙漏，第二槽留空，不再出现含义重复的双图标。

## [1.7.1] - 2026-11-25

### Fixed

- **已深度检查过的项目不再被重复校验。** 之前点「深度检查」会把所选（或全部）项目从头再跑一遍，哪怕上一轮已经出结论；现在默认只检查尚未跑过的项目，新加进来的文件夹只验新增部分，已出结论的标题直接复用缓存结果。
- **更换 / 移除 prod.keys 时作废旧结论。** 旧密钥下得出的签名判定不能套用到新密钥上，切换密钥后缓存的深度状态与逐 NCA 结果会清空，要求重新校验。
- 深度检查按钮改为菜单：「检查待查项（N）」只跑未检项目；「重新检查全部（忽略已有结论）」用于强制复检整批。

## [1.7.0] - 2026-11-25

### Added

- **深度检查逐文件即时出结果。** 以前要等整批文件全部校验完才一次性刷新列表；现在单个文件校验结束就立刻更新该行的结论、颜色与详情页内容，不用干等整批跑完。
- **行内细进度条。** 检查中按强调色随真实进度填充，跑完后进度条保持满格并按最终结论着色：绿=签名与哈希通过，青=仅签名通过，橙=非官方签名 / 无法确认，红=内容或结构损坏。
- **详情页显示阶段与百分比。** 「深度检查」一行在检查中显示「解包中 / 验签中 + 百分比」，结束后回到结论文案。
- **进度全部来自引擎真实标记。** 百分比按已完成 NCA 数 / NCA 总数、已解包条目数 / 总条目数计算；引擎没有给出数量时不虚构进度。NSZ 拆成两段：解包占前 60%，解包后逐 NCA 验签占后 40%。

### Changed

- 校验引擎（hactool / nszunpack）的输出从「跑完读临时文件」改为 Pipe 流式按行读取，供进度回调实时计数；最终结论的解析口径不变。

### Fixed

- **修复列表行状态缓存导致的「最后才出结果」。** 列表渲染用的是分组快照副本，单条检查结果只写回了主数组，快照要等到整批结束 `rebuildGroups()` 才更新；现在单条更新会同步镜像到所属分组，结果随算随显。

## [1.6.2] - 2026-11-25

### Fixed

- **x86（Intel / Rosetta）上真正的零售签名不再被判 FAIL。** 根因不在解包，而在 vendored mbedtls 2.6.1 的 x86_64 内联汇编 `MULADDC`：同一个模数、同一个签名字节，`s^e mod n` 在 arm64 与 x86 上算出不同结果。已在 `mbedtls/config.h` 关掉 `MBEDTLS_HAVE_ASM` / `MBEDTLS_AESNI_C` / `MBEDTLS_PADLOCK_C`，走纯 C 大数路径；实测两架构模幂逐字节一致，`Fixed-Key Signature (GOOD)` 数量相同，翻转签名一字节两边都变 `FAIL`。
- **内置 hactool 恢复为通用二进制**（arm64 + x86_64，各编一遍后 lipo）。`scripts/build-hactool.sh` 默认就是 universal。
- **去掉 Intel 的降级分支**：`DeepVerifier` 不再对 x86 返回“引擎只有 arm64 / 解包但不判绿黄”。现在 Intel 上 NSP、NSZ 都走与 Apple Silicon 完全相同的验签路径，结论一致。


## [1.6.1] - 2026-11-25

### Fixed

- **Intel（x86_64）上也能解包 NSZ 了。** `nszunpack` 现在是 arm64 + x86_64 通用二进制：解压与 AES-CTR 重加密在 x86 下跑出来的 NSP 与 arm64 逐字节相同（SHA-256 相等），某更新包 v1.1.6、Sample Game 更新（417 段 + 块压缩）都是 CNMT 4/4 一致。
- **Intel 上不再给假签名结论。** 内置 `hactool` 的 x86 构建会把真实零售签名报成 FAIL（同一文件 arm64 是 GOOD，问题在 vendored mbedtls 的 RSA 验签路径）。应用在 x86 进程里明确不做签名判定：NSZ 走“已解包 + 与 CNMT 清单逐字节对照”，NSP 则直接说“内置引擎只有 arm64”。


## [1.6.0] - 2026-11-25

### Added

- **NSZ 能解包了，而且解完还要自证。** 新增 `tools/nszunpack`（单文件 C，链接 vendored mbedtls 与 Homebrew 静态 zstd）：把 NCZ 的 zstd 正文解出来，按 section 记录的 key/counter 用 `IV = counter[0..7] || BE(offset>>4)` 重做 AES-CTR，写成一个可直接安装的 NSP。写完还会把每个重建 NCA 的 SHA-256 和包内 `.cnmt.xml` 的 `<Id>/<Hash>` 对照，打印 `NSZ_HASH ... match=yes`——这是「解出来的字节就是发行方签过名的那份」的直接证据。
- **多 section 与块压缩都支持。** 更新包的 NCZ 常有几百个 section（Sample Game 更新 417 个、某个更新包更新 692 个），并带 `NCZBLOCK`（1 MiB 一块、每块一条 zstd frame，压不小的块原样存放）。旧的固定 16 条 section 上限和「块压缩不支持」都已去掉。
- **深度检查对 NSZ 全自动。** `DeepVerifier.verify` 遇到 `.nsz` 先解包到临时目录，再按 NSP 逐 NCA 验签，最后把 hactool 的结论和 CNMT 哈希证明合并成一条结论；校验完删除临时文件。界面详情页新增「解包为 NSP…」，可自己选保存位置。
- **`docs/NSZ_UNPACK.md`**：NCZ 头结构、重加密规则、14 个真实 NSZ 的测试矩阵与已知限制。

### Changed

- **hactool 的密钥代重试上限从 64 MB 提到 8 GB。** NSZ 解包后是按 NCA 头里的密钥代重新加密的，大 NCA 恰恰是「ticket 代次写错」最先暴露的地方；旧上限会让 5–6 GB 的本体被误报成「内容不符」。
- **BKTR 补丁分区**不再只是「没能读出结论」：hactool 跳过这类分区时，详情里会明说原因。

### Fixed

- 解包工具在输出目录不存在时会静默写出 0 字节（`fopen` 失败未检查）；现在自动 `mkdir -p` 并在失败时报 `NSZ_ERROR`。


## [1.5.0] - 2026-11-25

### Fixed

- **ticket 密钥代写错的包不再被判红。** 重打包工具常见做法是把内容用某一代 titlekek 包出来，却在 ticket 的 `masterKeyRevision` 里写另一代（马车 8 DLC 就是 ticket 写 13、内容实际 12）。现在逐 NCA 验完后若哈希 FAIL、且 NCA 头的 `crypto_type` 与 ticket 代次不同、NCA ≤ 64 MB，就按 NCA 头的代次重新解密钥再验一次；`nsp.c` 打印 `NSP_NCA_RETRY: keygen 13 -> 12`，Swift 侧据此丢弃作废的第一次结果。大 NCA 不做重试，真实损坏（如 某样本 重打包）仍稳定判红。
- **真机颜色对照测试**（`docs/DBI_COLOR_TEST.md`，截图在 `docs/dbi-color-test/`）：绿 = 签名与哈希全过，DBI 逐文件 `[ПОДПИСЬ: OK]` 并注册成功；黄 = 签名 `ПОДДЕЛЬНАЯ`，DBI 照装不误；红 = 内容 `CRC ОШИБКА ФАЙЛА`，DBI 会把内容回滚删除（虽然仍打印“安装完成”）。我们的三色语义与 DBI 的实际行为一致。

### Changed

- **The colour now means what DBI means, and it is earned instead of assumed.** 可装性（结构/内容哈希）与官方性（RSA 签名）拆成两条轴：绿 = 两者都验过（`passed`，实心 seal），空心绿 = 结构正常但签名/哈希没验（`unverified`），黄 = 签名不是零售链、需要 sigpatch（`caution`），红 = 装不了（结构损坏或内容哈希不符）。装前快速预检不再把“结构干净”冒充成绿——那正是主机上绿灯翻黄的来源。
- **`hactool` 现在真的会打开 NCA。** 原版 `-t pfs0` 只列文件，深度检查因此对任何 NSP 都只能是“无结论”。补丁新增 `-t nsp`：遍历 PFS0、逐个 NCA 原地验签名与哈希，并从包内 `.tik` 解出标题密钥（`--titlekeys` 仍可用）。个人化票据与缺票据会被标成“未验签”，不会再被误判成内容损坏。
- **深度结论并入主色。** 哈希不符 = 红、签名非官方 = 黄、密钥不足 = 未验签；修掉了旧逻辑里“深度失败但颜色不变”的 bug。详情页新增逐 NCA 的签名/哈希清单。
- **开始安装前先验。** 没跑过深度检查的勾选项会在出确认页之前自动补跑；确认页按四档计数，出现未验签或非官方内容时必须手动勾选“我已知晓”，空间不足会直接写出来。

## [1.4.2] - 2026-11-25

### Added

- **A failed install retries itself instead of stalling the batch.** Each file
  gets three uploads (`InstallRetryPolicy`). The decision is a pure function, so
  the "retry vs write off" rule is unit-tested rather than inferred.
- **A failed upload now resets the MTP session instead of parking in `.error`.**
  DBI's session is what breaks when it rejects a title; `dispose` + reconnect
  fixes that, and the queue resumes by itself. Before this, one bad title left
  the whole queue stopped until the cable was replugged.
- **The queue survives quitting the app.** Pending items are written to
  `~/Library/Application Support/SwitchMTP Batch/InstallQueue.json` (path,
  storage kind, attempts) and restored at launch; the first unsent file is
  picked up when the console connects. Files that moved or vanished are dropped
  from the restored list with a log line.
- **A liveness probe reconnects when USB notifications cannot.** The USB monitor
  only speaks up when the port re-enumerates, so a console that stopped
  answering MTP without re-enumerating stayed lost. A 5 s scan covers that case.
  The probe also re-arms the state after a failed open (a busy port used to park
  the app in `.error`, which auto-connect never leaves), and forgives the three
  auto-connect attempts after a 30 s cooldown, so a console that was merely busy
  comes back without a manual click. A Disconnect pressed by the user is
  respected; only an explicit Connect or a replug brings the console back.

### Changed

- **The workspace stays open after a batch is sent.** Confirming a batch no
  longer closes the window and empties the list: files are marked "已交给 DBI",
  deselected so a second Send cannot resend them, and counted in the footer.
  “清除已发送标记” puts them back in rotation for a re-install.
- **The transfer bar shows queue notices** (restored items, retry in progress),
  separately from the error banner, so recovery never reads as a failure.

## [1.4.1] - 2026-11-25

### Fixed

- **The install plan no longer reorders a title's own files.** `makePlan()` used
  to sort the whole selection in one pass: `displayName` across titles, but
  `sortRank` inside them. Those two rules together are not a valid ordering and
  can form a cycle, so the sort was free to emit an update before its own base —
  which DBI then rejects. Selection order is now built in two explicit levels:
  titles are emitted as whole blocks (ordered by official name, then group key),
  and inside each block the order is base, update, add-ons, unknown. A title
  with no catalogue name uses the alphabetically-first file name as its block key,
  so the same folder always produces the same plan.

### Added

- **Traditional names are now shown in Simplified script.** The reachable Chinese
  catalogue is the Hong Kong one, so most rows came out as 瑪利歐賽車8 豪華版.
  Display now runs the name through a local conversion table
  (`Resources/T2S.json`, OpenCC derived, ~60 KB, no network):

  * franchise phrases first — 瑪利歐 -> 马力欧, 瑪利歐賽車 -> 马力欧卡丁车,
    薩爾達 -> 塞尔达, 寶可夢 -> 宝可梦, 動物森友會 -> 动物森友会
  * then OpenCC's single-character map for everything else

  The mainland catalogue still wins when it has the title, so a real
  Simplified entry is never overwritten by a conversion. This is a script
  conversion, not a translation: names whose mainland title differs beyond
  character forms can still read slightly off.

## [1.4.0] - 2026-11-25

### Added

- **Official game names, Simplified Chinese first, then Traditional, then English.**
  Group names used to come from the file or folder on disk, which is how a library
  ended up with rows called “升级档-v1.1.0”. They now come from the same public
  metadata the Windows front-end uses:

  | source | language | size | coverage |
  | --- | --- | --- | --- |
  | `CN.zh.json` (titledb) | 简体中文 | ~260 KB | 109 款（国行目录） |
  | `HK.zh.json` (titledb) | 繁體中文 | ~16 MB (gzip) | 22 628 款 |
  | `api.nlib.cc/nx/<id>?fields=name` | English | ~0.2 KB per title | 全部 |

  Both catalogues are fetched once, reduced to a `title id -> name` table (~1 MB)
  and cached; after that names cost nothing. A title ID can appear under several
  products (base game, base + expansion bundle, Switch 2 Edition), so candidates
  are filtered to the plainest name before being kept. English is requested
  per-title only for the handful the Chinese catalogues do not list.

## [1.3.0] - 2026-11-25

### Fixed

- **Bases and updates no longer masquerade as DLC.** The content type is read from the
  Title ID's low 16 bits: bit 12 set means add-on, `0x0800` means patch, `0000` means
  application. Comparing only against `0x0000`/`0x0800` sent every retail base whose ID ends
  in `2000`, `A000`, `6000` … down the DLC branch, so a whole library came back as
  "DLC only".

- **Title IDs are recovered from ticket names.** Repacks name their CNMT after a content
  hash, and the real Title ID lives in `<title id><zeros>.tik`. Requiring exactly 16 hex
  digits before `.tik` missed every such ticket, which left 44 packages with no Title ID:
  no grouping, no cover art, and a "cannot confirm title" warning on every row.

- **Real retail XCI images are readable.** The root HFS0 offset/size were read from
  `0x140`/`0x148` — those are the header hash, not the fields. hactool's layout puts them at
  `0x130`/`0x138`, so every cartridge image was reported as a corrupt/truncated container.

- **A loose file in the library root no longer inherits the library's folder name.** Release
  tags (`[本体v1.0.0]`, `[0100…]`, `[中文]`, `[US]`, `v1.0.0`, `(0.41 GB)`) are stripped; when
  nothing survives, the nearest meaningful parent folder is used, and as a last resort the
  catalogue name.

### Added

- **Cover art with a real retry story**: four requests at a time, one automatic retry on
  transport errors/429/5xx, on-disk cache so a title is fetched once ever, and a
  “重新获取封面” button in the toolbar that clears failed lookups.

## [1.1.0] - 2026-09-18

### Added

- **Releases now carry Linux artifacts.** Tagging builds the `.deb` for amd64 and arm64
  alongside the macOS DMG, plus a plain `.tar.gz` for distributions with neither package
  format. The Linux jobs run *before* the release is created rather than uploading to it
  afterwards, so a release is never visible in a half-populated state. The tarball's binary
  is extracted from the `.deb` rather than compiled a second time, making the two provably
  identical builds rather than merely equivalent ones.

- **An AUR `PKGBUILD`, covering Arch, Manjaro and SteamOS.** Published as `switchmtp-git`
  rather than `switchmtp`, because the project has no tagged releases yet and pinning a
  PKGBUILD to a tag that does not exist produces a package nobody can build; the file
  documents what to change when the first tag lands. Installs the same binary and udev
  rule as the `.deb`. Its build recipe was run against a real console rather than assumed.

- **A Debian package, so Linux installation is one command.** `scripts/build-deb.sh`
  produces a `.deb` carrying the `switchmtp` binary and the udev rule. A package is the
  right shape for this on Linux for a specific reason: it can install the udev rule, and a
  Flatpak or an AppImage cannot — that rule is the difference between the tool working and
  the desktop claiming the console first. Installing reloads udev so the rule applies
  without replugging, and removing it hands MTP back to the desktop immediately. Built and
  installed on Ubuntu 24.04 arm64 against a real console, including verifying that removal
  restores the desktop's own MTP support.

- **CI now builds and smoke-tests the Linux CLI on arm64 as well as amd64.** The arm64 leg
  is not speculative: it is the architecture the tool has had the most hardware validation
  on, having been built from a clean clone and driven against a real console on Ubuntu
  24.04 arm64, and it was the one architecture CI did not cover. Both binaries are
  published as artifacts.

- **Documented that `switchmtp` and your file manager cannot share the console.** On Linux
  the desktop's own MTP support already browses, reads and writes the Switch with no setup,
  which is worth knowing before installing anything. The two cannot be used in the same
  session though: once `switchmtp` has touched the device, GNOME's cached `gvfs` mount goes
  stale and every write through the file manager fails almost immediately with `libmtp
  error: Could not send object info`. Nothing is lost and a remount fixes it, but it was
  surprising enough to deserve writing down, along with the note that installing the udev
  rule avoids it entirely. Verified against Ubuntu 24.04 with a Switch running DBI.

- **Tests for the Linux process scanner, which had none that meant anything.** The scanner
  that finds gvfs or kio-mtp holding the device reads `/proc`, so on a CI runner with no
  USB devices it took no interesting branch and passed regardless of whether it worked.
  Its logic is now separated from the two paths that are genuinely Linux-specific and runs
  against a synthetic `/proc` fixture, so blocker matching, self-exclusion, unreadable
  processes belonging to other users, missing `comm` files and lookalike device paths are
  all exercised on every platform. Three latent bug classes in the blocker table are also
  pinned: a key with any uppercase character could never match, since lookup lowercases
  first; an entry longer than the 15 characters `/proc/<pid>/comm` reports needs a
  truncated variant or it never fires; and an entry without advice marks a process as to
  blame while saying nothing about what to do.
- **Cross-language drift tests.** A handful of facts exist in both Go and Swift with
  nothing connecting them at build time: the set of installable file types, and the error
  kind the app string-matches to detect a cancelled transfer. The second is the dangerous
  one — that match is what triggers resetting the MTP session after a cancel, and renaming
  the Go constant would compile, pass every other test, and leave the app wedged after the
  first cancelled transfer. Both are now pinned by tests that read the Swift sources and
  fail with an explanation of what will break.
- **A cross-platform `switchmtp` command line tool.** The existing `switchmtp-cli` is
  Swift and macOS-only; this one is Go, links `backend/nxmtp` directly with no FFI, and
  runs on Linux as well as macOS. It covers `devices`, `info`, `storages`, `ls`, `get`,
  `put`, `install`, `mkdir`, `rm`, `mv` and `doctor`, with `--json` output and exit codes
  that distinguish "no device", "cancelled", "device busy" and "bad usage" so scripts can
  react. Device paths are written `<storage>:<path>`, where the storage part accepts a
  numeric id, a friendly name such as `sdcard`, or a unique prefix of the display name;
  an ambiguous name is refused with the candidate ids rather than guessed, because
  guessing wrong could mean writing to NAND instead of the SD card. `Ctrl-C` cancels the
  in-flight MTP operation and closes the session cleanly instead of killing the process
  mid-transaction. CI builds it on Linux, smoke-tests it and publishes the binary as an
  artifact.
- **`switchmtp doctor` reports the Linux udev rule.** It looks for the rule, recognises an
  equivalent one installed by another Switch tool rather than demanding a redundant
  second copy, and prints the exact rule to install when there is none. A test pins that
  printed rule against the packaged `packaging/linux/69-switchmtp.rules` line by line, so
  the two cannot drift apart.
- **The Go backend now builds and is tested on Linux.** Nothing user-visible changes on
  macOS, but the MTP engine was only *theoretically* portable: it would not compile
  anywhere else, because `CollectDiagnostics()` existed solely in a cgo/IOKit file yet was
  called unconditionally, and the libusb cgo directives were macOS-only. Both are fixed,
  and CI now builds and runs the full Go test suite on `ubuntu-latest`. Since the device
  emulator in `backend/fake` needs no hardware, that suite is meaningful from the first
  run — so a macOS-only assumption creeping back into the backend now fails CI in under a
  minute instead of being discovered during a port.
- **Diagnostics understand Linux's version of the `ptpcamerad` problem.** macOS has
  `ptpcamerad` grabbing the Switch; Linux has `gvfs-mtp`, `gvfs-gphoto2` and `kio-mtp`
  doing exactly the same thing. On Linux the app now finds them by scanning `/proc` for
  processes holding a `/dev/bus/usb` descriptor, and names them with specific advice. The
  intuitive fix — `libusb_detach_kernel_driver()` — does not work on these, because they
  are userspace processes rather than kernel drivers; the rule below is the durable fix.
- **A udev rule for Linux**, at `packaging/linux/69-switchmtp.rules`, with an explanation
  of why it is unavoidable. It grants USB access (via both `uaccess` and `plugdev`, so it
  works on Fedora/Arch/SteamOS *and* Debian/Ubuntu *and* over SSH) and clears
  `ID_MTP_DEVICE` for Nintendo's vendor ID so the desktop's MTP handlers never claim the
  Switch. Scoped to Nintendo hardware, so every other MTP device on the system is
  unaffected.
- **Tests for the diagnostics advice.** Previously untested. The priority order is the
  part that matters — a Switch in DBIbackend/Awoo/GoldLeaf mode must be diagnosed as
  "wrong USB mode" and never as "no Switch detected", and "we cannot see USB at all" must
  stay distinct from "USB works, the Switch is not there". Those two pairs send users
  down opposite paths. Now pinned, and they run on both platforms.
- **Tests for the new CLI, run against the emulated device.** Every command is exercised
  end to end — argument parsing, storage resolution, the `nxmtp` call and the output
  formatting — with only the USB layer replaced by `backend/fake`. That includes a full
  `put` → `ls` → `get` round trip verifying the bytes survive. The whole suite therefore
  runs on a Linux CI runner that has never seen a Switch, which is the point: it is what
  turns "the backend should be portable" into evidence.

- **Hover explanations across the app.** Most controls had no tooltip, and the ones that
  did mostly repeated their own label. Toolbar buttons, breadcrumbs, sidebar storages, the
  install drop zone and the install queue now explain what they do — and, where a control
  is greyed out, *why*. A disabled button previously told the user only that something was
  unavailable, never that the fix was to select a file, connect a console, or wait for the
  current transfer; those three cases need different responses and now say so.
- **Tooltips in the file list.** The list is an `NSTableView`, so SwiftUI's `.help()` could
  never reach it: long filenames truncated mid-string with no way to read the rest. Name,
  date and kind cells now carry tooltips, column headers explain that clicking sorts, and a
  file whose date the device didn't report says so instead of showing a blank cell.
- **Settings ▸ General ▸ Write a diagnostic log**, with a button to reveal the log in
  Finder. Transfer failures were previously only diagnosable by knowing to run a
  `defaults write` command from Terminal, so in practice the log was never on when it was
  needed — including for the transfer failure that prompted adding it. The bug report form
  now points at the setting instead of the command.


- **An install queue.** Drop several NSP/NSZ/XCI/XCZ files — in one go or while an install
  is already running — and they are installed one after another, each starting
  automatically when the previous one finishes. The queue is visible, reorderable by
  removal, and individually cancellable.
- **The transfer UI is no longer a modal sheet.** It is now a bar at the bottom of the
  window, so the rest of the app — including the install drop targets — stays usable
  during a transfer. Queueing another install while one is running was previously
  impossible for exactly this reason.
- The app now reports the **install phase** distinctly from the transfer phase. DBI
  installs the title only after the last byte arrives and sends no completion event, so a
  transfer that reached 100% used to look wedged for minutes. The bar now says the console
  is installing, and keeps a live elapsed counter while it waits.
- A **stall notice** appears if no progress has been reported for 15 seconds, alongside a
  Cancel button that is always available.
- **Help ▸ Report an Issue…** opens a GitHub bug report with the app version and macOS
  version already filled in, and offers to copy a diagnostics report to the clipboard
  first.
- Structured issue forms for bug reports, feature requests and compatibility reports, so
  the details that actually determine whether a bug can be fixed — DBI's mode, the
  diagnostics report, reproduction steps — are asked for rather than hoped for.
- Automated issue triage (`scripts/triage`): a rule-based engine, with no model calls and
  no required secrets, that runs daily and on every issue event. It routes and labels
  reports, says precisely what is missing from an incomplete one, answers reports that
  match a documented behaviour, flags likely duplicates, and hands complete, reproducible
  reports to the Copilot coding agent when a token is configured.
- `CONTRIBUTING.md`, `SECURITY.md`, `docs/REPORTING_ISSUES.md` and a pull request
  template.

### Changed

- **The bug report form takes the log and screenshots as file uploads** rather than asking
  for pasted text. Reporters had to open the log, select ~7 KB of it and paste it into a
  textarea, which meant most reports arrived without one. Both fields now use GitHub's
  upload widget with the file types each accepts, and the triage tooling validates the new
  field type. `docs/REPORTING_ISSUES.md` and `docs/TROUBLESHOOTING.md` were still teaching
  the old `defaults write` route and now describe the Settings toggle.


- Uploads and the install queue now record their activity to the diagnostic log. The upload
  path had no logging at all — only downloads did — so a failed install left nothing behind
  to look at. Progress, the phase reported by the console, queue hand-offs and both classes
  of dropped callback are now traceable.

- **The interface is fully localised again.** 116 SwitchMTP-specific strings — the entire
  Switch menu, the install queue, storage capability errors, DBI setup guidance and the
  issue reporter — had only ever existed in English; every translated string in the catalog
  came from the upstream fork. They are now translated into Spanish, Japanese, Russian,
  Simplified Chinese and Traditional Chinese, and `scripts/apply-translations.py` fails if
  any key is left untranslated.
- Free-space labels in the sidebar are built from a single format string instead of gluing
  `"free of"` between two numbers, which could not be ordered correctly in every language.
- Removed the dead Apple Intelligence and AI-provider error messages inherited from the
  upstream fork. SwitchMTP has no AI features, so none of those errors could ever be
  produced; they were only inflating the translation surface.

- **Transfers were stuck on "Preparing transfer…" and never showed progress.** The Go
  backend reports `elapsedTime` as fractional seconds, but the Swift model declared it as
  `Int64`. `JSONDecoder` refuses to coerce `0.4231234` into an integer and rejects the
  *whole* payload, so every single progress update was discarded and the transfer
  statistics stayed empty for the entire transfer — even while DBI on the console visibly
  showed bytes arriving. Verified against a real console: 0 of 15 captured progress
  payloads decoded before this fix, 15 of 15 after.
- Progress decoding failures are now logged instead of being silently swallowed, so a
  future schema drift is visible rather than invisible.
- **Transfer speed was reported roughly a million times too high.** The backend emits
  bytes per second; the app labelled that figure "MB/s" without converting it.
- The file counter read "0 of 1 files" for the whole of a single-file transfer. It now
  counts the file being sent rather than the files already finished.
- An install that failed while waiting for the console to become ready left the transfer
  state marked as still running. It is now correctly reported as failed.
- A failed or cancelled file in a multi-file batch could leave the next file in the batch
  reporting the previous file's status.
- Installs are once again serialised against the console's readiness. The backend only
  waited for the Switch to answer again *between* files of one batch, so sending titles
  one at a time — which is what the queue does — skipped the wait entirely and could hand
  DBI a new title while it was still committing the previous one.
- A console unplugged mid-install no longer wedges the queue. The USB scan that detects
  the unplug resets the transfer state before the transfer's own callback arrives, so the
  running item could stay marked active forever with no way to clear it; every disconnect
  route now releases the queue, and reconnecting resumes anything still waiting.

### Fixed

- **The app could not reconnect to the console until it was relaunched.** Left overnight
  after a transfer, the app retried the connection every ten to twenty-five minutes and
  failed every time, while the Switch sat there plugged in and perfectly healthy. Two
  faults combined. The MTP engine reports a closed USB handle as `device is not open`,
  which reads as neither a disconnect nor a failure the app knew how to classify, so the
  dead session was never evicted and every retry was handed the same dead object. And
  because the connection step answers from cached device information without touching the
  wire, it reported success against that dead object, so the failure only surfaced a moment
  later when the storage list was fetched. Dead sessions are now recognised and discarded,
  and connecting verifies the device actually answers before claiming to have connected.

- **A finished transfer could be reported as stalled.** Stopping the stall watchdog asked
  it to exit but did not wait for it, so it could deliver one last progress event after the
  transfer had already reported completion — and if that event was the one flagged as
  stalled, the interface was told a transfer that had just succeeded was stuck.

- **The Mac could fall asleep part way through a transfer.** Installing a queue of games
  runs for hours with the user deliberately away, and nothing was keeping the machine
  awake: the app took no power assertion at all, so it depended on some other process
  happening to hold one. Sleeping mid-transfer does not just pause it, it leaves the
  console holding a half-written title. The app now holds an assertion for exactly as long
  as a transfer is in flight, the same thing Finder does to copy a file. The display is
  still allowed to sleep, which is what an unattended transfer should permit.

- **The log did not record whether the app noticed a stalled transfer.** Stall detection
  reached the interface but never the log, so a log attached to a bug report showed a byte
  counter creeping forward and gave no way to answer the first question anyone would ask.
  Entering and leaving a stall are now both recorded, with how long the transfer had been
  idle and where it had got to. They are written as transitions rather than as a field on
  every progress line, so the moment it changed is not buried under hundreds of identical
  lines.

- **The diagnostic log could not tell two files apart.** It recorded the name of the file
  being sent through a helper that clipped it to 50 characters for display, and clipped the
  end — which is exactly where a Switch title carries its title id and version. A game and
  its own update therefore appeared in the log under one identical, truncated name, in the
  one artefact used to work out what went wrong after a failed transfer. The log now records
  the full name. The transfer bar is unaffected: it already shortened long names by cutting
  the middle, which keeps both ends readable, so removing the clip improves what is shown
  there too.

- **A long install queue could not be scrolled.** The queue list was a plain stack with no
  height limit, so queueing dozens of titles grew the transfer bar until it ran off the
  bottom of the window, taking the rows at the end with it and leaving no way to reach
  them. Past eight items the list is now pinned to a fixed height and scrolls, and it
  follows the queue as it advances so the title actually being sent stays in view. Shorter
  queues are still laid out at their natural height rather than sitting in a mostly empty
  scroll area.

- **A long install queue made the app burn CPU during transfers.** Every queue row was
  rebuilt ten times a second — once per progress update, for every row — because the row
  carried a closure, and a closure cannot be compared, so SwiftUI had to assume the row had
  changed. Each rebuild recreated a localised tooltip that in most cases was never shown;
  tooltip construction alone accounted for roughly half of each row's render cost. Rows are
  now compared on their contents, so a row is only rebuilt when it actually changes, and
  only the visible portion of a long queue is built at all.

- **A wedged install showed a frozen percentage and no error.** A 3.24 GB title reached 37%
  at a healthy 20 MB/s, then the console stopped draining the USB endpoint. Nothing failed:
  the host stayed blocked inside a libusb write that never returned, so no error was raised
  and no progress callback ever fired again. The app sat on the last percentage it had seen
  for hours, and the log recorded no error of any kind.

  Two things were missing, and the second is the one that actually mattered. A watchdog now
  keeps emitting progress while the byte counter stands still, so a total freeze is visible
  instead of silent. More importantly, movement is now judged by *rate* rather than by
  whether the number changed at all: the console in question was still accepting exactly
  one 16 KiB packet every 80 seconds, which satisfies any "has it moved?" check while being
  about 102 days from finishing. Below 64 KiB/s — some 300 times slower than a healthy
  transfer — the transfer is reported as stalled, with advice to check the console, since
  the host cannot tell an error dialog from a full SD card from applet mode running out of
  memory. Nothing is cancelled automatically; a stall is surfaced, not acted on.

- **Debian package versions could outrank real releases.** `build-deb.sh` decided whether a
  version string needed a `0.0.0+` prefix by checking whether it started with a digit — but
  a commit hash such as `9518481` does, so it was used verbatim, and dpkg ranks `9518481`
  above `1.0.0`. An untagged development build would therefore block upgrading to an actual
  release, and because it depended on the hash it happened for roughly two builds in three.
  The decision is now made on whether git found a tag at all. Builds past a tag are
  versioned `1.2.3+4.gabc1234`, which dpkg sorts above `1.2.3` and below `1.2.4`.

- **`switchmtp rm sdcard:/game.nsp --yes` no longer fails with `"--yes" is not a device
  path`.** Go's flag package stops parsing at the first argument that is not a flag, so
  any global flag typed after the subcommand was handed to the command as though it were a
  file name — and `--yes` after the path is how most people would type it. This was the
  first thing to go wrong when the tool was driven against a real console. Flags are now
  accepted anywhere on the line, and a `--` separator still means everything after it is a
  path, so files whose names begin with a dash remain reachable.


- **A crash when no USB devices are present at all.** The vendored libusb wrapper frees its
  device list by taking the address of the list's first element, which panics outright when
  the list is empty. A Mac always has at least a root hub so this never fired here, but it
  is reachable on any machine with no USB host controller — and it brought down the Go test
  suite the first time that suite ran on a Linux CI runner. The guard now lives in the
  library rather than at each call site, so every caller benefits.

- **Browsing during a transfer froze the progress bar and hung the browser.** Navigating to
  another folder mid-copy left the progress bar stuck at whatever percentage it had reached
  and the file list spinning on "Loading files…" — while the copy itself carried on and
  finished perfectly well on the console. A 6.5 GB import reproduced it exactly: the bar
  stopped at 22%, 2,539 progress callbacks were discarded, and the completed transfer's
  result was handed to the directory-listing code, which could make no sense of it.

  Two separate faults, both now fixed. First, transfers shared a single-slot state machine
  with every other operation, so starting a directory listing overwrote the record that a
  transfer was in flight; every subsequent progress and completion callback was then routed
  to the wrong handler, or dropped. Transfers now own a slot of their own and report through
  their own completion callback, so no other operation can take their place. Second, MTP is
  a single session — the console genuinely cannot list a folder while it is copying, so the
  listing sat waiting for the transfer to release the connection. Rather than appear hung,
  SwitchMTP now says so and opens the folder the moment the transfer finishes.

- **Browsing was effectively dead for the length of an install queue.** Deferring a folder
  listing until the transfer finished was right for a single copy, but a queue of 22 games
  runs for hours and only leaves a third of a second between items, so in practice the file
  list stayed empty the whole time and refreshed only as one install handed over to the
  next. SwitchMTP now remembers the listing of every folder it has visited and shows it
  immediately, saying plainly that this is the folder as it was last seen and that it will
  refresh when the console is free. Every action that would change the console is already
  disabled during a transfer, so nothing can be done to a stale listing.

- **Going to a folder could drop the USB connection for no reason — including
  during a copy.** "Go to folder" and the Favourites list treat an error appearing
  just after the jump as proof the folder is missing, and recover by disposing the
  MTP session and reconnecting. But the check looked at whether *any* error was on
  screen, not whether this navigation caused one, so a message the user simply had
  not dismissed yet was enough to tear down a healthy connection. Worse, it did not
  exclude transfers: a jump made while copying was deferred rather than attempted,
  so nothing had failed, yet an unrelated error in the same half-second would
  dispose the session and abort the copy. Navigation during a transfer no longer
  runs the recovery at all, and the check now only reacts to errors this navigation
  actually produced.

- **A second transfer started mid-copy jammed the queue permanently.** The toolbar's Import
  button correctly greys itself out during a transfer, but dragging files onto the window,
  dragging a file out of it, and double-clicking a file to preview it all reached the
  transfer code directly and bypassed that. Because MTP has only one session, the second
  copy overwrote the record of the first; whichever finished last found no record of itself
  and was discarded, so the app believed a transfer was still running forever and every
  remaining item in the install queue silently stopped. All five entry points now decline
  politely and explain why. Double-click preview in particular had stopped checking for
  transfers at all when transfers moved to their own state slot in the fix above — the most
  likely way to hit this, since it takes one stray double-click while browsing.

- **Pressing Connect with no console attached showed a raw parser error.** The button stays
  enabled with nothing plugged in — retrying after waking the console or starting the
  responder is the normal thing to do — but it passed an empty device id straight to the
  backend, which failed to parse it and put its own diagnostics on screen:
  `invalidInput: parseDeviceId: malformed device id ""`. That is not an answer to "why
  can't it see my Switch", and it was the first thing anyone opening the app before
  launching DBI would have seen. Connect now adopts a discovered console if one turned up
  after the last scan, and otherwise says what to check.
- **The file browser hung on "Loading files…" after connecting.** Clearing the operation
  state machine was moved into the same main-queue block as the follow-up directory walk,
  but it landed *after* the call that arms it. `loadFiles(at:)` claims the state machine by
  setting `operation = .walking`, so clearing it afterwards overwrote that claim, and the
  walk's completion callback was dispatched against `.none` — the listing was decoded,
  matched no case, and thrown away. The browser then span forever against a perfectly
  healthy console. The clear now happens before the walk is armed, at both sites.
- **File ▸ Import (and the rest of the File menu) was greyed out while the toolbar worked.**
  The File menu was built inline in the `App` struct's `.commands { }` from thirteen
  `@FocusedValue` properties. An `App` body is not re-evaluated when a focused value
  changes, so the menu's structural parts kept whatever value was current when the body last
  ran — it offered "Connect Device" against an already-connected console — while the
  sibling `.disabled()` modifiers saw fresh values. The commands now live in a
  `FileMenuCommands: Commands` type, which tracks focused values properly.
- **Every command in the Switch menu was permanently disabled.** Two causes. `MainView`
  published the manager with `.focusedValue`, which only resolves while the view holds
  keyboard focus — the file list takes it as soon as it appears — so the value was nil; it
  now uses `.focusedSceneValue` like every other key. And even once the manager arrived, the
  menu read `manager.connectionState` directly: `@FocusedValue` hands back the object but
  does not observe its `@Published` properties, so the menu never rebuilt on connect. The
  menu now reads an `Equatable` snapshot published from the view that does observe it.
  Help ▸ Report an Issue was affected by the same nil manager and silently omitted
  diagnostics from bug reports.

## [1.0.1] - 2026-08-07

First release validated against real hardware: a Nintendo Switch on HOS 22.5.0 running
DBI's MTP responder. Every fix below is a bug that only surfaced on a physical console.

### Fixed

- **Connecting on macOS at all.** macOS binds the Switch's still-image USB interface to its
  own `ptpcamerad` daemon before any application can claim it, so every connection failed
  with `LIBUSB_ERROR_ACCESS`. SwitchMTP now re-enumerates the USB port and re-claims the
  interface in the same instant, which wins the race against the daemon's automatic
  restart. It needs no privileges and works inside the App Sandbox.
- **Misleading connection errors.** A failed interface claim was silently ignored, so the
  real problem only surfaced later as an unrelated `LIBUSB_ERROR_NO_DEVICE`. Claim failures
  are now reported where they happen.
- **DBI being reported as stock Horizon OS.** DBI's MTP `DeviceInfo` says `Nintendo`/`Switch`,
  identical to stock firmware; it identifies itself only in its USB descriptors. Detection
  now uses those, so DBI is correctly recognised.
- **Every directory listing failing.** DBI advertises `GetObjectPropList` but rejects the
  request with `ParameterNotSupported` rather than `OperationNotSupported`, which bypassed
  the fallback. Both response codes now demote the capability and fall back to
  `GetObjectInfo`.
- **Sessions never opening.** The session was opened twice — once by device configuration and
  again by the client — and the second attempt is an error. Masked until connections started
  succeeding.
- **Stale sessions after a crash.** A session left open by a client that died mid-transaction
  is now closed and reopened on the post-reset path, not just the first attempt.
- **Diagnostics naming the wrong processes.** The occupancy check scanned every USB device on
  the machine, so it blamed web browsers and peripherals while missing the real culprit. It
  now inspects only the Switch, and only interface-level clients, which are the ones that can
  actually block a claim. `ptpcamerad` was additionally missed because the daemon name was
  recorded as `ptpcamera`.

### Added

- Regression test pinning the operation set reported by DBI on real hardware.
- Verified hardware results in `docs/HARDWARE_VALIDATION.md`, including DBI's supported and
  unsupported MTP operations.

## [1.0.0] - 2026-08-06

### Added

- Initial public release of SwitchMTP, a native macOS MTP client for Nintendo Switch devices running DBI's MTP responder.
- DBI-aware storage classification for SD Card, NAND, Saves, Album, Installed Games, Gamecard, and SD/NAND install targets.
- Device and operation capability probing with graceful degradation when optional MTP operations are unsupported.
- Drag-and-drop install targets for NSP, NSZ, XCI, and XCZ files, with progress reported for the upload step.
- Save backup and restore workflows, including dated backup folders.
- Album export and gamecard dump workflows.
- USB/MTP diagnostics for common connection, mode, and permission problems.
- Bundled `switchmtp-cli` for device listing, browsing, copying, installs, save backup, and diagnostics.
- Universal arm64 + x86_64 macOS build packaged as an ad-hoc signed DMG.

### Notes

- This release has not yet been validated against real Nintendo Switch hardware.
