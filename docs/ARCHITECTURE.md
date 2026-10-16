# 原生客户端架构

## 数据路径

```mermaid
flowchart LR
    UI[SwiftUI / Liquid Glass] --> Model[MainActor 状态模型]
    Model --> Bridge[串行后台队列 / C ABI]
    Bridge --> Core[Go 静态库]
    Core --> SSH[SSH 指纹认证]
    SSH --> PTP[相机 PTP 命令与事件]
    SSH --> LV[相机 HTTP JPEG 取景]
    Core --> Disk[导入文件与分段清单]
    Model --> Keychain[iOS Keychain]
```

Go 编译为 iOS `c-archive`，由 Xcode 链接到 App。它是同一进程中的原生机器码，不是 WebView、外部进程或 Mac 服务。界面、权限、生命周期、照片图库和分享全部使用 Apple 原生 API。

## 边界与并发

`CameraCreate` 创建引擎，使用持久化 GUID 标识客户端。`CameraRequest` 接受内部 JSON 请求并返回 JSON 结果。Swift 在后台串行队列执行阻塞请求，在主线程更新界面。所有 C 返回的内存经 `CameraFree` 释放。

相机命令序列由 Go 互斥锁保护。Swift 请求调度按传输、交互、清晰预览和缩略图排序，仍然只执行一个 PTP 事务。取消尚未执行的预览不会中断正在写入的相机命令。取景通过独立 SSH 通道读取，只保留最新一帧，界面约每 66 ms 取一帧。事件缓存最多 80 条。属性轮询每 2 秒一次，导入与写操作期间暂停轮询，避免积压。

`CameraAbort` 可从另一线程取消网络工作。Swift 使用会话标识忽略过期连接与导入结果。后台时主动断开；前台重连使用相同 GUID，重新握手和读取能力。快门、录像、删除、恢复和上传没有重试队列。

## 参数与控制

读取所有属性后，界面展示当前值、可写状态、枚举或范围。写操作重新读取描述；检查 `Writable`、`Enabled`、数值位宽、枚举成员和范围步长。写后短暂轮询，只有读回一致才报告完成。

64 位原始参数以字符串通过 JSON 边界，避免经过浮点数时丢失精度。字符串、数组和标量保留原始类型。快门的高低 16 位分别是分子、分母；ISO 保留感光度与模式位。特殊光圈值与无效水平角不显示成普通数值。

静态目录提供 783 项名称，优先保留 alpha2go 的已核对条目，再为其余代码补名称。目录不包含机型支持标记、写入范围或额外控制命令。控制项只使用已知类型的 8 类操作，按机身声明和当前状态检查。

## 文件与恢复

每个导入任务包含相机身份、内容 ID、文件 ID、路径、创建时间、大小和 UMID。任务键由这些字段计算。续传传入原任务键，机身当前文件不匹配时拒绝继续，避免把更换存储卡后的同编号文件拼接到旧文件。

分段支持 2 / 4 / 8 / 16 MiB；默认值以手机测速结果选择。离开取景页和导出时停止实时流，导出期间不排入新的缩略图。只有相机完整响应并确认后，才更新已提交偏移。中途失败截掉本段尾部；进程重启时也截到清单中已提交的位置。文件写入和清单分别执行同步与原子替换。

下载时流式计算 SHA256，完成后将文件暴露为最终名称。恢复时只重算已提交的前缀；失败分段使内存中的哈希失效，重试前重建。保留分段文件到完成清单提交之后，缩小崩溃时的恢复窗口。清单中的本机绝对路径会按当前 App 数据容器重新解析，支持覆盖安装后容器路径变化。

首次恢复连接会重新读取媒体列表。10,919 组影像已在现场 iPhone 跨页读取；更多内容、列表变化和相同时间戳的分页边界仍需额外验证。系统照片不支持的格式仍可通过文件分享导出。

## 取景布局与全屏

Live 使用平面黑白相机 LCD 样式，不用玻璃按钮。普通竖屏使用屏幕全宽；全屏隐藏导航并请求横屏。相机原始画面按比例完整显示，源 JPEG 分辨率不变。

`ViewfinderGeometry` 统一计算画面区域。图像、网格、对焦框和点按映射都使用同一矩形；留黑区域不产生对焦请求。参数按钮与画面点按层分开，触摸控件不会触发对焦。全屏使用公开的 `UIWindowScene.requestGeometryUpdate`，退出后恢复进入前方向。

## 批量格式导出

`ExportPlanner` 是不依赖 UI 的格式筛选器。`ExportStore` 持久化任务、来源文件身份、输出格式、相对路径和当前批次。任务执行时格式固定，修改偏好只影响新任务。恢复保留已完成成员，以保持批次进度含义。

JPEG 优先选择机身已有文件。需要转换时使用串行原生解码队列，按原始尺寸生成 JPEG，另存到 Exports。原始文件仍由既有 Go 传输引擎管理，预览缓存不参与导出。完整规则和验收见 [EXPORTS.md](EXPORTS.md)。

## 图片与手势

全屏浏览使用 `UIPageViewController`，只保留当前及相邻页面。每页以 `UIScrollView` 缩放；放大时由图片处理平移，复位后恢复左右翻页。双击在适配尺寸和 3 倍放大之间切换，双指支持连续缩放。

网格用 thumbnail，打开照片用 screennail。相机字节直接写入按文件身份命名的缓存文件，Swift 获取路径后由 ImageIO 在后台解码，不经过 Base64。磁盘预览缓存限制为 256 MiB，内存分别限制缩略图和大图，收到内存警告时清理。

原图下载保留全部原始字节。RAW 使用 Apple `CIRAWFilter` 解码，队列串行处理；不受支持时标明使用内嵌预览。显示时解码上限为 4096 像素，控制 RAW 内存占用；界面展示实际预览像素尺寸，避免把缩略图称为原图。视频下载后交由系统播放器处理。

## 拟真参数控制

刻度滚轮使用相机实际允许的值，中心吸附、触感反馈和可访问性步进均对应同一组值。只有用户滚动停稳或点选刻度才写入；初始化位置和机身状态更新不会发送命令。一个参数写入期间只保留最新待提交目标，既保持手势响应，也避免排队重放旧值。

## 凭据与公开仓库

密码存入 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` Keychain，不进入 UserDefaults。相机指纹核验发生在密码发送之前。错误输出替换凭据和相机 HTTP 地址。

原始影像、个人证据、构建产物、手机标识、签名文件与 `Local.xcconfig` 均不进入 Git。App 不发送遥测。局域网发现只扫描本机私有 IPv4 网络中的 /24 候选，再读取 Sony 元数据，不在发现阶段发送密码。

## 构建与测试

`build-core.sh` 根据 Xcode SDK 和架构生成静态库。当前现场构建验证的是 Apple Silicon Mac 的 arm64 模拟器和 arm64 真机。Intel 模拟器编译路径存在，但未实测。

核心测试覆盖参数约束、64 位数值、分段失败回滚、超过 4 GiB 的偏移、空卡请求、删除确认、导入持久化和身份变化。`go test -race` 检查并发访问。SwiftUI 测试检查断连状态、连接表单和四页导航；截图从 xcresult 导出后人工查看。

## 设计参考

原生玻璃组合参考 [Apple 自定义视图 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) 和 [Liquid-Glass-Examples](https://github.com/pchelnikov/Liquid-Glass-Examples)。未复制该项目界面代码。

快门编码交叉核对 [libgphoto2 的 Sony 配置实现](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/config.c)，未引入其代码。光圈特殊值、ISO 模式与名称表交叉核对 [mikefsq/ptp](https://github.com/mikefsq/ptp/blob/0fe3c68516f8c0fe89c963437bbc385d68620b25/sony/exposure.go)。引入的名称数据保留 MIT 许可。
