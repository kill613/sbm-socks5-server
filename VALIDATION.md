# 测试与验收记录

日期：2026-10-30（北京时间）。

结论：独立源码已发布；下列自动化、Debian13容器及一次性Ubuntu虚拟机测试通过。**后续用户已提供SSTap TCP/UDP及Windows经Debian的非DNS UDP123成功证据；云服务器实际重启、游戏及其他平台仍未全部验收。**

## 可核对证据

- 被测试的程序提交：[`4ef7a66ff434463f94984352e0ebc9d95e7ef1e6`](https://github.com/kill613/sbm-socks5-server/commit/4ef7a66ff434463f94984352e0ebc9d95e7ef1e6)。
- [Actions完整记录](https://github.com/kill613/sbm-socks5-server/actions/runs/40981164335)：`protocol`与`one-click-systemd`均为success。
- 该版本`install.sh`的SHA-256：`a50beae4cc48bf982fd514ff58c1ed66edba4598e5bca54920510ef347fe53eb`。匿名公开下载后已与本地文件核对一致。
- 本报告只新增记录，不改被测程序或单文件安装器。
- 后续验证提交：[`c704d7fc0a7b1b0021ecd84e36a509e9f690e7e8`](https://github.com/kill613/sbm-socks5-server/commit/c704d7fc0a7b1b0021ecd84e36a509e9f690e7e8)。[最新Actions](https://github.com/kill613/sbm-socks5-server/actions/runs/40982057306)三组job全部通过，新增没有预装Python的Debian13 systemd容器完整安装及账户管理验证；安装脚本SHA未变。

## 已通过

| 项目 | 证据范围 |
| --- | --- |
| 单元测试13项 | 凭据长度与字符规则、认证配置、输入拒绝、空闲UDP范围、下载校验换点、旧版iproute检测、修改失败恢复、停止状态保持 |
| 真实内核测试4项 | 第二账户的TCP数据往返、匿名和错误密码拒绝、UDP数据往返及公网通告/固定端口、端口范围耗尽时拒绝越界 |
| 完整单文件安装 | 一次性Ubuntu24.04 amd64虚拟机，直接执行公开的install.sh，由清华源准备组件，编译固定SHA的上游源码及严格范围补丁 |
| Debian13环境引导 | 从未预装Python的Debian13容器执行单文件安装，由清华源安装环境并启动真实systemd服务，随后验证账户/端口管理；容器共享宿主内核，不等同于裸机 |
| 服务与管理 | 立即启动及设置自启、账户添加/查看/重设/删除、改TCP端口、停止后修改配置仍保持停止、再次启动和自检 |
| 防火墙 | 独立网络空间内真实nft及iptables添加、改端口、精确清理，保留预置L2TP规则 |
| 隔离 | 安装时保留占用UDP38162的测试哨兵，不修改全局IPv4转发值 |
| 发布检查 | 无面板或管理端依赖；单文件安装器与明文源码一致；公开文件不包含现场数据库、账号、密钥或备份 |

真实内核TCP/UDP数据测试在回环地址进行；完整安装中的公网通告采用测试地址，不是公网中继往返测试。L2TP隔离检查使用端口占用及规则哨兵，没有在该虚拟机运行真实L2TP业务。这些边界不能省略。

## 后续用户实机结果（2026-10-30）

- 云端服务running、开机自启enabled，本机认证与公网UDP通告通过；用户提供SSTap原生TCP/UDP成功截图。
- 用户在新Debian整合管理端部署一条SOCKS5线路；Windows网页正常，出口与服务端一致。
- 非DNS UDP123测试取得三次有效NTP响应，同时Debian抓包显示客户端三次请求和回复双向经过TUN；不依赖DNS转TCP。
- Debian实际重启后，用户确认网页、出口和三次NTP查询仍正常。这是管理服务器重启，云SOCKS5服务器没有相应整机重启证据。

以上为用户提供的输出和截图，不是助手远程执行。公开记录省略实际代理IP及凭据。[完整分流验收范围](https://github.com/kill613/sing-box-hy2-multiline/blob/main/installer/FIELD_ACCEPTANCE_20261030.md)。

## 仍待实机验收

云端机器实际重启、已有GOST/L2TP业务回归、实际游戏/QUIC、CentOS/Rocky/Alma及ARM、云服务端对应的新系统实机安装和恢复演练仍需对应证据。管理端Debian13实机通过不能证明云服务端在所有操作系统上通过。

TCP DNS和DNS转TCP成功不能代表普通UDP；本次普通UDP证据为独立的UDP123 NTP双向抓包。NTP样本不能证明所有UDP应用或性能。

## 回退

运行安装结束打印目录中的`rollback.sh`，只停止/禁用本服务并清理其专属规则，保留配置与备份供核对。不会回退整个操作系统的软件包，也不停止原GOST/L2TP。管理配置修改另有`/etc/sbm-sk5/backups`中的逐次备份及失败恢复机制。

## 统一下载/软件源回退验证

程序提交4edb436ab8cf48e299d17b7eaee63e74de9bf852：[Actions](https://github.com/kill613/sbm-socks5-server/actions/runs/41010212421)三组全部通过。包括16项单元测试、真实TCP/UDP协议、Debian13无curl/Python的完整引导与安装，以及Ubuntu实际安装和保留已有L2TP端口测试。国内加速点采用完整下载摘要验证，失败切换；官方更新清单仅从GitHub API经TLS读取。系统源失败回退保留签名验证。未在用户云服务器覆盖安装，不把CI当作RPM/ARM现场验收。

用户后续反馈CentOS上官方原始文件地址首次下载超时，而国内加速加固定摘要命令可正确安装；入口优先级据此修正。该反馈没有本轮服务状态/公网UDP输出，不能扩大为完整CentOS协议或性能验收。
