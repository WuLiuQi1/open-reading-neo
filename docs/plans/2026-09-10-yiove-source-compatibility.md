# Yiove 书源兼容与分组删除修复

## 原始输入

- 合集地址：https://shuyuan-api.yiove.com/import/book-source-collection/f3f55c6e-723b-4055-b254-124c9d88c5cb
- 2026-09-10 下载文件：`/Users/xiaoyuan/Downloads/yiove-f3f55c6e-2026-09-10.json`
- 970 条原始记录，导入器去重后 965 条，5 条重复，JSON 解析错误 0 条。
- 文件大小：5,066,385 字节。
- SHA-256：`7854ed6202e75659ce40f297e364b53c8d0409adfde319d2477be63cb16a778b`。
- 参考代码：`/Users/xiaoyuan/code/legado-with-MD3` 中的 `AnalyzeByJSonPath`、`AnalyzeRule`、`AnalyzeByJSoup` 与书源类型定义。

## 已确认并修复的共享行为

| 触发规则或操作 | 修复位置与行为 |
| --- | --- |
| 米读章节 URL `{$.bookId}`、目录 `$.[*]` | `source_rule_json.dart` 支持嵌入 JSONPath 与旧根数组路径，复用规则分隔解析器处理引号中的花括号。 |
| 阅读助手 JavaScript 中的 `{{$.id}}` | `source_rule_engine.dart`、`source_rule_script.dart` 复用现有插值器，在执行脚本前用当前结果填充规则。 |
| 含插值的 JavaScript 被反向解析为静态书籍 URL | `source_runtime_catalog.dart` 在重建书籍变量和详情上下文时跳过脚本规则，避免把 `@js:` 当成 URI。 |
| 七猫 AES 规则的 `Arrays.copyOfRange` | `source_script_java_compatibility.dart` 提供 Java 数组切片与超出末尾补零行为。 |
| 万象书城 `kind: "0"` | `source_rule_html.dart` 将数字起始的合法末段当作属性，属性不存在时返回空值。 |
| 古典文学自定义 `attr` 地址旁的 `href="javascript:void(0)"` | `source_runtime_catalog_reading.dart` 仅保存可请求的 HTTP/HTTPS 备用地址，避免成功读正文后访问占位链接而失败。 |
| 文字源设置 `imageStyle: FULL` | `source_config.dart` 不再把图片显示宽度当作漫画类型；保留明确漫画类型和实际图片规则的识别。 |
| Mihomo 同时返回 IPv4、IPv6 Fake-IP | `book_source_network_policy.dart` 在既有 synthetic-DNS 显式选项下识别精确的 `fdfe:dcba:9876::/64`，复用系统网络客户端。默认策略与其他私网地址限制保留。 |
| 单删最后一个源，或批量删完全部源 | `book_source_registry.dart` 同时持久化空分组；`book_source_management_controller.dart` 刷新分组列表并清空失效的分组选中状态。部分删除、无效 ID 删除保留手动分组。 |
| 已有目录和正文缓存 | `reading_source_backend.dart` 规则修订号升为 3，旧修订 1/2 的磁盘缓存会重新解析。 |

采用共享引擎修复，没有增加依赖或按域名编写规则特例。工作区已有会员和界面修改保持原样；`source_runtime_test.dart` 中一个旧权限错误文案断言同步为当前 `unavailable` 文案。

## 验证方法与边界

- 相关自动化回归共 360 项通过；包含规则、脚本、运行时、源类型、网络、缓存和分组管理。全项目 `flutter analyze --no-pub` 无问题，`git diff --check` 通过。执行命令：

  ```sh
  flutter test --no-pub --concurrency=1 \
    test/source_rule*_test.dart test/source_script*_test.dart \
    test/source_runtime*_test.dart test/source_config*_test.dart \
    test/book_source_network_policy_test.dart test/source_http_transport_test.dart \
    test/source_cover_cache_test.dart test/reading_source_rule_revision_test.dart \
    test/book_source_registry_organization_test.dart \
    test/book_source_management_controller_test.dart
  ```

- 原始米读完整规则保存在 `test/fixtures/book_sources/yiove_midu.json`；合成响应覆盖搜索、详情、目录、正文以及真实出站 URL。
- 七猫原始 Java/AES 规则摘录使用固定合成密文验证；正文为原创测试文本。
- 分组测试覆盖持久化重载、最后一个源、批量删除、部分删除、无效删除，以及管理控制器状态。
- 网络测试覆盖精确 IPv6 `/64`、相邻私网拒绝和实际 transport 路由选择。
- 在线抽测直接使用下载的规则。古典文学的测试关键词设为“论语”，仅用于选择匹配题材，没有修改其解析规则。
- 在线诊断工具即使输出 `FAIL`，测试进程也可能退出成功；结论以每个源的阶段结果为准。
- 静态可导入或兼容性分类不代表全部源可在线使用。HTTP 403、原站返回空结果，以及需要原生 WebView 的源分别记录，不能算作全文链路通过。
- 这次没有安装 macOS/iOS 新包或进行实体设备操作；平台共享逻辑通过自动化验证，原生 WebView 与设备界面仍需安装后实测。

## 在线抽测结果

| 原始书源 | 验证结果 |
| --- | --- |
| 阅读助手（优+++） | 搜索、详情、1,663 章目录与首章解密正文通过；正文 2,746 字符。 |
| 书海阁小说 | 搜索、详情、603 章目录与首章正文通过；正文 5,047 字符。 |
| 万象书城 | 搜索、详情、1,646 章目录与首章正文通过；正文 3,388 字符。 |
| 古典文学（优） | 搜索“论语”、详情、16 章目录与首章正文通过；正文 467 字符，不含图片。 |
| 零点看书（优） | 原站请求 HTTP 403。 |
| 饿狼小说、爱下、五六中文、包电子书 | 测试进程缺少原生 WebView 插件，未验证设备端结果。 |
