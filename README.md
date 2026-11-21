# FocusLock

**到点盖住桌面，只放行「豆包」。**

Windows 熬夜锁屏工具。设定的时段一到，全屏遮罩接管桌面，只留「打开豆包」和「立刻关机」两个出口——想继续用电脑，得等倒计时走完、手输 1000 位随机数字，或者自己双击 `unlock.cmd`。

![version](https://img.shields.io/badge/version-1.2.7-6f7fc7?style=flat-square)
![platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-4c7a96?style=flat-square)
![shell](https://img.shields.io/badge/PowerShell-5.1-2f6f8f?style=flat-square)
![admin](https://img.shields.io/badge/admin-not%20required-589c80?style=flat-square)
![network](https://img.shields.io/badge/network-none-b4a05c?style=flat-square)

单文件 PowerShell 程序（`FocusLock.ps1`，约 2300 行）＋ 七个 `.cmd` / `.vbs` 外壳。用户级安装（`%LOCALAPPDATA%\FocusLock`），不联网、不写 HKLM、不装服务或驱动、不改系统文件。

---

## 目录

- [特点](#特点)
- [快速开始](#快速开始)
- [它怎么工作](#它怎么工作)
- [两种锁](#两种锁)
- [三种解锁](#三种解锁)
- [锁屏界面](#锁屏界面)
- [安装与升级](#安装与升级)
- [卸载](#卸载)
- [配置](#配置)
- [自启与性能](#自启与性能)
- [资源占用](#资源占用)
- [数据与日志](#数据与日志)
- [排查](#排查)
- [已知限制](#已知限制)
- [设计取舍](#设计取舍)
- [文件结构](#文件结构)

## 特点

- **两种锁**：每天定时（可跳过指定周几）＋ 立刻锁 N 分钟
- **三种解锁**：等它结束、1000 位数字挑战、`unlock.cmd`（带 10 秒门禁）
- **不锁时 0 常驻进程**：计划任务每分钟跑一次、约 0.4 秒就退出
- **登录秒锁**：Run 键 + 计划任务双链路，开机那段最容易漏的时间也盖住
- **互保**：遮罩和看门狗互相检查，杀掉一个，另一个会补回来
- **卸载可验证**：目录、任务、Run 键、策略值、残留进程逐项检查，全干净才返回 0

## 快速开始

前提：Windows 10 / 11，系统自带的 Windows PowerShell 5.1，不需要管理员权限。

```cmd
install.cmd
settings.cmd
lock.cmd
```

| 想做 | 命令 |
| --- | --- |
| 安装 / 升级 | `install.cmd` |
| 卸载 | `uninstall.cmd` |
| 改时段、改周几 | `settings.cmd` |
| 立刻锁 | `lock.cmd`（弹窗选时长）或 `lock.cmd 45`（直接锁 45 分钟） |
| 解锁 | `unlock.cmd` |
| 跑单个模式 | `powershell -NoProfile -ExecutionPolicy Bypass -File FocusLock.ps1 -Mode tick` |

默认配置：每天 `00:00`–`06:00` 上锁，跳过周六，数字挑战 1000 位。

## 它怎么工作

- **两个触发点**：Run 键（登录即跑）和计划任务（登录 + 每分钟），都只干一件事——跑一次 `tick`
- **`tick` 只做判定**：当前时刻命中锁机区间就确保 `lock-ui` 与 `guard` 活着；没命中就清掉残留状态后退出，不锁时 0 常驻进程
- **两个进程互保**：遮罩没了看门狗拉起，看门狗没了遮罩拉起

核心就一句：**维护一个「锁机区间」集合，轮询当前时刻在不在里面。**

- 定时锁：`manual.json` 里一条 `[start, end]`
- 熬夜锁：按 `config.json` 的时段 + `skipDays` 每天现算一条，作废记录写在 `state.json` 的 `dismissed`
- 两个区间有交集时，并集内任何时刻解锁都会同时解除两个；不相交就各解各的
- 解锁 = 删区间或写一条作废记录，下一轮 `tick` 自然找不到，于是出锁
- 倒计时显示整条连通区间的终点，不是当前这一段的终点

边界处理：`tick` 先算出下一个状态切换点，落在 90 秒内就 `Sleep` 到那一刻（+120 ms 余量），而不是每 N 秒问一次。

## 两种锁

| 项目 | 熬夜锁 | 立刻锁 |
| --- | --- | --- |
| 触发 | 每天按 `window.start`–`window.end`，跳过 `skipDays` | `lock.cmd` / `lock.cmd N` |
| 数据 | 每次现算，不落盘 | `manual.json` 一条 `[现在, 现在+N 分钟]` |
| 结束 | 时段终点，或解锁后记入 `state.json` | 到点自动删，或解锁 |
| 跨零点 | 支持（`start` > `end` 时算到次日） | — |

## 三种解锁

| 方式 | 操作 | 实际耗时 |
| --- | --- | --- |
| 等 | 遮罩上有倒计时，到点自己走 | 0，但要等到时段结束 |
| 数字挑战 | 100 组 × 10 位，组序随机，输错一位整批作废重来 | 手速决定，一般 5–10 分钟 |
| `unlock.cmd` | 双击；遮罩须**稳定显示满 10 秒** | 10 秒 |

关于那 10 秒门禁：刚开机那几秒遮罩还没画到屏幕上，或者遮罩崩溃重启的空窗期，双击 `unlock.cmd` 一律不算解锁，而是**立刻重新上锁**并写一条 `unlock-refused` 日志。只有遮罩稳定显示满 10 秒后的双击才生效。不在锁机时段时，`unlock.cmd` 只清理残留状态。

数字挑战的那 1000 位由 `RandomNumberGenerator` 生成，每组的出现顺序也会打乱；答错任意一位，整批（含已答对的）作废并重新生成。

## 锁屏界面

深色全屏、无边框、置顶，每 250 ms 校准一次尺寸和层级。

| 区域 | 内容 |
| --- | --- |
| 时钟 | `23:47:05`，下面一行是「距离自动解锁还有 04:12:53」 |
| 卡片 | `ui.title` / `ui.subtitle`，默认「免打扰时间」＋「本机现在只允许使用『豆包』」 |
| 按钮 | `打开豆包`、`立刻关机` |
| 挑战区 | 「第 7 / 100 组 · 已确认 60 / 1000 位 · 进度点」＋ 照着敲的 10 位数字 ＋ 输入框和确认按钮 |
| 底栏 | 版本号 · 自动解锁时刻 · 提示可用 `Unlock.cmd` 立即解锁 |

锁定期间：

- **只放行豆包** —— 按进程名、路径关键词、`allow.exePath` 三段判定；点按钮没起来会自己重试，约 30 次后提示手动点一次
- **立刻关机** —— 二次确认后 `shutdown /s /t 0 /f`
- **藏任务栏** —— `Shell_TrayWnd` / `Shell_SecondaryTrayWnd` 都藏，副屏任务栏一起收；每约 30 秒重新确认一次
- **拦快捷键** —— 键盘钩子吃掉 Win 键、`Win+任意`（放行 `Win+L`）、`Alt+Tab`、`Alt+Esc`、`Alt+Space`、`Alt+F4`、`Ctrl+Esc`
- **压任务管理器** —— 每约 2 秒杀一次 `taskmgr`，同时反复写 `DisableTaskMgr` 策略；策略写不进去就自动降级为纯进程拦截
- **退出即还原** —— 撤钩子、清策略、恢复任务栏、收掉遮罩进程

## 安装与升级

```cmd
install.cmd
```

复制 7 个文件到 `%LOCALAPPDATA%\FocusLock`、注册计划任务、写 Run 键，不需要管理员权限。步骤是固定的：

1. **先停任务、杀掉还在跑的 tick / guard / 遮罩** —— 否则正好落在整分点上的 tick 会读到写了一半的脚本
2. **覆盖 7 个文件**，缺一个就中止
3. **清旧版遗留** —— 两个旧任务、`HKCU\Software\FocusLock`、`StartupApproved\Run\FocusLock`
4. **注册任务 + Run 键** —— 调 `-Mode lock`，注册失败返回非零
5. **逐项验证** —— 任务、Run 键、`tick.vbs`、`config.json`、`native.dll`
6. **打印配置目录**

升级就是再跑一次同一条命令。任何一步失败都会打印 `FAIL` 行并以非零退出，不会留下「注册了一半」的状态。

## 卸载

```cmd
uninstall.cmd
```

> 锁机时段内 `uninstall.cmd` 会直接拒绝：`-Mode uninstall` 返回退出码 **3**，命令脚本看到 3 就中止，不删任何东西。要先在遮罩上解锁，或等这一轮锁结束。

先调 `FocusLock.ps1 -Mode uninstall`（优先用仓库里这份，保证是当前版本），它会：

- 删 `FocusLockGuard`，连带旧版的 `FocusLockGuardBackup` / `FocusLockManualLock`
- 删 Run 键和 `StartupApproved\Run\FocusLock` —— 「启动应用」里的禁用记录不清掉，Run 键会被 Windows 直接跳过
- 删 `DisableTaskMgr`，并把因此变空的 `Policies\System` 键一起收掉
- 删 v1 遗留的 `HKCU\Software\FocusLock`
- 杀掉还在跑的 tick / guard / 遮罩（不杀自己）
- 还原任务栏

然后命令脚本自己删目录（6 次重试，防止句柄没释放），最后逐项验证：目录、任务、Run 键、启动记录、旧键、策略值、残留进程。全干净才 `exit 0`，否则打印 `FAIL` 行并 `exit 1`。

> 卸载会把安装目录里的 `FocusLock.ps1` 一起删掉，所以仓库（或至少 `uninstall.cmd` + `FocusLock.ps1`）要留一份。脚本找不到时会退回纯注册表清理。

## 配置

`settings.cmd` 能改时段和周几，保存即生效、不用重装。其余字段直接编辑 `%LOCALAPPDATA%\FocusLock\config.json`，遮罩每 10 秒重读一次配置。

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `autoEnabled` | `true` | `false` 关闭熬夜锁，立刻锁不受影响 |
| `window.start` / `window.end` | `00:00` / `06:00` | 熬夜锁时段，`HH:mm`，`start` > `end` 表示跨零点 |
| `window.skipDays` | `[6]` | 跳过的 ISO 周几（1=周一 … 7=周日），默认跳过周六 |
| `challenge.groups` × `digitsPerGroup` | `100` × `10` | 数字挑战规模，默认 1000 位 |
| `allow.processNames` | `Doubao` / `doubao` / `豆包` | 放行的进程名 |
| `allow.pathKeywords` | `doubao` | 放行的路径关键词 |
| `allow.exePath` | 自动探测 | 豆包 exe 路径，探测不到时手填 |
| `safety.maxLockHours` | `10` | 连续锁超过这么久自动释放，防把自己锁死 |
| `ui.title` / `ui.subtitle` | `免打扰时间` / `本机现在只允许使用「豆包」` | 遮罩上的标题和副标题 |
| `release.minutes` | `30` | 预留字段，当前版本不生效 |
| `activeFrom` | `2020-01-01T00:00:00+08:00` | 预留字段，当前版本不生效 |

> 在 `settings.cmd` 里保存会顺手删掉 `state.json`——「今天这份已作废」的记录被清掉，所以如果当前时间正好落在新时段内，保存后立刻重锁。

## 自启与性能

两条链，缺一不可：

- **Run 键** —— `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\FocusLock` → `wscript tick.vbs`。Explorer 一启动就执行，负责「登录那一刻」的秒锁
- **计划任务** —— `FocusLockGuard`：登录触发 + 每分钟重复，`StartWhenAvailable`、`MultipleInstances=IgnoreNew`、`RunLevel=Limited`、执行上限 10 分钟。负责每分钟轮询与兜底，关机期间错过的那一分钟开机会补跑

> 试过只留计划任务：登录时它可能被上一分钟的 tick 占着（`IgnoreNew`），或受任务计划在开机高峰的调度影响，锁屏会晚几秒到几十秒。所以 Run 键必须保留——这是「秒锁」的那一路。

保留的优化（只减少单进程开销，不减少自启数量）：

- **C# 只编译一次** —— 首次编译成 `native.dll`（约 6 KB），源码 SHA256 写进 `native.hash`；之后 `Add-Type -Path` 直接加载，不再每次拉起 `csc.exe`，源码变了哈希不匹配才重编
- **解锁态的 tick 完全不碰 native** —— 只查策略值和 `taskbar.hidden` 标记，命中才动手
- **不在锁定时段就不拉遮罩** —— 以前装完或手动 `lock.cmd` 会空转 6 秒
- **启动器不弹框** —— `tick.vbs` / `settings.vbs` 都带 `On Error Resume Next` 并显式 `WScript.Quit`；启动器一旦报错就会弹「Windows Script Host」对话框并卡住，而 `IgnoreNew` 之下卡住的实例会把后面每个整分 tick 全挡掉
- **慢 tick 留痕** —— 超过 800 ms 就往 `focuslock.log` 写一条 `tick-slow`，方便下次开机核对

开机如果仍然卡，做一次 A/B 确认是不是它（注意：禁用后开机不会秒锁）：

```powershell
Disable-ScheduledTask -TaskName FocusLockGuard   # 重启对比
Enable-ScheduledTask  -TaskName FocusLockGuard
```

## 资源占用

| 项目 | 数值 |
| --- | --- |
| 锁屏期间内存 | ~250 MB（PowerShell + WinForms 基础开销） |
| 不锁时 | 0 常驻进程 |
| 后台轮询 | 每分钟一次进程启动，约 0.4 s；临近切换点会 sleep 到边界 |
| 磁盘 | 主程序约 90 KB，`native.dll` 约 6 KB |

## 数据与日志

运行数据都在 `%LOCALAPPDATA%\FocusLock\`：

| 文件 | 作用 |
| --- | --- |
| `config.json` | 时段、周几、挑战规模、放行名单、遮罩文案 |
| `manual.json` | 立刻锁的区间，过期自动删 |
| `state.json` | 熬夜锁的作废记录（`dismissed`） |
| `ui-ready.json` | 遮罩真正画出来的时刻，`unlock.cmd` 的门禁依据 |
| `taskbar.hidden` | 任务栏被藏过的标记，异常退出后用来恢复 |
| `native.dll` + `native.hash` | C# 助手与它的源码哈希 |
| `focuslock.log` | 事件日志，超过 512 KB 只保留最后 200 行 |

日志是三列纯文本：`时间 | 事件 | 详情`。常看的几个事件：

| 事件 | 含义 |
| --- | --- |
| `tick-slow` | 某次 tick 超过 800 ms，开机 / 唤醒卡顿的线索 |
| `unlock-refused` | 双击 `unlock.cmd` 被门禁拒绝，详情里有遮罩稳定了多久 |
| `unlock-cli` / `unlock-done` | 解锁成功、解锁收尾完成 |
| `dismissed` / `manual-released` | 熬夜锁被作废 / 立刻锁区间被移除 |
| `safety-release` | 连续锁定超过 `maxLockHours`，自动放行 |
| `policy-unavailable` | `DisableTaskMgr` 写不进去，已降级为进程级拦截 |
| `autostart-fail` / `native-build-fail` | 自启注册 / `native.dll` 编译失败 |

## 排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 开机没有秒锁 | Run 键被「启动应用」禁用，或被清理工具删了 | 重跑 `install.cmd` |
| 双击 `unlock.cmd` 没反应，反而锁得更死 | 遮罩还没稳定显示满 10 秒，门禁按设计拒绝 | 等 10 秒再双击，看日志里的 `unlock-refused` |
| `uninstall.cmd` 直接退出、什么都没删 | 退出码 3＝锁机中拒绝卸载 | 先解锁或等这一轮结束 |
| 任务管理器仍能打开 | 策略被组策略覆盖或写入失败，走了进程级拦截 | 看 `policy-unavailable`；杀进程有约 2 秒窗口，属预期 |
| 「打开豆包」点了没反应 | `allow.exePath` 不对，或豆包装在非常规目录 | 手填 exe 完整路径到 `config.json` |
| 开机变慢 | 计划任务在开机高峰被调度，或 tick 变慢 | 看 `tick-slow`，用上面的 A/B 命令定位 |
| 卸载后还剩进程 | 句柄没释放，目录删不掉 | 脚本已带 6 次重试，仍失败会打印 `FAIL` 并返回 1 |

## 已知限制

- 计划任务最小重复间隔 1 分钟，切换点落在 90 秒外的时段靠下一次 tick 接手
- 任务管理器优先用 `DisableTaskMgr` 策略拦；策略写不进去时降级为每 2 秒杀进程，存在约 2 秒窗口
- 没有防破解；安全模式、任务管理器、直接改 JSON 都能绕过
- `native.dll` 首次生成时如果 `Add-Type` 失败，会自动退回进程内编译，功能不受影响
- 只覆盖主屏 + 任务栏层级，不接管 UAC 安全桌面、登录界面、其他用户会话
- 依赖 Windows PowerShell 5.1 与 WinForms，没有做 PowerShell 7 / ARM64 适配

## 设计取舍

- **不做防破解** —— `unlock.cmd` 在锁机时段内也能解（前提是遮罩已稳定显示）。这是给自己用的工具，目的不是对抗，是给「再刷五分钟」加一道摩擦。真要硬锁，安全模式和任务管理器都能绕
- **用户级而不是系统级** —— 不写 HKLM、不装服务、不要管理员，代价是拦不住提权后的操作
- **PowerShell + WinForms** —— 不用编译、不用装运行时、改一行就能跑；代价是锁屏期间约 250 MB 内存
- **区间集合而不是「锁定标志位」** —— 状态全是可计算的：现在在不在区间里、下一个边界在哪。解锁只是删数据，不需要改任何开关，也就没有状态不一致

## 文件结构

```
FocusLock.ps1    主程序（8 个模式：lock / lock-ui / lock-ask / tick / guard / unlock / settings / uninstall）
install.cmd      一键部署 / 升级（6 步，逐步校验）
uninstall.cmd    一键卸载（逐项验证，返回码 0/1/3）
lock.cmd         上锁（无参数弹窗选时长，带参数直接锁）
unlock.cmd       解锁（受 10 秒门禁约束）
settings.cmd     设置时段 / 周几   → settings.vbs（免黑框）
tick.vbs         计划任务与 Run 键用的静默启动器
README.md        本文件
```

运行时数据：`%LOCALAPPDATA%\FocusLock\`（见 [数据与日志](#数据与日志)）

当前版本 **1.2.7**，变更看 `git log`。
