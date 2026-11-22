# iOS 恢复 fvp 播放后端

日期：2026-11-22（Asia/Shanghai）。分支：`feat/fpv-port-ios`。目标是在单包里恢复 iOS 的 fvp／MDK 播放后端，其他平台继续使用 media_kit，并由 CI 产出未签名 IPA。

## 基线与固定项

- 代码基线：`11e9da4c06e9e8da7a9f567a25f34722f507ba83`（1.3.0+5，Flutter 3.50.0，media_kit fork `302d60ee`）。调查时远端 `master` 已前进到 `2f53940c`；本分支按用户指定基线建立，未混入后续提交。
- FPV 资产来源：`87ac2be45ad6051fd8ba13a917a78f1415775a97`（1.2.9+1）的 `native/fvp`、Apple 渲染补丁与 CocoaPods 脚本。
- fvp 固定 `e81637411c58a9ae28de246ee73ad06e3418f10e`（0.40.0），要求 Dart `^3.4`、Flutter `>=3.22`。
- MDK 固定 0.39.0 Apple SDK，URL／SHA-256 见 `native/fvp/assets.lock.json`；CocoaPods 按摘要校验后使用。
- `flutter.config.enable-swift-package-manager: false` 保持不变，继续走 CocoaPods。

## 阶段一：原生依赖与链接

`pubspec.yaml` 恢复 fvp git 依赖与 `native/fvp/*` 资产；`packages/bili_player` 恢复 fvp、`code_assets`、`hooks`、`native_toolchain_c` 与 ffigen 开发依赖；恢复 MDK C 头文件、音频时钟桥接、原生资产 hook 和 `tool/prepare-fvp-apple.py`。

`ios/Podfile` 增加 `pod 'mdk', :podspec => '../native/fvp/mdk.podspec'`，并在 Flutter pods 之后执行：

1. `prepare-apple-media-libs.py ios`：验证并暂存固定 mpv 框架；
2. `prepare-fvp-apple.py ios`：校验 `FvpPlugin.mm` 原文摘要，替换为 `native/fvp/apple/metal_texture.inc` 的“完成后一次性发布 IOSurface”实现，并把 podspec 的源文件匹配收紧到源码扩展名。

`tool/verify_fvp_ios.py` 在构建前检查 git ref、SPM 开关、资产清单、Apple 归档摘要、Podfile 与许可文件；`tool/test_ios_fvp.py` 覆盖缺失资产、错误 ref、SPM 开启和未固定 SDK。`tool/build-release.ps1` 在 iOS 包内校验 `mdk.framework`、`fvp.framework`、`Podfile.lock` 的 mdk 版本、`MinimumOSVersion >= 15.0` 以及 fvp 许可资产，并检查最终 IPA 的 Payload 布局。

**硬门槛状态：未在本环境通过。** 本会话运行在 Linux 沙箱，没有 macOS、Xcode、CocoaPods 或 iOS 设备，无法执行 `pod install`、iOS 链接或 1080p 实机起播。已用 g++ 编译音频桥接、用固定 fvp 源模拟并通过 `prepare-fvp-apple.py`，核对 MDK Apple 归档 SHA-256 与 `assets.lock.json` 一致，并确认 `mdk.framework`（iOS arm64）与 media_kit 的 `Mpv.framework` 都是 Mach-O 动态库；因此重复符号风险主要不在静态链接，而在两份动态 FFmpeg 的共存与包体大小。实际链接、pod 解析与 Flutter 3.50 编译结果仍必须由 macOS CI 或本机 Xcode 给出，不能据此宣称阶段一通过。

## 阶段二：后端契约

新增 `fvp_backend.dart`、`fvp_engine.dart`、`fvp_native_player.dart`、`fvp_buffer.dart`、`fvp_seek.dart`、`fvp_playback_information.dart`、`fvp_video_decoders.dart`、`fvp_video_output.dart` 与生命周期计数。

契约映射：

- `open/close`：`preparePaused` 创建全新的 MDK player（DASH 分轨时另建音频 companion），在暂停态完成 prepare、轨道、缓冲窗口、请求头、解码器和音量／增益；失败由共享引擎统一失败与释放。
- `play/pause/seek/倍速/音量/增益`：命令直接落到两个 native player；暂停等待 native `paused`，EOF 保留原生停止事实；seek 复用 1.2.9 的暂停、目标确认、音频 companion 对齐与可取消重试。
- 位置／时长／缓冲：250 ms 采样事件，位置取 MDK 呈现时钟，缓冲端点取视频与音频队列在媒体时间轴上的交集并夹在时长内；`buffered` getter供共享引擎的缓存 seek 与零缓冲判定使用。
- 纹理：`confirmVideo` 创建新的 Flutter texture 并绑定尺寸；`confirmPresentation` 等待两帧呈现；DASH 外部音频由 FFI 音频主时钟驱动视频同步。
- 音轨／字幕：DASH 分轨由 companion 播放音频，视频管线禁用内嵌音频；静音预览禁用音轨；字幕默认关闭（应用层弹幕／字幕渲染保持不变）。
- 错误与事件：`buffering/buffered/ended/audioEnded/invalid` 映射为共享契约事件；`audioEnded` 标记为 `videoInterrupted`；网络中断由共享引擎的三秒重试与零缓存判定接管。
- 会话代次：`BackendEvent` 新增可选 `generation`；FVP 适配器的所有异步回调、采样事件和失败事件都带会话代次，共享引擎同时校验事件代次与 backend 身份，旧会话回调直接丢弃。适配器不复用 player／texture，每次打开都新建。

设置：`PlaybackBackendPreference` 恢复 `fvp`；iOS 默认 fvp，其他平台默认 media_kit。设置页仅在 iOS 显示“播放后端”，可切回 media_kit。设置快照版本升到 54：1.2.9（schema 45）保存的 `fvp`／`mediaKit` 是明确选择，二者都保留；1.3.x（schema 46–53）只有 media_kit，写入的 `mediaKit` 不是选择，iOS 升级时迁移为 fvp；schema 54 起显式 `mediaKit` 保留。非 iOS 读取到历史 `fvp` 时归一化为 media_kit，未知值回退到当前平台默认。后端在每次打开前按保存值选择，切换后旧引擎完整释放再创建新引擎。

## 阶段三：生命周期

- `FvpBackend.dispose`、`FvpPlayerPort.dispose` 都是单飞 Future；重复调用返回同一 Future。
- 释放顺序：停止采样 → 取消事件订阅 → `output.clear()` 解除 Flutter 纹理绑定 → 等待进行中的 player 创建 → `player.dispose()` → 销毁 output 与事件流。共享引擎在创建新 backend 前等待旧 backend 的 `dispose()`。
- 不实现 `ReusablePlaybackBackend`，禁止跨会话复用 player、纹理或 companion。
- `FvpLifecycle` 提供 backend/player 的创建数、活跃数、销毁数、孤儿数，并记录 `backend-create`、`backend-bind`、`backend-unbind`、`backend-dispose-start/end`、`player-create`、`player-dispose-start/end`，日志走 `dart:developer` 的 `bilisail.fvp`。
- 原生销毁先 `interrupt()` 清空 media 并停止管线，再 `disposeAsync()` 等待 10 秒；音频 companion 并行释放，避免把打开预算翻倍。若纹理创建仍在飞行，则不删除 native player：先最多等 2 秒，超时后把删除延迟到 `CreateRT` 返回之后再执行，避免迟到的纹理回复包装已释放的 handle。原生销毁超时后不再次调用 `disposeAsync`（会双释放），而是把 native handle 标记为孤儿、永不复用、继续观察其完成；引擎可立即重建新实例，迟到的原生销毁完成后再释放 FFI 时钟与观察器。iOS 进程内无法强杀 MDK 线程，这是“强制回收并重建”的边界；真正杀死原生实例只能依赖进程退出。

## CI 与产物

`.github/workflows/ci.yml` 的 iOS 矩阵目标新增：

- `Verify iOS FVP/MDK configuration`：构建前运行 `python3 tool/verify_fvp_ios.py`；
- `Collect iOS FVP diagnostics` / `Upload iOS FVP diagnostics`：上传固定清单、`ios/Podfile.lock` 与 App Frameworks 列表；
- 既有 `tool/build-release.ps1 -Target ios-arm64` 继续执行 `flutter build ios --no-codesign`、拷贝 `THIRD_PARTY_NOTICES.md`、生成未签名 IPA 并校验 Payload。

产物名沿用 `BiliSail-ios-arm64-<version>-packages`，其中 IPA 为 `BiliSail-<version>-ios-arm64-unsigned.ipa`；版本由 `pubspec.yaml`（当前 1.3.0+5）决定。本会话没有 GitHub 凭据，未能推送分支、触发 CI、创建 PR 或读取 artifact 大小。

## 已执行的本地验证

- `dart analyze`：根 `lib`、`packages/bili_player` 全包、全仓 `flutter analyze --no-pub` 均无问题。
- `dart format --set-exit-if-changed`：全仓通过。
- `packages/bili_player` 全量测试：290 通过、10 跳过（跳过项为无原生库／Swift 工具链的环境用例）。
- 新增 FVP 测试 9 项：打开／播放／暂停／seek／倍速／音量／增益、代次采样与缓冲事件、单飞释放、失败释放、结束与非法状态、网络错误到 networkOpen 的映射、取消 seek 不触发失败、MDK EOF seek 码归一化、零缓存端点信号；共享引擎新增“旧代次事件被丢弃”1 项。
- 设置与播放定向测试：405 项通过，包含 iOS 默认 fvp、历史 fvp 保留、非 iOS 回退 media_kit、设置页切换和旧字段清理。
- `tool/verify_fvp_ios.py` 与 `tool/test_ios_fvp.py`（5 项）通过；`prepare-fvp-apple.py` 在固定 fvp 源上成功生成暂存 pod；音频桥接 C++17 编译通过。

以上均为 Dart／Linux 侧证据，不等同于 iOS 原生链接或设备播放。

## 待执行的验收

设备与 CI 就绪后按以下顺序执行；任一项失败都不得宣称本次移植完成：

1. macOS：`flutter pub get`、`cd ios && pod install`，确认 `Podfile.lock` 含 `mdk (0.39.0)` 与 `fvp`；`flutter build ios --no-codesign` 无重复符号、无未解析 MDK 符号。
2. 安装未签名 IPA（重签后）到真机，默认后端播放 1080p H.264，确认起播、音画同步、暂停／seek／倍速。
3. 4K H.264 连续播放 30 分钟不崩；记录 `bilisail.fvp` 日志与实例计数。
4. 长按 2 倍速 30 分钟不崩。
5. 空间页进入视频 A → 返回 → 视频 B，连续 5 次不崩；确认每次 `backend-create/backend-dispose-end` 成对且 active 回到 1。
6. 1080p 回归；设置切到 media_kit 后同一视频仍可播放；再切回 fvp。
7. 记录 CI run 链接、IPA artifact 名称与字节大小，附已知问题。

## 已知问题与边界

- 阶段一硬门槛未在本会话执行，因而没有 pod install 结果、iOS 链接结果、真机 1080p 起播、CI run 或 IPA 大小。
- fvp 仍是全局 Flutter 插件依赖：非 iOS 构建会注册 fvp（以及 `video_player_avfoundation`）并可能编译／打包未使用的 MDK。默认后端仍是 media_kit，Android 独立 worker 未恢复；如果必须让非 iOS 产物完全不包含 fvp，需要后续单独做 flavor／依赖隔离，本次按“先单包双后端”要求未拆。
- iOS 进程内原生销毁超时只能隔离并重建，不能像 Android 独立进程那样强杀；孤儿计数与日志用于定位，最终回收依赖原生 future 或进程退出。孤儿期间可能出现短暂的两个 native player 并存，但旧纹理已解绑且旧 handle 永不复用。
- 1.3.x 的强制 media_kit 快照在 iOS 升级时会迁移为 fvp；1.2.9 的显式选择保留。若用户希望升级后继续 media_kit，需要在设置中重新选择一次。
- MDK Apple 纹理为 BGRA8 IOSurface；HDR／杜比视界的色调映射未在本次验收范围，异常时应切回 media_kit。
- 4K／倍速／空间页连续 5 次／1080p／切回 media_kit 的设备验收尚未执行。
