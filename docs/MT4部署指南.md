# MT4 部署指南

## 1. 准备环境

需要准备：

- Windows 版 TradingHero。
- 已安装并至少启动过一次的 MetaTrader 4。
- 本仓库的本地目录。

建议先使用模拟账户完成连接与交易验证。

## 2. 启用 TradingHero 的 MT4 功能

在 `TradingHero.exe` 所在目录创建 `config.json`：

```json
[
  {
    "feat": "MT4"
  }
]
```

保存后完全退出并重新启动 TradingHero。未配置合法的 MT4 条目时，MT4 面板和本地网关不会启动。

## 3. 安装 EA

在 TradingHero 的 MT4 面板点击“桥接配置”，选择本仓库目录和 MT4 数据目录。确认后 TradingHero 会自动生成 Token 并执行仓库根目录的 `launch.bat`：

- 只将 `TradingHeroBridge.ex4` 复制到 `MQL4\Experts\TradingHero`。
- 在 `MQL4\Files\TradingHero\bridge.conf` 写入本地网关地址和 Token。
- 在 `http://127.0.0.1` 启动 MT4 本地网关。

如果导航器中没有出现 EA：

1. 在 MT4 中选择“文件 > 打开数据文件夹”。
2. 将本仓库 `mt4` 目录中的 `TradingHeroBridge.ex4` 复制到 `MQL4\Experts\TradingHero`。
3. 回到 MT4，在“导航器 > 智能交易系统”上点击右键并选择“刷新”。
4. 如果 `.ex4` 无法加载，使用 MetaEditor 打开 `.mq4` 并重新编译。

## 4. 允许 WebRequest

1. 打开“工具 > 选项 > 智能交易系统”。
2. 勾选“允许 WebRequest 用于下列 URL”。
3. 添加以下地址：

```text
http://127.0.0.1
```

不要添加公网地址，也不要把端口 80 映射到其他设备。

## 5. 加载 EA

1. 打开任意一个需要保持运行的 MT4 图表。
2. 将 `TradingHeroBridge` EA 拖到图表上。
3. 仅查看数据时可保持 `AllowLiveTrading=false`。
4. 如需下单、平仓和撤单，将 `AllowLiveTrading=true`。
5. 需要真实交易时，同时勾选 EA 的“允许实时自动交易”，并开启 MT4 顶部的“自动交易”。

EA 参数中的默认值：

| 参数                           | 默认值             | 说明                            |
| ------------------------------ | ------------------ | ------------------------------- |
| `BridgeUrl`                    | `http://127.0.0.1` | MT4 本地网关                    |
| `BridgeToken`                  | 空                 | 正常情况下从 `bridge.conf` 读取 |
| `AllowLiveTrading`             | `false`            | 是否允许执行真实交易命令        |
| `PollIntervalMilliseconds`     | `300`              | 命令轮询间隔                    |
| `SnapshotIntervalMilliseconds` | `1000`             | 账户快照发送间隔                |

## 6. 验证连接

连接成功后应满足：

- MT4 图表右上角显示 EA 正常运行。
- “智能交易系统”或“日志”中出现 `TradingHeroBridge started`。
- TradingHero 的 MT4 账户选择区域显示已连接账户。
- 市场报价、持仓和挂单能够正常刷新。

如出现 `WebRequest failed, error=5200`，请检查允许列表中的地址是否严格为 `http://127.0.0.1`。
