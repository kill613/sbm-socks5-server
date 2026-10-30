# 独立 SOCKS5 服务端

[已通过的测试与待验收项目](VALIDATION.md)

中文一键安装和`sk5`命令管理，提供带账号密码认证的TCP/UDP SOCKS5代理。**没有管理面板，不依赖其他管理系统，不包含任何现场账号、数据库或备份。**

## 一键安装

请先自行安装curl，再在Linux的root终端复制下面这一条命令。系统识别、环境准备、内核加速、软件源回退和中文问答全部在install.sh内部完成。

CA证书由install.sh自动检查并安装。若首次HTTPS下载尚未启动脚本就报证书错误，可下载install.sh后上传服务器执行，由脚本通过系统签名验证的软件源补齐证书。

<!-- bootstrap-command:start -->
```bash
curl -fL --connect-timeout 8 --max-time 120 https://raw.githubusercontent.com/kill613/sbm-socks5-server/main/install.sh -o sk5-install.sh && bash sk5-install.sh
```
<!-- bootstrap-command:end -->

<details>
<summary>GitHub直连慢时：国内加速安装（含SHA-256校验）</summary>

```bash
curl -fL --connect-timeout 8 --max-time 120 https://ghfast.top/https://raw.githubusercontent.com/kill613/sbm-socks5-server/main/install.sh -o sk5-install.sh && printf '%s  %s\n' 18e494893d92763b50ffa155fa929f6e8cb25e0537d96ee3b558a95cdb0b2c6e sk5-install.sh | sha256sum -c - && bash sk5-install.sh
```

</details>

install.sh为自包含脚本，不需要GitHub账号、克隆仓库、预先安装Python或手动拼接多个脚本。安装器内部程序包与明文`app/`一致，构建脚本及校验均公开。不要使用`curl | bash`，以免安装问答读不到终端输入。

安装过程中文提示确认公网IP、UDP中继范围、TCP端口、账户及密码。回车采用默认值：

| 项目 | 默认值 |
| --- | --- |
| 本机IP/网卡 | 自动检测默认出口，不修改网卡配置 |
| 公网IPv4 | 自动检测后由用户确认；检测失败或冲突可手填 |
| TCP端口 | 随机空闲五位端口 |
| 账户 | 随机8位英文大小写和数字 |
| 密码 | 随机18位英文大小写和数字 |
| UDP中继 | 自动选择1000个连续空闲端口，也可手动填写范围 |

凭据不使用特殊符号、数字`0`或大写`O`；小写`o`可用。默认账号密码均保证含大写、小写和数字。手动账户最多64位、密码最多128位，采用同样字符限制。

安装完成立即启动并设置开机自启，打印IP、端口、账号、密码、SOCKS5链接及所有管理命令。相同资料另存`/root/sbm-sk5-install-*/access.txt`，仅root可读。

## 系统适配

识别Debian12/13、Ubuntu22.04/24.04/26.04、CentOS7、CentOS9Stream、Rocky/Alma8/9/10；必须使用systemd。未识别系统停止，不混用不同发行版软件源。

通过**本次安装专用清华源**安装组件，保留系统原源及软件包签名校验，不执行全系统升级。CentOS7使用清华归档源；该系统已停止维护，兼容代码不能视为旧系统安全保证。新服务器建议Debian13。服务端使用本机源码编译，ARM和各RPM发行版仍需各自实机验证。

每次下载3proxy源码都会实际探测中国GitHub加速站，按可用性和速率尝试，失败换点，最后官方直连。必须与代码内固定的官方SHA-256匹配才编译；加速站返回网页或损坏包会被拒绝。不关闭TLS校验，不向镜像站发送代理密码或GitHub认证信息。

## 管理命令

安装后直接输入`sk5`查看帮助，命令在`/usr/local/bin/sk5`。

```bash
sk5 info                       # 查看IP、端口、UDP范围和账户数量
sk5 status                     # 查看状态及自启设置
sk5 users                      # 查看已有账户名
sk5 users --show-passwords      # root终端显示已有账户和密码
sk5 add-user                   # 添加随机8位账户，隐藏提示输入密码
sk5 add-user User123a           # 添加指定账户，回车生成18位密码
sk5 del-user User123a           # 删除账户，不能删除最后一个账户
sk5 passwd User123a             # 重设密码，回车自动生成
sk5 port 31234                 # 修改TCP入口端口
sk5 public-ip 你的公网IPv4      # 修改UDP中继通告的公网IP
sk5 udp-range 20000-20999       # 修改固定UDP中继范围
sk5 start
sk5 stop
sk5 restart
sk5 check                      # 本机认证及UDP通告地址自检
sk5 firewall                   # 恢复本服务专属防火墙规则
```

配置修改先备份，失败尝试恢复原配置和运行状态。运行中的服务改配置会重启本服务、断开其现有连接；原本停止时保持停止。备份在`/etc/sbm-sk5/backups`。管理命令不把密码放进命令行参数，添加或重设密码使用隐藏输入。

## 云安全组与UDP

云安全组必须放行安装结束打印的：

- **TCP入口端口**，供客户端建立SOCKS5连接。
- **完整UDP中继端口范围**，供UDP数据往返。只放行与TCP同号的UDP端口不够。

安装器配置本机firewalld/nftables/iptables中的专属规则，不清空全局策略、不重启整个防火墙；没有云账号权限，不能自动修改云安全组。外部工具重新加载防火墙后可运行`sk5 firewall`。

服务端会向客户端返回配置的公网UDP中继IP，避免返回无法访问的10.x内网IP。云NAT需支持IP一对一、UDP端口号保持不变；共享公网/PAT或额外UDP封锁需单独核验。UDP范围用尽则拒绝请求，不回退到范围之外的随机端口。

`sk5 check`只验证本机认证与UDP通告，**不代表公网UDP已经验收**。在另一台机器可运行源码中的`python3 app/probe_sk5.py`，隐藏输入凭据，分别检查经SOCKS5的TCP/UDP DNS真实答案；Windows安装Python3后也可使用。远端UDP数据和游戏实测证据不足时，状态仍为未验收，不能用TCP网页成功代替UDP成功。

## 与现有服务隔离

本项目使用专用系统账户`sbm-sk5`、`/etc/sbm-sk5`、`/usr/local/libexec/sbm-sk5`及`sbm-sk5.service`，以非root账户运行代理内核。端口占用时停止安装或提示另选端口，不停止占用服务。

不覆盖、停止或替换原GOST、L2TP、IPsec，不改系统全局IPv4转发或网卡IP。已有本项目路径时拒绝覆盖。用户名密码认证强制开启，不提供匿名代理或SOCKS BIND。

回退脚本在安装记录目录`/root/sbm-sk5-install-*/rollback.sh`：仅停止/禁用本次服务并清理专属防火墙规则，保留配置、备份、系统账户及组件供核对，不操作原GOST/L2TP。

## 测试与源码

安装运行使用Python3.6或更新版本，由安装器自动安装；生成/校验发布脚本及运行开发测试请使用Python3.10或更新版本。

```bash
python3 build_installer.py --check
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

CI额外编译真实3proxy并测认证、TCP和UDP数据收发、固定范围及耗尽拒绝；在一次性Ubuntu24虚拟机执行完整单文件安装、账户增删改、修改端口、自启动、停止状态保持及独立网络空间的真实防火墙清理。

测试通过与否以对应提交的Actions结果为准。Debian13无预装Python的容器安装及Ubuntu24安装已通过；用户后续已提供SSTap公网TCP/UDP及Windows经Debian的非DNS UDP123双向成功证据，Debian实际重启后业务仍正常。云SOCKS5服务器重启、游戏、CentOS/Rocky/Alma及ARM等仍待对应实测，详见VALIDATION.md。

内核使用3proxy1.0.2及严格UDP范围补丁，明文见`app/core_patch.py`。本仓库安装/管理代码采用MIT；上游许可证、补丁范围说明见[THIRD_PARTY.md](THIRD_PARTY.md)。

## 统一下载策略

公开安装包及3proxy内核支持国内加速、超时换点、官方回退和固定SHA-256；损坏文件不覆盖原文件。APT/RPM使用相应的软件源及签名校验，不经GitHub代理。内外网IP探测属于实时查询，保持直连，不发送账号或认证信息。加速逻辑不会更改已经运行的代理。
