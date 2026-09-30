# ⚡ VPS-Tool 综合运维与网络代理工具箱

> 专为 Linux VPS 打造的一站式轻量运维脚本。兼顾极致网络性能、抗封锁代理、安全加固与 IP 质量审计，面向小白提供全自动。
持续更新中啊!!!!
---

## 🌟 核心特性与亮点

- 🛡️ **安全加固，防失联闭环**：全自动静默升级补丁与时间校准；修改 SSH 端口与密钥认证时内置严格拦截与防失联指引，UFW 自动开路。
- 🚀 **前沿协议，免买域名**：精选 **VLESS-Reality** 与 **Hysteria 2** 协议，后台并发实测毫秒级握手延迟，自动优选无 CDN 干扰的大厂伪装（Apple、Mozilla 等），一键直出客户端分享链接。
- 🏎️ **压榨极限，内核调优**：融合 **BBRv3 Max 极限内核**、666shen **网卡软中断全核均衡**、IPv4 优先解析与百万级连接句柄，提供暴躁冲速率与生产级自适应两种调优模式。
- 📦 **懒人福音，交钥匙工程**：模块 4 支持一键自动化流水线（系统更新 ➔ 内核调优 ➔ 协议测速部署 ➔ 防火墙放行 ➔ 链接输出），1 分钟开箱即用。
- 🔍 **安全体检，用完即焚**：集成星标最高的 IPQuality 欺诈分、流媒体/AI 解锁与三网回程路由；独创**硬件防死机哨兵**（内存/磁盘低配预警），测试后自动销毁垃圾文件。
- 🔄 **透明可控，无痕卸载**：所有功能均明确标注 `[可完全撤销]` 与 `[安全保留]`；支持一键在线热更新，更提供出具审计报告的**一键彻底纯净卸载**。
......


## 🚀 快捷运行

只需在你的 Linux VPS 终端中粘贴并执行以下命令即可启动：

### 官方主线（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yesok6/vps-tool/main/install.sh)
```

### 国内 / 拥堵加速镜像

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/yesok6/vps-tool/main/install.sh)
```

> **提示**：首次运行后，脚本会自动注册快捷指令。以后在终端任意位置直接输入 `vps` 即可秒开主菜单！

---

## 📋 功能导航面板

| 模块 | 功能概要 | 撤销属性 |
| :--- | :--- | :--- |
| **1. 网络安全** | 软件静默全量更新、CVE 安全漏洞修补、SSH 端口更换、UFW 防火墙、SSH 密钥认证 | `[安全基线/保留]` |
| **2. 协议搭建** | VLESS + Reality（免域名抗干扰）、Hysteria 2（UDP/弱网晚高峰加速）、配置导出 | `[可完全撤销]` |
| **3. 网络优化** | 生产级自适应调优、BBRv3 Max 激进内核、BBR 暴躁模式、IPv4 优先、多核软中断打散 | `[参数可撤销/内核保留]` |
| **4. 一键安装** | 端到端全自动装配流水线（补丁 ➔ 调优 ➔ 节点 ➔ 放行 ➔ 出链） | `[混合执行]` |
| **5. 质量体检** | 硬件防死机哨兵、IP 纯净度/欺诈分、Netflix/Disney+/ChatGPT 解锁检测、三网回程线路 | `[即用即焚/无残留]` |
| **8. 在线更新** | 击穿 CDN 强缓存，一键检测云端最新版本并原地热重启升级 | `[在线热更新]` |
| **9. 彻底清理** | 精准回滚所有参数、卸载 Swap 与核心，并打印《系统清理与变更恢复报告》 | `[纯净还原]` |

---

## 🖥️ 系统兼容性

- **支持发行版**：Debian 11 / 12+、Ubuntu 20.04 / 22.04 / 24.04+、CentOS / AlmaLinux / Rocky Linux
- **支持硬件架构**：x86_64 (amd64)、aarch64 (arm64)
- **推荐运行环境**：全新的纯净系统最佳
## 🙏 鸣谢与参考项目 (Acknowledgements)

本项目在开发与整合过程中，深受开源社区众多前辈优秀项目的启发，并吸纳与参考了其成熟的技术思路与脚本方案，在此致以由衷的敬意与感谢：
---
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)：下一代通用网络代理核心，提供稳定高效的底层协议支撑。
- [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui)：本项目协议模块参考并吸收了其 Reality 伪装域名选优、延迟探测与客户端分享链接构建思路。
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)：本项目网络优化模块参考并集成了其编译的 BBRv3 Max 极限激进吞吐内核与单向冲榜暴躁模式。
- [666shen/tcp-dashboard](https://github.com/666shen/tcp-dashboard)：本项目参考并融合了其网卡多队列软中断全核打散均衡（RPS/XPS）、百万文件描述符句柄提升与 IPv4 优先解析策略。
- [xykt/IPQuality](https://github.com/xykt/IPQuality)：权威的综合 IP 纯净度与多源欺诈度评级体检脚本。
- [lmc999/RegionRestrictionCheck](https://github.com/lmc999/RegionRestrictionCheck)：轻量而全面的全球流媒体与主流 AI 平台可用性与解锁检测脚本。
- [zhanghanyun/backtrace](https://github.com/zhanghanyun/backtrace)：快速精准的三网回程逐跳路由追踪诊断工具。
......

## ⚠ 免责声明

本项目仅供 Linux 运维管理、系统内核性能调优、学术网络研究与个人服务器安全防护学习使用。请在遵守当地法律法规的前提下合理合规使用，使用者需自行承担因违规使用产生的所有责任。
