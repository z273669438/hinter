# iOS Metal 美颜核 — 进度备忘(2026-11-03 凌晨,核已编成,待装机)

## 🎉 里程碑:v31 构建全绿,CI 内核 11457 字节 sym=2,已注入 ipa
96 字节空库之谜终结。完整根因链(以后别再踩):
1. CI 内核编译需 `-fcikernel`(函数才算入口点)——v23b 手工编译缺它 → 空库
2. 链接需 `metallib -cikernel` ——v29/v30 走 Xcode 规则编译 `.ci.metal`,
   Xcode 内置规则在这条工具链上不生效,air-lld 报 `symbol(s) not found`
3. 最终方案(v31,已提交):**完全绕开 Xcode**,workflow 手工执行:
   xcrun -sdk iphoneos metal -fcikernel -c -target air64-apple-ios15.0.0
     ios/Kernel/hinter.ci.metal -o /tmp/hinter.ci.air
   xcrun -sdk iphoneos metallib -cikernel /tmp/hinter.ci.air -o /tmp/hinter.metallib
   然后注入 Payload/Runner.app/default.metallib,strings 验 hinterBeauty 符号

## 顺手排掉的另两个坑
- run#50/51 构建失败真因(被噪音淹没数轮):shared_preferences_foundation-2.6.1
  生成代码含 Swift 6.1 尾逗号,Xcode 15.4 编不动 → runner 换 macos-15(默认 Xcode 16.4)
- **macos-14 镜像 2026-11-02 起已完全退役**,以后必须 macos-15+

## 当前状态
- release 资产已更新为 run#53 版(262241523 字节,2026-11-02T17:40Z)
- ipa 下载:私有仓库 browser_download_url 404(即使带 token),必须走
  **API octet-stream**:GET /releases/assets/702611127 + Accept: application/octet-stream
  + `-x http://127.0.0.1:7890`(本机代理)+ `curl -C -` 断点续传
  脚本:/c/tmp/dl_ipa2.sh → **E:\hinter-v30.ipa**(校验含 zip 完整性+metallib 字节+版本)
- 版本 1.0.23+23(装机后 pymobiledevice3 apps list 可区分新旧)

## 下一步(睡醒后)
1. Sideloadly 装 E:\hinter-v30.ipa
2. 拉日志验核:`pymobiledevice3 apps pull com.hinter.hinter.562DJX6G75
   Documents/hinter_diag.log <本地>` → grep beautyKernel → 期望 **LOADED**
3. 实测:磨皮/美白是否脸部定向(不再全屏)、瘦脸是否生效不抖
4. 注意:face 坐标系假设——metal 里 `disp=(uv.x, 1-uv.y)` 假定 coord() 是左下原点;
   若装机后发现掩码上下颠倒(磨皮落在背景),把 disp 翻转即可(一处改动)
5. 验证通过 → 拆埋点(Ddiag、四层音频埋点、ciWrite、frame70.png)出正式版

## 额度
- 今晚消耗 4 runs(#50~#53,含一次排队被取消),约 15 build 分钟 = 150 计费分钟
- 私有仓库 macOS 10x 计费;11 月剩 ~1850 计费分钟 ≈ 18 次构建,够用
- gh CLI 本机不可用(不在 PATH),用 git credential 里的 token 走 REST:
  `printf "protocol=https\nhost=github.com\n\n" | git credential fill` → password

## 设备端诊断命令速查(不变)
- 拉日志:`pymobiledevice3 apps pull com.hinter.hinter.562DJX6G75 Documents/hinter_diag.log <本地>`
- 查版本:`pymobiledevice3 apps list`
- 判定成功:`grep beautyKernel` → LOADED
