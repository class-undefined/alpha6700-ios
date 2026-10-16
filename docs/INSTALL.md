# 安装与 7 天续签

## 本次安装

2026-10-16 已在现场 iPhone 上成功构建、签名、安装和启动。签名描述文件的 `LocalProvision` 为 `true`，有效期为 2026-10-16 21:10:56 至 2026-10-23 21:10:56（Asia/Shanghai）。这是本次实际文件中的日期，不是对以后安装的固定承诺。

## 首次准备

1. 安装完整 Xcode 26 或更新版本。命令行 `xcodebuild -version` 应能读取版本。
2. 在 Xcode → Settings → Accounts 登录自己的 Apple Account。免费账号对应 Personal Team。
3. 用数据线连接 iPhone，完成信任电脑，打开开发者模式。初次运行时按手机实际提示信任开发者。
4. 安装 Go。首次构建需要下载 `go.mod` 指定的工具链和模块。
5. 用 `git clone --recurse-submodules` 获取项目。已克隆时运行 `git submodule update --init --recursive`。
6. 在 `ios/Local.xcconfig` 填写 `DEVELOPMENT_TEAM`。这个文件不进入 Git。Bundle ID 可按需改成自己唯一的值。

免费账号当前最多允许 3 个开发 App / 设备、3 台设备和 10 个 App ID，描述文件 7 天到期。以 [Apple 账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account) 为准。遇到数量上限时，选择自己不再需要的开发 App 处理；安装脚本不会删除其他 App。

## 构建、安装和续签

```sh
scripts/install-device.sh
```

有多台设备时传入 `xcrun devicectl list devices` 返回的标识：

```sh
scripts/install-device.sh DEVICE_IDENTIFIER
```

脚本调用 Xcode 自动签名。每次运行都会打印描述文件的创建与到期时间。有效期内 Xcode 可能复用旧文件；到期时重新生成，再覆盖安装。

续签必须使用同一团队和 Bundle ID，以保留 App 数据及 Keychain 访问。不要先卸载 App。安装之前可通过“文件 → 我的 iPhone → α Remote → Imports”另存重要原文件。

本版本不安装定时任务，也不能在 iPhone 上自行签名。需要 Mac 定期执行安装命令，或在 Xcode 中重新运行。工程不需要付费账号专属 entitlement。

## 相机认证

优先在 App 中填写认证信息。IP 可从机身网络菜单读取，也可使用 App 的局域网查找。相机和 iPhone 必须能互相访问；访客 Wi-Fi 的终端隔离可能阻止连接。

如果这台 Mac 已有本项目早期原型保存的 Keychain 项，可以迁移到已安装的 App：

```sh
/usr/bin/python3 scripts/import-local-access.py DEVICE_IDENTIFIER
```

脚本使用 `bin/SonyCameraAccess --read`，凭据经临时文件和 Apple 配对设备通道传送，不打印内容。Mac 临时文件权限为 `0600`，传输后删除。App 下次启动后存入 `ThisDeviceOnly` Keychain 并删除手机临时文件。如修改了 Bundle ID，传入 `--bundle-id`。

这只是本机迁移入口；仓库中没有相机密码、手机 UDID、Team ID 或签名证书。没有旧辅助程序时直接在 App 填写，或用 `swiftc local-auth/CameraAccess.swift -o bin/SonyCameraAccess` 构建旧工具。

## 常见问题

| 现象 | 处理 |
|---|---|
| 首次连接失败后出现局域网权限框 | 允许访问，再连接一次；系统可能先拒绝最初的网络请求 |
| 指纹不匹配 | 按机身访问认证信息核对；不会忽略指纹继续认证 |
| 设置项只读 | 检查机身模式和镜头；App 只开放相机当前允许写入的项 |
| 相机拒绝存储卡访问 | 等机身空闲，退出其他遥控会话后刷新 |
| 缩略图空白 | 可能是拍摄内容为黑色或该格式未被系统解码；原文件仍可导入 |
| 相机取景全黑 | 先检查镜头盖、镜头和曝光；本次能解码黑色画面不等于已验收所有拍摄场景 |
| 保存到“照片”失败 | 系统照片可能不接受某些 RAW / 视频格式；通过分享保存原文件，Imports 中的文件保留 |
| 切到后台后断开 | 这是当前恢复策略；返回前台重连，不承诺后台永久在线 |
| App 过期不能打开 | 保留 App，运行安装脚本覆盖安装，检查实际到期时间 |

手机 UI 自动化测试还需要“设置 → 开发者 → 启用 UI 自动化”，启动测试服务时可能要求用户在手机完成身份验证。日常使用 α Remote 不需要运行自动化测试服务。
