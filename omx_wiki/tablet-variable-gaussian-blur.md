---
title: "平板渐变高斯模糊"
tags: ["flutter", "tablet", "gaussian", "shader", "alignment", "渐变高斯模糊", "平板"]
created: 2026-09-07T05:15:06.626Z
updated: 2026-09-07T05:15:06.626Z
sources: ["git:725df2618a850f232935fbb78e65f8be435ab9f2", "docs/tablet-layout-redesign-plan.md"]
links: []
category: pattern
confidence: medium
schemaVersion: 1
---

# 平板渐变高斯模糊：已验收实现

2026-09-07 用户明确认可当前效果。代码提交：725df2618a850f232935fbb78e65f8be435ab9f2；平板布局及版本保存提交：7ae7b98；版本2.6.6。只保存到Git，不创建标签或Release。

## 设计约束与验收标准

- 高斯模糊的sigma随纵坐标递减，上方最强，往下连续归零；固定半径模糊叠加透明度淡出不能代替这个效果。
- 去掉整条厚重毛玻璃底色，不给顶部增加染色面板。标题和复用的悬浮导航绘制在过滤层上方，保持清晰。
- 保持平板统一1200dp外框及28dp内边距，标题与正文共用边界；窄窗和大字号允许两行布局。
- 用户特别重视严格对齐，当前视觉是后续调整基准。

## 实现入口

- lib/pages/home/widgets/home_tablet_top_backdrop.dart：高度与开关、Shader资源生命周期、DPR换算、降级。
- shaders/tablet_variable_gaussian.frag：按输出位置变化的高斯卷积。
- lib/pages/home/parts/home_shell_layout_part.dart：顶部过滤层与清晰控件分层。
- lib/pages/home/widgets/home_tablet_toolbar.dart：清晰标题及局部文字阴影。
- pubspec.yaml：Shader资源注册。
- docs/tablet-layout-redesign-plan.md：完整布局与演进记录；较早的透明度淡出方案已被本页所述方案替换。

## 算法与资源边界

clearHeight = max(0, height - 16dp)。顶部sigma取min(appBarBlur × 2, clearHeight / 3)，在clearHeight范围内线性减至0；末尾16dp直接返回源图。Shader参数换算为物理像素，最大sigma限128px、采样半径限384px。

使用可分离二维高斯：先纵向、后横向。横向采样保持同一y，因此同一输出位置的两个轴使用相同sigma；不要交换这两个pass。输入采样器使用线性过滤及双轴 clamp-to-edge；UV 与单位采样方向在循环外归一化。OpenGLES 同时反转 UV.y 和方向.y，不反转用于 sigma 曲线的坐标。该边界行为等价于原先每次读取前的半像素 UV 钳制。

每个离散源像素都进入3sigma核。用线性采样把相邻两个高斯权重合并为一次读取，在保持核形状的同时减少纹理读取。循环上限必须是编译期常量，运行时在半径处break，兼容所有编译目标。

当前Flutter引擎会替换ImageFilter.shader的sampler 0纹理，但保留采样描述。用1×1透明种子图像与FilterQuality.low配置线性过滤。该行为已核对当前引擎源码，但不是可跨版本盲信的契约；升级Flutter时必须重跑细条纹和DPR像素回归。

只缓存已完成的FragmentProgram；避免缓存跨widget测试fake async zone的Future。各实例持有、释放两份FragmentShader和种子Image；异步返回检查mounted，Picture用finally释放。加载中透明，加载失败或不支持Shader过滤时降级；主Shader分支必须排除_loadFailed，防止半初始化资源绕过降级。

旧Skia使用32段不同sigma的原生BackdropFilter近似，并非连续Shader实现；不要宣称不同后端完全相同。

## 已踩过的坑

1. 固定模糊加透明度擦除：留下清晰副本，视觉上像一条毛玻璃，无法通过边缘扩散宽度证明sigma递减。
2. 厚重surface渐变：遮住背景颜色，用户明确否定。
3. 49个稀疏采样点：大sigma时细文字与条纹发生重影、相位锁定；必须使用连续离散核或经过像素验证的等效方法。
4. 只测棋盘对比度：透明度混合也能通过，需要黑白阶跃边缘的扩散宽度，以及高频条纹测试。
5. 并行Flutter进程：共享native_assets目录竞争；状态化测试文件应独立进程串行执行。
6. 默认flutter test --enable-impeller在此Mac tester中使用静态SwiftShader Vulkan软件后端，不等于Metal硬件GPU性能。

## 复现验证

在仓库根目录顺序运行：
```sh
flutter test --no-pub --enable-impeller test/home_tablet_top_backdrop_test.dart
flutter test --no-pub test/home_tablet_top_backdrop_test.dart
flutter test --no-pub --enable-impeller test/tablet_home_shell_test.dart
flutter analyze --no-pub
git diff --check
```

2026-09-07实测：像素测试Impeller 5项、Skia 5项、完整壳层3项，共13项通过；全项目静态分析与空白检查通过。
像素断言覆盖边缘扩散递减、双轴棋盘、高频1dp条纹、DPR 1/2/3、末尾原图一致及关闭效果。壳层验证对齐、旋转、窄窗、大字号与滚动。

截图需同时配置TABLET_SCREENSHOT_DIR与TABLET_PREVIEW_FONT，例如Mac字体路径 /System/Library/Fonts/Hiragino Sans GB.ttc；TABLET_SCROLL_VIDEO=1可生成48帧滚动序列。无字体会出现测试Ahem方块。截图使用真实Flutter页面与测试数据，固定步长视频不代表帧率。

## 性能证据与限制

本机M2、明确指定Metal的1194×208dp离屏渲染加像素回读诊断：DPR2关闭/开启中位6.11/12.33ms；DPR3为10.06/28.81ms。这些只是当时环境的诊断值，不是屏幕帧率或实体平板表现；高DPR仍需真机profiling。未完成实体iPad/Android平板滚动性能验证，不可把截图或软件tester通过写成真机流畅性结论。

## 2026-09-10 保持效果的性能优化

完整分辨率、两遍卷积、采样点和权重不变，仅移除每次采样的重复坐标归一化及显式边界钳制。额外消除切页结束重复重建，并让下载导航状态只监听 hasActiveTasks。详见 `docs/plans/2026-09-10-tablet-blur-performance.md`。

三个批次交替测量的 Metal 离屏渲染加回读，DPR 3 中位数约 21.642 → 18.798ms（约减少 13.1%）。DPR 2 波动较大，未声明稳定收益。原始像素对比最大单通道差异 2/255；不代表实体平板帧率。缩图实验因近清晰区边缘偏移已放弃，未进入最终实现。
