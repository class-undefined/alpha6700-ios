# 第三方代码

当前验证程序使用 [alpha2go](https://github.com/knallli/alpha2go)，固定在提交 `02883425c9445c653b2950210187cdd1547320c2`。本地源码位于 `vendor/alpha2go`，保持上游原样。

alpha2go 采用 Apache-2.0 许可。许可证和声明随源码保留在 `vendor/alpha2go/LICENSE`、`vendor/alpha2go/NOTICE`。它通过 `golang.org/x/crypto` 实现 SSH，相关依赖由 `prototype/go.mod` 和 `go.sum` 固定。

本项目的 `prototype` 调用库接口，单独实现限定范围的实机验证、输出记录、稳定会话标识、中断续传检查、ISO 临时调整与恢复，以及单次快门验证。没有调用上游命令行工具的通用存储枚举、任意原始命令、删除、恢复设置或 LUT 写入功能。

另查阅了以下项目，用于交叉核对协议路线：

| 项目 | 查阅内容 | 当前采用情况 |
|---|---|---|
| [remote-camera-control-rs](https://github.com/Streetblock/remote-camera-control-rs) | α6700 的发现、PTP/IP 会话和参数访问 | 未引入代码 |
| [SonyCameraKit](https://github.com/wangrunji0408/SonyCameraKit) | Swift/CoreBluetooth 的 Wi-Fi 唤醒流程 | 未引入代码；未发现明确许可证 |
| [sony-camera-protocol](https://github.com/sarnau/sony-camera-protocol) | BLE 特征值和 Python Wi-Fi 引导 | 未引入代码；未发现明确许可证 |

开源作者的实测结论与本项目的实机结果分别记录。上游在同型号、同固件上成功，不代表本机验证已经通过。
