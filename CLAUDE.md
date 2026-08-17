# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

`dshr` 是一个单文件 bash CLI（`./dshr`，约 250 行），把任意可通过 SSH 密钥访问的 Linux 机器变成远程 DeepSeek Harness (dsh) 开发服务器，并建立本地 SSH 隧道访问其 WebUI。无构建步骤、无测试基础设施；运行时依赖（远程侧）为 bash/ssh/curl/lsof/tmux。

## 常用命令

```sh
bash -n dshr                 # 语法检查
shellcheck dshr              # 静态检查（若已安装）
ln -s "$PWD/dshr/dshr" /usr/local/bin/dshr   # 安装到 PATH
dshr up <ssh-host> [--port N] [--sync]       # 手动验证（幂等，可重跑）
dshr down <ssh-host> [--server]
dshr dsh <ssh-host> <dsh args...>            # 在远程执行 dsh 子命令（localhost/@local 走本地 npx）
dshr list
```

没有单元测试。修改后的验证方式：`bash -n` + `shellcheck` + 在真实 SSH 主机上跑 `up`/`down`/`list` 并观察输出。脚本对外部命令（ssh/curl/tmux/lsof）行为有强假设，改动前先完整阅读相关函数。

## 架构

脚本是扁平单文件结构，按顺序组织：

1. **全局配置**（18–27 行）：所有环境变量默认值在此展开（`DSHR_HOME`、`DSHR_DSH_VERSION`、`DSHR_NODE_MAJOR`、`DSHR_NODE_VERSION`、`DSHR_REMOTE_PORT`、`DSHR_LOCAL_PORT_BASE`、`DSHR_SSH_OPTS`）。新增环境 knob 时沿用 `${DSHR_X:-default}` 模式，并在头部注释块（2–15 行）登记。
2. **辅助函数**（29–44 行）：输出约定（进度走 stdout 的 `say`，错误走 stderr 的 `die`）、`sshc`/`scpc`（强制 `BatchMode=yes` + `ConnectTimeout=8`，即只支持密钥认证）、awk 状态读写、lsof 端口检测。
3. **阶段函数**（46–128 行）：`ensure_install` → `ensure_creds` → `ensure_server`，均幂等，`up` 按此顺序执行。
4. **命令函数**（137–336 行）：`cmd_up`/`cmd_down`/`cmd_dsh`/`cmd_local_up`/`cmd_local_down`/`cmd_list`，末尾 case 分发（338–348 行）。新增子命令时在 case 中登记。

## 关键设计决策（修改时务必保持）

- **SSH 是唯一认证层**：远程服务器只绑定 loopback（`dsh web --port 3080`，无 `--host 0.0.0.0`），所有访问经本地隧道。不要绕过此模型——README 明确说明 DSH 在拥有认证层之前故意禁用公开绑定。
- **状态模型**：`$DSHR_HOME/sessions` 是唯一状态文件，每行 `host port pid`（空格分隔），用 `state_of`/`drop_state`（awk）读写。所有命令必须保持幂等：`up` 重复运行无副作用，`down` 后 `up` 可完整恢复。
- **版本检测读磁盘、不读进程**：`remote_dsh_version` 解析远程 package.json（49–51 行注释解释了原因：非交互 ssh 下 `dsh --version` 的 node 启动无输出，曾导致"未安装"被误判为"已安装"）。不要改回进程调用。
- **健康检查一律 `--noproxy '*'`**（本地与远端两侧），防止本地代理环境干扰 localhost 探测。
- **隧道必须带 `ExitOnForwardFailure=yes`**（170 行）：端口被占时快速失败而不是静默驻留。
- **`cmd_dsh` 透传 stdin/tty**：与其它命令不同，实际执行不用 `sshc`（其 `-n` 会把 stdin 指到 /dev/null），而是保留 stdin 的 ssh（仍强制 `BatchMode=yes` + `ConnectTimeout=8`），使远程 dsh 的交互式提示可用；参数经 `printf '%q'` 逐字传给远端 shell，退出码原样透传。不要改回 `sshc`。
- **`cmd_dsh` 的 localhost 快捷方式**：host 为 `localhost`/`127.0.0.1`/`@local` 时不经 ssh，直接 `npx @deepseek-ai/dsh@$DSH_VERSION` 本地执行（与 `cmd_local_up` 同款 pin 与用法），参数与退出码直接透传。
- **重装即重启**：`DSH_INSTALLED=1` 由 `ensure_install` 设置，`ensure_server` 据此决定是否重启 tmux 会话；否则会话健康就直接复用。

## 远程端约定

- Node 装到 `~/.local/node`（用户态，无 root）；dsh 经 npm 全局安装，版本由 `DSHR_DSH_VERSION` 固定（默认走 npmmirror registry）。安装必须带 `--prefix $HOME/.local/node`：远端 `~/.npmrc` 若自定义了 prefix（如 `~/.local`），npm 会把包装到别处，导致按 `~/.local/node` 读磁盘的 `remote_dsh_version` 误报"未安装/不可读"。不要去掉该 flag。
- 远程服务器运行在 tmux 会话 `dsh-web`：cwd `~/workspace`，loopback `:3080`，日志 `/tmp/dsh-web.log`（排障先 `tail /tmp/dsh-web.log`）。
- 凭据 `~/.dsh/.credentials.yaml` / `settings.yaml` 仅在远程缺失时复制（`--sync` 强制覆盖），权限 0600。
- 本地端口从 `DSHR_LOCAL_PORT_BASE`（3081）向上自动分配，`lsof -nP -iTCP:<port> -sTCP:LISTEN` 判断占用。
- `$DSHR_HOME/tunnels` 目录被创建但当前脚本未使用——保留 mkdir，其他工具可能依赖其存在。

## 注意事项

- 头部注释块（2–15 行）是权威的用法/环境变量文档；语义变化时同步更新它和 README.md（用户视角文档）。
- 默认镜像（Aliyun node 发布 + npmmirror）针对国内网络；替换镜像只改 `ensure_install` 中的 URL。
- 错误路径必须 `die`（stderr + 非零退出），不要在错误路径静默 `return` 后假装成功。
- `dshr dsh` 是参数透传：参数逐个传，不要用引号把整条 dsh 命令包成单个参数——dsh 会把含空格的畸形参数报成 `--profile <name> is required`（缺参误报）。
- 本地 3080 端口冲突：`dshr local` 与手动 `dsh web` 默认端口同为 3080，先起者占住后另一者报 `EADDRINUSE`；dshr 登记的 @local 实例用 `dshr local down` 停。
