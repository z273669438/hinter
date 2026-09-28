# Hinter 口播提词器

跨平台(iOS / Android)短视频口播提词器:**本地语音识别自动跟随换行 + 实时美颜相机 + 美颜录制**。

技术栈:**Flutter(Dart)+ sherpa-onnx(端上流式语音识别)+ 原生 GPU 美颜管线**。

## 功能

| 功能 | 说明 |
| --- | --- |
| 提词器 | 悬浮字幕层,当前行高亮居中,支持镜像预览、字号、上/下方位置、区域高度调节 |
| 语音跟随换行 | 端上流式识别(中英双语),念完一行自动滚动到下一行并高亮;支持跳行检测、点击纠偏、灵敏度调节 |
| 本地语音模型 | sherpa-onnx 流式 Zipformer(int8,约 190MB)**已随 App 打包**,首次进入口播页自动解包到应用目录,全程无需下载、无需联网 |
| 美颜相机 | 实时磨皮(边缘保留)/ 美白 / 红润 / 亮度 / 饱和度,全部 GPU 着色器实现,可实时调节 |
| 录制 | 美颜画面 + 麦克风音轨合流为 MP4(竖屏 720p);点停止后自动写入系统相册「影片/Hinter」(iOS 存「相簿 Hinter」) |
| 跟读联动 | 点开始录制后自动开启语音跟随,无需手动切换 |
| 脚本管理 | 多脚本、按标点自动分行、分行预览、跟读灵敏度按脚本记忆 |

## 架构

```
lib/                          Flutter UI 与业务
  pages/                      首页 / 编辑 / 模型管理 / 口播页
  widgets/                    提词字幕层 / 美颜设置面板
  services/
    asr_engine.dart           sherpa-onnx 流式识别封装(16k int16 PCM)
    line_follower.dart        「念到哪跟到哪」模糊匹配算法
    camera_controller.dart    原生美颜相机通道封装
    model_downloader.dart     模型下载(HF 官方源 + 国内镜像自动回退)
    script_store.dart         脚本持久化(JSON 文件)
android/.../camera/
  HinterCameraPlugin.kt       方法通道 + 事件通道 + Flutter Texture
  CameraEngine.kt             Camera2 采集(前后摄 / 尺寸 / 传感器旋转)
  BeautyRenderer.kt           OpenGL ES 三趟美颜着色器(旋转 → 双向高斯 → 边缘保留合成)
  AudioEngine.kt              麦克风唯一持有者:48k 录制抽头 + 16k 识别流
  Recorder.kt                 H.264 + AAC → MediaMuxer MP4
ios/Runner/AppDelegate.swift  同一套能力的 iOS 实现
  (AVCaptureSession + Core Image 自定义 Metal 核 + AVAssetWriter)
```

**为什么原生层统一持有麦克风:** 口播需要「边录边识别」。若 Flutter 侧录音用于识别、原生侧再开一路录音用于录制,双路抢占麦克风在不同系统上不可靠。所以麦克风由原生插件唯一持有:48kHz 一路编码进 MP4,降采样到 16kHz 通过 `hinter/mic` EventChannel 推给 Dart 供 sherpa-onnx 识别。

**预览镜像说明:** 前摄预览的镜像在 Flutter 层做(`Transform` 翻转),因此**录制出的成片不镜像**,符合观众视角。

## 语音跟随算法(增量对齐器)

1. 整篇脚本归一化(去标点/空白/小写)成一条字符流,维护「已读指针」;
2. 识别转写(定稿 + 实时 partial)归一化后整体替换进对齐器(**不累加**,避免重复),两个指针增量对齐;
3. 字符相同 → 双指针前进(字幕的琥珀色光标跟着走);
4. 失配时做有界容错:双字锚定跳过误识别/多字,或跳过用户漏念的脚本字;连续失配超预算(由「灵敏度」决定)则回滚到最近锚点等待,绝不瞎跑;
5. 高亮与滚动位置由指针换算,与字号、换行方式无关;点击字幕可手动跳转(同时清空识别上下文重新对齐)。

`test/line_follower_test.dart` 覆盖了流畅跟读、带错字转写、跳句、手动跳转等场景。

## 构建运行

```bash
flutter pub get
flutter run            # 连接真机(需要相机/麦克风权限,模拟器美颜性能不真实)
flutter build apk      # Android
flutter build ios      # iOS 需在 macOS + Xcode 上执行
```

- Android:minSdk 由 Flutter 决定(≥24),需真机有 CAMERA / RECORD_AUDIO 权限(应用内会请求)。
- iOS:iOS 13+,首次构建会经 CocoaPods 拉取 sherpa-onnx iOS 库。
- 语音模型:已随 App 打包(assets/models,构建 APK 会包含约 190MB),无需任何下载操作;App 安装后首次进入口播页自动解包并加载。
- 录制画质档位:美颜面板内选择(720p/1080p/2.5K/4K,列表按当前摄像头硬件支持生成),默认 1080p,传感器优先选 16:9 模式;预览用等比 cover 裁剪,任何档位下都不会拉伸。
- 调试后门(开发者用):`adb shell am start -n com.hinter.hinter/.MainActivity --ei debug_rot 90` 可强制预览旋转角,用于在新机型上快速定位方向问题;logcat 过滤 `HinterCamera`/`HinterRenderer` 可看档位选择与帧流诊断日志。
- 提示:因为内置模型,安装包体积约 200MB(debug 版更大);若换用其它模型,替换 assets/models 下 4 个文件并同步修改 ModelSpec.sizes。

## 已知边界

- 语音模型默认为中英双语流式 Zipformer;若需要其他模型,`model_downloader.dart` 里的文件清单和 `asr_engine.dart` 的文件名可以按 sherpa-onnx 文档替换。
- 美颜为单层着色器方案(非商业 SDK 的精细人脸关键点方案),日常口播效果自然,但不含瘦脸/大眼等变形类功能。
- iOS 代码未在本机验证编译(本机为 Windows),建议在 macOS 上首次构建时如有小问题按 Xcode 提示修正。
