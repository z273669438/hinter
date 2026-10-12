# iOS Metal 美颜核 — 进度备忘(今晚收工快照)

## 当前设备状态
- iPad 装着 **v23b(版本 1.0.22,回退链)**:全屏滤镜美颜(可用但非脸部定向),跟读已修好(SENT 计数正常)
- 本机已有下载缓存:`E:\hinter-v23.ipa`(96B 空 metallib,装了也是回退,勿再装同类)

## 目标
脸部定向美颜 + 可用瘦脸 = hinter.metal 核真正加载成功(设备日志出现 `beautyKernel LOADED`)

## 失败链回顾(明天从这里继续)
1. v22d/e:手工 xcrun 编译报 `sampler2d unknown` / `destCoord undeclared`
2. v23b:sampler 成员 `sample(uv)` 语法通过,金属编译"成功"但产物 **96 字节空库**
3. v24:加 `-target air64-apple-ios13.0` 仍 96 字节 → 手工 xcrun 路线放弃
4. v25:改用 ruby xcodeproj 把 hinter.metal 注册进 Runner target,让 Xcode 编译
   - **失败点:`Register Metal source with Xcode target -> failure`(原因未查明)**
   - 候选原因:① `sudo gem install xcodeproj` 在 runner 上失败/已存在版本冲突
     ② 目标名不是 "Runner"(Flutter 模板可能不同)③ new_reference 路径写法
   - 明天先跑一个只 `ruby -e 'require "xcodeproj"; puts Xcodeproj::VERSION'` + 列 targets 的调试 job 定位

## v28 之后的进展(2026-10-12 收工)
- v26 证实 ruby 注册成功(METAL_REGISTERED,xcodeproj 可用)→ 失败点收敛为
  **Xcode 编译 hinter.metal 报错**,错误内容被 build 日志噪音淹没
- v28 已重写 workflow(之前 patch 事故把 yml 写坏 431KB,已修复+YAML 校验,
  **已推送远端**),report 步骤会把 metal 错误行+build.log 尾部强制发到 issue
- **10-12 起 macOS 分钟额度耗尽**(job 0 步骤秒失败)→ 等 11-01 重置

## 下月恢复只需两步
1. 触发:`gh api .../workflows/ios-release.yml/dispatches -f ref=main`
   (或仓库 Actions 页手动 Run workflow)
2. 读最新 MSTAT issue → 拿到 Xcode 对 hinter.metal 的真实报错 →
   针对性修一次 → 构建成功 → 验 MSTAT "METALLIB_INJECTED <数字>" > 2KB →
   断点续传下载 → 装机 → 拉沙盒日志确认 beautyKernel LOADED →
   装机验磨皮/美白定向+瘦脸 → 拆埋点出正式版

## 关键事实
- release tag: ios-test-1(每次构建覆盖资产);当前资产 631040483 = run45(空库版,无用)
- 构建状态自动上报:issue 标题 METAL-STATUS(含 metallib 真实字节数)——以 >2KB 为成功标志
- 下载通道:GitHub API 直连不稳,用 curl -L -C - 循环断点续传(已验证可断点续);用户重启电脑会中断循环,说"续传"可恢复
- 额度:GitHub Actions macOS 10x 计费,本月已用约大半;新周期若不够,先本地修好语法再构建

## 设备端诊断命令速查
- 拉日志:`pymobiledevice3 apps pull com.hinter.hinter.562DJX6G75 Documents/hinter_diag.log <本地>`
- 查版本:`pymobiledevice3 apps list`
- 判定成功:`grep beautyKernel` → LOADED
