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

## 关键事实
- release tag: ios-test-1(每次构建覆盖资产);当前资产 631040483 = run45(空库版,无用)
- 构建状态自动上报:issue 标题 METAL-STATUS(含 metallib 真实字节数)——以 >2KB 为成功标志
- 下载通道:GitHub API 直连不稳,用 curl -L -C - 循环断点续传(已验证可断点续);用户重启电脑会中断循环,说"续传"可恢复
- 额度:GitHub Actions macOS 10x 计费,本月已用约大半;新周期若不够,先本地修好语法再构建

## 设备端诊断命令速查
- 拉日志:`pymobiledevice3 apps pull com.hinter.hinter.562DJX6G75 Documents/hinter_diag.log <本地>`
- 查版本:`pymobiledevice3 apps list`
- 判定成功:`grep beautyKernel` → LOADED
