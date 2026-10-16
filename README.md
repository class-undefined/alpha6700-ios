# α6700 连接协议调查

## 当前结论

已完成可连接真实相机的协议原型。基于 Apache-2.0 许可的 [alpha2go](https://github.com/knallli/alpha2go)，打通了 SSH 认证、PTP 3.00、取景、参数控制、单次拍摄和图片传输。当前交付物运行在 Mac，尚未封装为 iPhone App。

| 实机验证 | 本次结果 |
|---|---|
| 认证和初始化 | 成功；读取 350 项属性，相机另声明 369 个扩展属性和 57 个控制项 |
| 实时取景 | 连续 3 帧 JPEG，1024×576；完整解码成功 |
| 媒体列表 | 读取第一页 100 条内容；没有将第一页当作整张卡 |
| 缩略图 | 取得 111,782 字节的响应；未单独验收缩略图格式 |
| 原图和续传 | 下载 12,050,156 字节 JPEG；先取得 65,536 字节再断开会话，重新认证后续传 |
| 续传一致性 | 与从头重新下载的完整文件比较，SHA256 一致 |
| 参数写入 | ISO 250 → 200 → 250，每一步都读回确认，原值已恢复 |
| 快门和拍摄回传 | 发出一次快门请求，得到一张 1920×1080 JPEG，141,015 字节；回传队列已清空 |
| 重连 | 单次实测约 493 ms，重连后再次读取 350 项属性；这不是平均耗时或保证值 |

各次运行的结果、命令记录和输出文件保存在 [实测结果索引](evidence/validation-summary.json)。测试在相机上新增了一张照片。原型没有删除照片，也没有启动录像。

现场设备是 Creators’ App 3.5.0、iOS 27.0 和 ILCE-6700。相机自身报告固件为 2.00。调查时间为 2026-10-16，时区为 Asia/Shanghai。

## 实机证据

| 已观察到的内容 | 含义与边界 |
|---|---|
| App 显示“已通过蓝牙进行连接” | 手机已保留蓝牙配对；不证明图传会话已建立 |
| App 连接过程中显示“已通过接入点进行连接” | 本次使用了接入点连接路径 |
| Mac 经 SSDP 发现 ILCE-6700，读取两个 XML 均返回 HTTP 200 | Mac 可以在当前局域网直接访问相机元数据 |
| `X_PTP_Versions = 3.00` | 相机声明支持 PTP（Picture Transfer Protocol，图片传输协议）3.00 |
| `X_PTP_RemoteControlSupport = Enable` | 相机声明支持遥控；具体命令仍待验证 |
| `X_PTP_ContentsTransferSupport = Enable`、`X_PTP_MediaServerSupport = Enable` | 相机声明支持内容传输和媒体服务；没有实际下载文件 |
| `X_PTP_PairingNecessity = Unnecessary` | 该服务描述没有要求 PTP 配对；不等于免认证 |
| `X_SSH_Support = Enable`，TCP 22 返回 SSH banner | SSH（Secure Shell，安全外壳协议）服务可达 |
| 直接连接 TCP 15740 返回拒绝 | 当前状态下不能直接建立明文 PTP/IP 连接；不代表相机始终关闭这个端口 |

服务发现使用 `urn:schemas-sony-com:service:DigitalImaging:1`。发现到的 HTTP 地址为 `http://192.168.5.98:64321/dd.xml`，它指向 `/DigitalImagingDesc.xml`。IP 可能随网络改变，应在客户端中动态发现。

后续实机验证已确认：通过 SSH 认证后，命令和事件连接可转发至相机的 `localhost:15740`，再建立 PTP/IP 和 Sony 会话。实时取景使用相机属性中给出的 HTTP 流，同样经过 SSH 转发。它与老机型的 ScalarWebAPI JSON 命令是不同路线。完整映射见 [PROTOCOL_MAP.md](PROTOCOL_MAP.md)。

原始响应保存在 [实测目录](evidence/live-probe-20261016/)。REA 已解析其中的 HAR（HTTP Archive，HTTP 归档），证据编号为 `ev_decf2dac314122f076a3ec576ce5486f66ed3eb62a3e6fdb0fee1cbcebf50c27`。完整结果见 [REA 证据](evidence/rea-metadata-evidence.json)。这是我们在 Mac 上发起的两个元数据请求，并非手机 App 的抓包；REA 对归档的运行时归属保留为 unknown。

## 断连与后台行为

进入远程拍摄后，现场出现了 iOS 的相机访问提示，随后两次看到“已断开相机连接”。尚未建立稳定取景基线，也没有完成一次排除系统弹窗影响的前后台切换实验。因此，不能把本次断开直接归因于 Wi-Fi、蓝牙、心跳或 Sony 的某段代码。手机观察记录见 [phone-observations.json](evidence/phone-observations.json)。

索尼把“后台保持相机连接”开关标为 Android 专属。iPhone 的客户端可以设计自动恢复，但不能承诺普通网络会话永久在后台运行。[Sony 相机页说明](https://helpguide.sony.net/di-app/ca/v1/en/contents/CA_camera_screen.html)

iOS 26 及之后的 `BGContinuedProcessingTask` 支持用户在前台发起、在后台继续的有限任务，允许网络访问。它适合验证批量导入，需要显示进度、支持取消和处理系统终止。后台 HTTP 下载还可使用 `URLSession`；是否适用于这台相机，要先确认实际文件接口。[Apple 长任务说明](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)、[后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

若客户端使用 `NEHotspotConfiguration.joinOnce = true` 加入相机热点，进入后台超过 15 秒会触发热点断开。这是后续直连模式的排查项；当前没有证据说明 Creators’ App 在本次连接中使用了它。[Apple joinOnce](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce)

## iPhone 客户端后续实现

1. 将已验证的传输与会话逻辑接入原生 iOS 界面，支持取景、快门、参数与媒体选择。
2. 持久化传输队列、文件身份和已确认的偏移量。返回前台后重建会话，避免重放快门命令。
3. 实测 iOS 的后台导入任务、应用挂起和真实 Wi-Fi 断开。目前验证的是 Mac 主动中断会话后的恢复。
4. 补测完整视频、大于 4 GiB 的文件和跨页媒体列表。
5. 补蓝牙唤醒与网络切换，减少首次连接以外的手动操作。

认证信息已通过本地窗口保存到这台 Mac 的钥匙串，后续运行直接复用。密码经本地进程管道传给客户端，没有放进命令行参数或项目配置文件。索尼的菜单路径是“网络 → 网络选项 → 访问认证信息”，其中含用户名、密码和指纹。[认证信息](https://helpguide.sony.net/ilc/2320/v1/en/contents/221h_access_authentication_information.html)、[认证设置](https://helpguide.sony.net/ilc/2320/v1/en/contents/221h_access_authentication_settings.html)

Camera Remote Command 的官方完整参考包仍未取得，官方下载面向企业客户。本阶段使用开源项目的协议实现，并以本机实际响应验证所需功能，已不依赖该参考包推进核心原型。来源与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。[Command 入口与条件](https://support.d-imaging.sony.co.jp/app/cameraremotecommand/en/index.html)

## 运行已验证的协议原型

保持相机接入当前局域网，开启电脑遥控，然后运行：

```sh
cd /Users/class-undefined/sony-camera-investigation
python3 run_camera_check.py info
python3 run_camera_check.py liveview
python3 run_camera_check.py list
python3 run_camera_check.py thumbnail
python3 run_camera_check.py reconnect
python3 run_camera_check.py resume-check
```

每条命令是单独的一次验证，都会创建新证据目录。`resume-check` 从第一页挑选一个不超过 64 MiB 的静态影像，先续传，再完整下载一遍用于比对。它不会批量导出整张卡。

以下两个命令会实际操作相机：

```sh
python3 run_camera_check.py iso-roundtrip
python3 run_camera_check.py capture-once
```

`iso-roundtrip` 临时使用一个相机报告可选的 ISO 值，随后恢复并读回原值。`capture-once` 只在当前已处于单张拍摄、照片模式且开启主机回传时发出一次快门请求，新增一张照片。请求结果不确定时不会自动重拍。

验证程序源码在 [prototype](prototype/)。上游测试已通过；自编的续传回滚、空卡处理、文件身份核对、错误脱敏和 ISO 恢复测试通过了 Go race 检查。

## 运行已实现的探测工具

Mac 与相机连接同一局域网，相机保持开启网络服务，然后运行：

```sh
cd /Users/class-undefined/sony-camera-investigation
python3 sony_probe.py
```

程序只依赖 Python 标准库。它发送 Sony 服务发现请求，读取相机的设备和能力 XML，然后测试 SSH 与 PTP/IP 端口。每次运行创建新的证据目录，保存 JSON、XML 和 HAR。程序不会登录、配对、拍摄、修改参数或下载媒体。

该发现程序实机找到一台 ILCE-6700，两个 HTTP 请求成功。它保留为无需认证的独立诊断入口。

## 调查清单

| 问题 | 状态 |
|---|---|
| 手机 App、相机型号、相机固件 | 已确认 |
| 实机声明的协议、服务与能力 | 已确认 |
| 局域网发现与描述读取 | 已实现并实测 |
| 实际认证与 PTP/IP 握手 | 已实现并实测 |
| 完整命令集与机型兼容矩阵 | 所需核心命令已有开源实现与本机验证，未覆盖全部命令 |
| 本机切后台断开的根因 | 未确认 |
| 拍摄、取景、ISO 调整与图片导入 | 已实现并实测 |
| 会话中断后的重连和图片续传 | 已实测，文件 SHA256 比对一致 |
| 完整视频与大文件传输 | 待实测 |
| iPhone App、iOS 后台任务与恢复体验 | 尚未实现到手机端 |
