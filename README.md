# FocusLock

Windows 熬夜锁屏工具。到点用全屏遮罩盖住桌面，只放行「豆包」，逼你去睡。

用户级安装（`%LOCALAPPDATA%\FocusLock`），不联网、不写 HKLM、不装服务/驱动、不改系统文件。没有防破解，`unlock.cmd` 在锁机时段内也能解（前提是遮罩已经显示出来）——这是有意为之。

## 安装 / 升级

```cmd
install.cmd
```

复制文件到 `%LOCALAPPDATA%\FocusLock`、注册计划任务、设置开机自启，不需要管理员权限。步骤固定：

1. 先停任务、杀掉还在跑的 tick / guard / 遮罩 —— 否则正好落在整分点上的 tick 会读到写了一半的脚本
2. 覆盖 7 个文件，缺一个就中止
3. 清旧版遗留：`FocusLockGuardBackup`、`FocusLockManualLock`、`HKCU\Software\FocusLock`、`StartupApproved\Run\FocusLock`
4. `-Mode lock` 注册任务 + Run 键；注册失败会返回非零
5. 逐项验证任务、Run 键、`tick.vbs`、`config.json`、`native.dll`
6. 打印配置目录

升级就是再跑一次同一条命令。任何一步失败都会打印 FAIL 行并以非零退出，不会留下“注册了一半”的状态。

## 卸载

```cmd
uninstall.cmd
```> 锁机时段内 `uninstall.cmd` 会直接拒绝：`-Mode uninstall` 返回退出码 3，命令脚本看到 3 就中止，不删任何东西。要先在遮罩上解锁，或等这一轮锁结束。

先调用 `FocusLock.ps1 -Mode uninstall`（优先用仓库里这份，保证是当前版本），它会：

- 删 `FocusLockGuard`，连带旧版的 `FocusLockGuardBackup` / `FocusLockManualLock`
- 删 Run 键和 `StartupApproved\Run\FocusLock`（“启动应用”里的禁用记录不清掉，Run 键会被 Windows 直接跳过）
- 删 `DisableTaskMgr`，并把因此变空的 `Policies\System` 键一起收掉
- 删 v1 遗留的 `HKCU\Software\FocusLock`
- 杀掉还在跑的 tick / guard / 遮罩（不杀自己）
- 还原任务栏

然后命令脚本自己删目录（带重试，防止句柄没释放），最后逐项验证：目录、任务、Run 键、启动记录、旧键、策略值、残留进程。全干净才 `exit 0`，否则打印 FAIL 行并 `exit 1`。

> 卸载会把安装目录里的 `FocusLock.ps1` 一起删掉，所以仓库（或至少 `uninstall.cmd` + `FocusLock.ps1`）要留一份。脚本找不到时会退回纯注册表清理。

## 用法

| 文件 | 作用 |
| --- | --- |
| `lock.cmd` | 弹窗选时长后上锁（15/30/60/120 或自定义） |
| `lock.cmd 30` | 直接锁 30 分钟 |
| `unlock.cmd` | 解锁 |
| `settings.cmd` | 设置时段和周几 |

两种锁：

- **熬夜锁** —— 每天按设定时段自动触发，可跳过周几（比如跳过周六）
- **立刻锁** —— `lock.cmd` 往集合里加一条 `[现在, 现在+N分钟]`

三种解锁：

1. 等它自己结束（锁屏上有倒计时）
2. 输完 1000 位数字（100 组 × 10 位，错一位整批重来）
3. 双击 `unlock.cmd`：锁机时段内只有遮罩已经显示出来才生效——刚开机那几秒遮罩还没画出来时双击，不会解锁，而是立刻上锁；不在锁机时段则只清理状态

## 原理

维护一个「锁机区间」集合，轮询当前时刻是否与任一区间有交集：有就进锁，没有就出锁。解锁 = 删掉区间或标记作废，轮询自然找不到。

- 定时锁：`manual.json` 一条 `[start, end]`，过期自动删
- 熬夜锁：按 `config.json` 的时段 + skipDays 每天算一条，作废记录写在 `state.json` 的 `dismissed`
- 两个区间有交集时，并集内任何时刻解锁都同时解除两个；不相交各解各的
- 倒计时显示整条连通区间的终点，不是当前这一段的终点

轮询：计划任务每分钟跑一次 `tick`，先算出下一个状态切换点，落在 90 秒内就 sleep 到那一刻；锁着的时候检查 UI / guard 的命名互斥体，缺哪个补哪个。不锁时 0 常驻进程。

## 锁屏界面

全屏卡片式，大时钟 + 倒计时，两个按钮：

- 背板用当前桌面壁纸（模糊 + 压暗）当底图，看着像原生锁屏；壁纸读不到或解码失败就退回纯深色

- **打开豆包** —— 锁定期间唯一放行的应用
- **立刻关机** —— 二次确认后 `shutdown /s /t 0 /f`

锁定期间藏任务栏、拦 Win 键 / Alt+Tab / Alt+Esc / Alt+F4 / Ctrl+Esc（放行 Win+L）、每 2 秒杀一次任务管理器；解锁瞬间全部还原。

息屏 / 睡醒回来时 timer 会跳一大格，这时强制重排、重绘并重新置顶（顺带再藏一次任务栏），避免唤醒后整块黑、任务栏也回来。

## 开机自启与性能

两条自启链，缺一不可：

- **Run 键** —— `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\FocusLock` → `wscript tick.vbs`。Explorer 一启动就执行，负责「登录那一刻」秒锁。
- **计划任务** —— 登录触发 + 每分钟重复；`StartWhenAvailable` 打开，关机期间错过的那分钟会在开机时补跑。

> 试过只留计划任务：登录时它可能被上一分钟的 tick 占着（`MultipleInstances=IgnoreNew`），或受任务计划在开机高峰的调度影响，锁屏会晚几秒到几十秒。所以 Run 键必须保留——这是「秒锁」的那一路。

保留的性能优化（只减少单进程开销，不减少自启数量）：

- **C# 只编译一次**：`install.cmd` / `lock.cmd` 时编译成 `native.dll`（约 6 KB），之后 `Add-Type -Path` 直接加载，不再每次拉起 `csc.exe`
- **解锁态的 tick 完全不碰 native**，只查策略值和 `taskbar.hidden` 标记，命中才动手
- **不在锁定时段就不拉遮罩**（以前装完 / 手动 `lock.cmd` 会空转 6 秒）
- **启动器不弹框**：`tick.vbs` / `settings.vbs` 都带 `On Error Resume Next` 并显式 `WScript.Quit`。启动器一旦报错就会弹「Windows Script Host」对话框并卡住；`IgnoreNew` 之下卡住的实例会把后面每个整分 tick 全部挡掉，锁屏自然就晚了
- tick 超过 800 ms 会往 `focuslock.log` 写一条 `tick-slow`，方便下次开机核对

如果开机仍然卡，做一次 A/B 确认是不是它（注意：禁用后开机不会秒锁）：

```powershell
Disable-ScheduledTask -TaskName FocusLockGuard   # 重启对比
Enable-ScheduledTask  -TaskName FocusLockGuard
```

## 占用

| | 数值 |
| --- | --- |
| 锁屏期间内存 | ~250 MB（PowerShell 基础开销） |
| 不锁时 | 0 常驻进程 |
| 后台轮询 | 每分钟一次进程启动，约 0.4 s；临近切换点会 sleep 到边界 |

## 已知限制

- 计划任务最小重复间隔 1 分钟，边界在 90 秒外的时段靠下一次 tick 接手
- 非管理员账户下，任务管理器靠杀进程拦（`DisableTaskMgr` 策略若不可写会自动降级）
- 没有防破解；安全模式、任务管理器、直接改 JSON 都能绕过
- `native.dll` 首次生成时如果 `Add-Type` 失败，会自动退回进程内编译，功能不受影响
- Windows 的「锁屏壁纸」放在 `%ProgramData%\Microsoft\Windows\SystemData\S-1-5-18\ReadOnly` 下（SYSTEM 权限），用户级读不到，所以遮罩底图默认取**桌面壁纸**；想用别的图就在 `config.json` 里加 `"ui": { "backdrop": "D:\path\pic.jpg" }`

## 文件

```
FocusLock.ps1    主程序（8 个模式：lock / lock-ui / lock-ask / tick / guard / unlock / settings / uninstall）
install.cmd      一键部署 / 升级
uninstall.cmd    一键卸载
lock.cmd         上锁
unlock.cmd       解锁
settings.cmd     设置        → settings.vbs（免黑框）
tick.vbs         计划任务用的静默启动器
```

运行数据：`%LOCALAPPDATA%\FocusLock\`

```
config.json   时段 / 周几 / 挑战参数 / 豆包路径
manual.json   立刻锁区间（过期自动删）
state.json    熬夜锁作废记录
native.dll    C# 助手（首次上锁时生成）
focuslock.log 事件日志（超过 512 KB 自动截断）
```
