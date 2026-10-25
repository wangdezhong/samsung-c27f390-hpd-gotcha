# 三星 C27F390 显示器断电"假在线"特性:根因分析与 PC 端对策

> **一句话结论**:三星 C27F390 用自身电源键关机后,既不释放 HDMI 热插拔检测信号(HPD),也不应答 DDC/CI 查询 —— Windows 从头到尾不知道它被关了,所以副屏一直显示"已连接",窗口永远留在黑掉的屏幕上。换线、换口、重装驱动都无法改变,唯一可靠的办法是 **PC 端反向控制**:用 Win+P 的机制停掉副屏信号,让显示器自己待机熄屏。

## 现象

- 显示器通过 HDMI 直连 PC(最初是 DP→HDMI 转接头,后换直连,现象不变)。
- 按显示器自己的电源键关机后:
  - Windows 显示设置里仍然显示两台显示器,"扩展"拓扑不变;
  - 原副屏上的窗口全部原地不动,落在黑屏上,必须手动拖回主屏;
  - 系统事件日志中**没有任何**设备断开记录。

## 环境

- Windows 10 22H2 (19045)
- AMD Radeon RX 6650 XT(3×DP + 1×HDMI)
- 主屏:2560×1440 高刷屏,DisplayPort 直连
- 副屏:三星 C27F390(仅 HDMI + VGA,无 DP)

## 根因

显示器"是否连接"不是由面板亮不亮决定,而是由链路上的**热插拔检测信号(HPD)**决定。C27F390 的固件在断电(待机)后仍保持 HPD 为有效电平 —— 这是很多显示器的"快速唤醒"设计:链路保持活跃,重新通电后秒亮。代价是:操作系统完全无从感知"用户把它关了"。

### 实测证据

**1. 设备级监视(Win32.DeviceChangeEvent)**

用 WMI 事件订阅监视关机全程:0 个设备到达/移除事件。PnP 层完全无感知。

**2. DDC/CI 探针(dxva2.dll,`test-ddc.ps1`)**

| 查询 | 含义 | 主屏(DP) | 三星 C27F390(HDMI 直连) |
|---|---|---|---|
| `GetMonitorCapabilities` | 能力描述符 | OK (caps=0x1C17) | 失败 |
| VCP 0x10 | 亮度 | OK,97/100,~58ms | 失败 |
| VCP 0xD6 | 电源模式 | OK,1(开) | 失败 |
| VCP 0x01 / 0x52 / 0x62 / 0xDF | 其他 | OK | 全部失败 |

主屏一切正常,三星对所有 DDC/CI 查询完全无应答。这意味着:

- PC **无法读取**它的电源状态 → 无法做"检测断电→自动回收窗口"的自动化;
- PC 也**无法通过 VCP 0xD6 远程开关它**;
- 顺带说明:诸如"按亮度调节"类软件对它也必然无效。

**3. 30 天系统日志**:零显示器拔插记录、零 GPU 超时(TDR)记录 —— 排除驱动崩溃,问题在链路协议层。

### 为什么换线没用

HPD 是显示器固件的行为,与线材/转接头无关(转接头只会额外引入别的问题,见下文"相关发现")。

## 对策:PC 端反向控制

思路反过来:**不让显示器告诉 PC"我关了",而是让 PC 主动"关掉"副屏**。

原理:调用 `SetDisplayConfig`(即 Win+P 的底层 API)把拓扑切到"仅主屏"→ Windows 原生把副屏上所有窗口收回主屏 → 三星失去信号后自动进入待机(面板熄灭,指示灯变橙,效果与按电源键完全一致)。再切回"扩展"即恢复。

### 用法

1. 下载 `screen_toggle.ps1` 到本地固定位置,例如 `C:\Users\<你>\screen_toggle.ps1`;
2. 创建带全局热键的桌面快捷方式(一次性):

```powershell
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\ScreenToggle.lnk")
$lnk.TargetPath  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\<你>\screen_toggle.ps1"'
$lnk.WorkingDirectory = "$env:USERPROFILE"
$lnk.WindowStyle = 7
$lnk.Hotkey      = 'CTRL+ALT+F9'   # 按喜好修改
$lnk.Save()
```

3. 以后:
   - **Ctrl+Alt+F9** = 关副屏(窗口全部回主屏,三星自动熄屏)
   - **再按一次** = 开副屏(恢复扩展)

### 系统内置等效方案(零安装)

- **Win + P** → 仅电脑屏幕 / 扩展
- **Win + Shift + ←/→** 把当前焦点窗口扔到另一块屏

## 附:支持 DDC/CI 的显示器的全自动方案

如果你的显示器 DDC/CI 正常(`test-ddc.ps1` 能读到数据),可以用 `samsung_watch.ps1` 实现全自动:

- 后台轮询副屏 DDC/CI 应答;
- 应答消失(断电)→ 自动把副屏窗口搬回主屏(含最大化窗口、鼠标位置);
- 应答恢复(通电)→ 自动把窗口搬回原位;
- 安全设计:只有先"见过"它应答,之后才允许动作,DDC 不通的显示器它永远待命。

对 C27F390 本机无效(它不应答 DDC),但代码可作为其他显示器的参考实现。

## 如何检测你自己的显示器有没有同样的特性

1. 运行 `test-ddc.ps1`,看副屏是否应答 DDC/CI;
2. 关掉显示器电源 5 秒,按 Win+P 看显示器数量是否减少;
3. 两条都"否" → 和本文是同一类显示器:用 PC 端反向控制。

## 相关发现:DP→HDMI 转接头导致随机闪断

换直连 HDMI 之前,这台显示器经 DP→HDMI 转接头连接,出现过"副屏时不时黑一下 + Windows 设备断开提示音"。机制:劣质/被动转换器链路瞬断 → DP 音频端点随链路拔插 → 播放"设备断开"音;端点插拔不留事件日志,所以日志看起来"很干净"。直连 HDMI 后该现象消失。**建议副屏一律直连显卡原生 HDMI 口。**

## 文件清单

| 文件 | 用途 |
|---|---|
| `screen_toggle.ps1` | 一键切换 仅主屏 ↔ 扩展(SetDisplayConfig),配热键使用 |
| `samsung_watch.ps1` | DDC/CI 断电检测 + 窗口自动搬移(适用于 DDC 正常的显示器) |
| `test-ddc.ps1` | DDC/CI 探针:列出每台显示器对各 VCP 码的应答情况 |

## 适用范围与免责

- 结论基于 Windows 10 22H2 + AMD RX 6650 XT + C27F390(HDMI 直连)实测;
- 不同品牌/型号/接口(尤其 USB-C、KVM、扩展坞链路)行为可能不同;
- `SetDisplayConfig` 仅改变本次会话拓扑,不修改注册表、不动驱动,随时可用 Win+P 恢复。
