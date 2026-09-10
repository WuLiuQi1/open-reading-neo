# 平板切页模糊性能优化

## 保持的行为

保留当前顶部 sigma 随 y 连续减小至零、16dp 清晰尾部、颜色、标题和导航分层、布局、切页动画以及旧后端降级。禁止靠关闭效果、减小模糊强度或稀疏采样来提速。

## 执行与验收

1. 先运行现有 Impeller 像素测试，记录原始边缘、棋盘、细条纹和 DPR 表现。
2. 验证高 DPR 下缩小滤镜中间纹理的方案，保持逻辑 sigma 与显示尺寸。若高频内容或清晰尾部退化，调整或放弃该方案。
3. 只删除无状态变化的重复切页完成重建，不改变动画或页面生命周期。
4. 独立进程串行运行像素测试（Impeller / Skia）、平板壳层及导航测试，执行全项目分析和 diff 检查。
5. 用同场景、同后端的前后渲染诊断量化收益；离屏渲染回读耗时不等于真机屏幕帧率。记录设备验证边界。

初始检查：源码位于 /Users/xiaoyuan/code/open-reading；当前工作目录仅有残留 l10n 目录。源码 checkout 唯一原有未跟踪内容为 coverage/，保持不动。现有 Impeller 五项像素测试通过。

## 最终实现

- 保持完整分辨率和全部连续离散高斯采样。Shader 将 UV 和单位采样方向的归一化移出循环；双轴边界钳制交给输入采样器已有的 clamp-to-edge。OpenGLES 同时反转 UV.y 和方向.y，sigma 仍由原始 y 决定。
- 引擎契约已在当前 Flutter 3.44.7 源码核实：`ReusableFragmentShader::SetImageSampler` 为两轴设置 `DlTileMode::kClamp`，`RuntimeEffectFilterContents` 只替换 sampler 0 的纹理，保留 descriptor。升级引擎时需要重跑边界及细条纹测试。
- `_completeTabTransition` 对已完成且无目标的相同页面直接返回，消除 `onPageChanged` 与 `animateToPage` 完成时的重复重建；保留中断动画的 token 和落页兜底。
- 下载按钮从监听整个控制器改为选择 `hasActiveTasks`，下载章节进度不再重复重建壳层；开始和结束仍刷新高亮。
- 缩小中间纹理的实验未采用：虽然原有测试通过，原图对比暴露接近清晰区约一物理像素的边缘偏移。最终代码未改变滤镜分辨率、权重、强度、动画、依赖或配置。

## 性能诊断

本机 Metal，1194×208dp 顶部，DPR 2/3，每轮预热 5 次、记录 50 次离屏渲染及 RGBA 回读。基线 shader 来自 `d718057`。同一 kernel、相同 widget 和输入纹理，只替换已编译的 shader 资产；三个批次交替前后运行，无并发测试。单位 ms：

| 批次 | DPR 2 原始/优化 | DPR 3 原始/优化 |
| --- | --- | --- |
| 1 | 8.616 / 9.120 | 21.695 / 18.798 |
| 2 | 10.774 / 9.555 | 21.642 / 19.122 |
| 3 | 16.634 / 8.859 | 21.634 / 16.927 |

DPR 3 各批中位数再取中位数：21.642 → 18.798ms，约减少 13.1%。DPR 2 波动较大，不声明稳定提升比例。包含回读和调度成本，不是屏幕帧耗时/FPS，不代表整个切页耗时，也不证明实体 iPad/Android 平板已经流畅。

### 复现 Metal 诊断

`tool/benchmark_tablet_backdrop.dart` 使用实际 `HomeTabletTopBackdrop`。此 Mac 的默认 `flutter test --enable-impeller` 是 SwiftShader Vulkan，不能替代 Metal 数据。显式编译 Metal runtime stage，再指定后端：

```sh
flutter build bundle --no-pub --debug --target-platform=darwin \
  --target=tool/benchmark_tablet_backdrop.dart --asset-dir=/tmp/tablet-blur-bundle
engine_dir=/Users/xiaoyuan/flutter/bin/cache/artifacts/engine/darwin-x64
"$engine_dir/impellerc" --runtime-stage-metal --iplr \
  --input=shaders/tablet_variable_gaussian.frag --input-type=frag \
  --sl=/tmp/tablet-blur-bundle/shaders/tablet_variable_gaussian.frag \
  --spirv=/tmp/tablet-blur.spirv --include="$engine_dir/shader_lib"
"$engine_dir/flutter_tester" --run-forever --enable-impeller \
  --impeller-backend=metal --disable-vm-service --non-interactive \
  --flutter-assets-dir=/tmp/tablet-blur-bundle \
  --icu-data-file-path="$engine_dir/icudtl.dat" \
  /tmp/tablet-blur-bundle/kernel_blob.bin
```

基线复测可用 `git show d718057:shaders/tablet_variable_gaussian.frag` 导出原 shader 到临时文件，修改 impellerc 的 input 即可，不需要改工作区生产文件。勿同时运行两份诊断。

## 效果与回归

原有场景导出的 RGBA 前后比较：最大单通道差异 2/255（DPR 3），最大全图平均差异约 0.019/255；关闭模糊图像一致。没有减少采样或改变核形状，仅有浮点运算次序差异。`TABLET_BLUR_PIXELS_DIR` 可导出像素供后续对比。

像素测试新增 DPR 2/3 细条纹、两个纹理轴的边缘钳制；平板壳层测试新增下载开始/完成高亮及连续进度通知不重建顶部的断言。所有状态化测试按文件独立进程串行执行。

### 最终验证结果

- Impeller 像素 6 项、Skia 像素 6 项、平板壳层 3 项、导航 7 项、焦点 2 项、下载控制器 4 项，共 28 项通过。
- `flutter analyze --no-pub`：No issues found。
- `git diff --check`：通过。
- 原有 coverage/ 保持不动；未改依赖、版本、发布配置。未执行实体平板 FPS、Android OpenGLES 真机或完整平台发布构建。

### 改动文件

- `shaders/tablet_variable_gaussian.frag`：采样坐标计算及边界处理。
- `lib/pages/home/home_shell_page.dart`：切页完成幂等。
- `lib/pages/home/parts/home_shell_layout_part.dart`：下载活动状态的选择性订阅。
- `test/home_tablet_top_backdrop_test.dart`：高 DPR 细条纹、边缘采样及可选 RGBA 导出。
- `test/tablet_home_shell_test.dart`：下载活动高亮与无效重建回归。
- `tool/benchmark_tablet_backdrop.dart`：独立离屏渲染诊断入口。
- `omx_wiki/tablet-variable-gaussian-blur.md`：更新当前采样契约和性能证据。
- 本文：执行计划、测量和验收记录。
