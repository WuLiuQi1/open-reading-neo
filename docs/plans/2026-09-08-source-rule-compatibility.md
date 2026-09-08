# Legado 书源与漫画源通用规则兼容性

## 范围与验收

参考本地 `legado-with-MD3` 的实际执行语义，使用用户提供的书资源定位通用兼容性缺口。
分别验证搜索、详情、目录、正文与漫画图片；离线规则正确、在线站点可用和真机表现是独立证据。
不修改版本号、不发布、不覆盖当前工作区已有的书源导入和 WebDAV 修改。

## 修改前的修复与清理计划

1. 盘点样本并运行现有规则回归，按 HTML/JSON/XPath、脚本、请求和漫画阶段定位差异。
2. 为确认的差异先补失败回归，记录本地 Legado 参考位置和样本规则形式。
3. 在已有 rules、scripting、runtime/request 路径内修正语义；不建立第二套规则引擎，不添加依赖。
4. 每项修复同步删除被替代的分支、重复解析和未使用辅助函数，不保留废弃实现。
5. 将兼容性回退区分为有测试的边界处理和掩盖错误的默认值；只在证据充分时清理，
   不把需要 WebView、登录或已经失效的网站伪装成解析成功。
6. 运行相关核心回归、静态分析、格式检查，漫画阅读器状态测试独立进程运行。
7. 对本地样本做有限在线全链路抽测，记录站点/网络/脚本/规则各阶段结果及未验证边界。

## 分工与边界

- rules：选择器与规则流水线；独立测试文件。
- scripting：JavaScript 与宿主 API；独立测试文件。
- runtime/request：目录、正文、图片与请求契约；由主代理实现。
- 样本原文件只读，不将完整私人书源、认证字段或正文复制到仓库。

## 验证记录

初始请求、真实规则夹具、漫画兼容性基线：23 项通过。

## 已确认的请求层修复计划

- `AnalyzeUrl.kt:192-214,280-359` 先替换变量，再按请求 charset 编码 query/form。
  现有实现把整个模板的变量一律按 UTF-8 URL 编码，导致 GBK 搜索词错误，
  同时污染 JSON body 和 header。样本搜索入口中含 GBK 1914 次、GB2312 140 次。
- 先解析 options，再按 URL、form、JSON 和 header 的各自契约展开；编码沿用现有
  gbk_codec，不添加依赖。删除全模板统一 URL 编码的旧路径。
- 新增 GBK GET/POST、JSON/header 原值与本地 HTTP 出站字节回归；修正此前把
  UTF-8 字节标为 GBK 的旧测试预期，不删除断言。

## 整合时确认的底层缺口

- 在线漫画图片请求的 HTTP 400 追踪到共享 `BookSourceNetworkPolicy`：自定义
  `HttpClient.connectionFactory` 返回普通 Socket，HTTPS 也没有 TLS。
  本机 Dart SDK `_http/http_impl.dart:2683-2701` 证明自定义工厂会接管默认
  `SecureSocket.startConnect`，并不会自动升级。用本地 TLS 服务先复现后修复，
  保留原域名证书校验、SNI、IP 校验、多地址尝试和连接取消。
- 清理为该错误新增的 HTTP 400 系统重试路径及错误归因；真实 HTTP 400 应报告，
  不重放请求掩盖问题。正常网络失败和显式平台能力保留已验证边界。
- 脚本变量改为真实 book/chapter 存储后，请求模板也必须携带同一个实体上下文，
  由既有 writer 回写，防止详情保存的 token 在章节请求阶段丢失。
- 目录层聚合后统一反转与去重，复用多 URL 规则接口；缺失章节地址的普通短篇
  使用目录 finalUri。已有安全 DOM 锚点回退继续保留，显式无效地址不能冒充目录页。
- `replaceRegex` 的脚本形态以合并正文运行一次，继续保留纯正则路径对各分页图片
  基址的追踪，以及删除图片不得被原始 HTML 回退重新恢复的保证。

## 最终实现与同步清理

| 文件/模块 | 修复与清理 |
| --- | --- |
| `networking/book_source_network_policy.dart`、`source_http_transport.dart` | 补齐自定义 HTTPS TLS 握手；删除掩盖握手错误的 HTTP 400 重放分支，保留原域名证书验证和多地址尝试。 |
| `caching/source_cover_cache.dart` | 图片与书源请求统一允许 VPN FakeDNS 198.18/15；继续拒绝默认未授权的普通内网目标。 |
| `source_request_expressions.dart`、`source_request_template.dart` | 删除模板变量统一 UTF-8 URL 转义；按 query/form/JSON/header 分别处理，支持 POST/header 页选表达式并保留含逗号属性的 HTML。 |
| `utils/chinese_charset_encoder.dart`、`source_response_codec.dart`、`scripting/source_script_encoding_api.dart` | 请求与脚本复用同一字符编码；GB2312/GBK 超出字符集输出替代字节，GB18030 支持真实四字节编码和响应解码。复用现有 GBK 表，仅保存标准范围和小型差异数据。 |
| `rules/source_rule_html.dart`、`source_rule_xpath.dart` | 将属性正则和 Jsoup 文本/位置/has 伪类合并到已有选择器流水线；删除被替代解析分支，临时属性在 finally 清理。块/BR 文字边界、空格组合符有精确回归；兄弟节点一次快照消除位置筛选的平方级扫描。 |
| `rules/source_rule_json.dart` | 复杂相对 JSONPath 复用已有 JSONPath 库；简单路径保留快路，不把普通键名内的冒号/逗号误当表达式。 |
| `scripting/source_script_bootstrap.dart`、`source_runtime_requests.dart`、`source_runtime_catalog.dart` | 脚本读写实际 chapter/book/rule/source 变量；请求继续传递相同实体上下文。旧 AES 名称转向已有加密实现，不新增平行加密层。 |
| `source_runtime_reading.dart` | 目录合并后排序去重、单链/固定多页区分、普通空章节地址、内容 webJs；跨页/附加正文合并后运行一次脚本替换。 |
| `source_content_images.dart`、`source_text_replacement.dart` | 共享图片引用解析，去掉重复属性扫描；全文脚本替换后保留存活图片的原页面基址。 |
| `tool/diagnose_source_samples.dart`、`test/source_real_chain_diagnostic_test.dart` | 分小说/漫画抽测，漫画使用生产图片缓存下载并真实解码；删除旧的重复网络探针。 |

没有建立第二套书源引擎，没有增加 package 依赖。修改前已有的导入流程、WebDAV、
本地化、DESIGN 和生成文件修改保持独立；它们不计入本次兼容性修复。

交叉复查另外补齐了正文页脚本写入章节变量后，下一页请求仍读取旧副本的问题。
串行分页共用实际章节实体，移除第一页旧状态的结尾覆盖；有脚本状态依赖的固定分页
串行执行，普通选择器固定分页保留最多四路预取。`java.put`、`chapter.putVariable`
均有“第一页写入 → 第二页请求 → 第三页请求”回归。
动态表达式检测统一放回现有规则解析器，同时覆盖 `{{…}}` 插值和分页请求模板，
删除原先仅供 replacement 使用的重复判断；避免把插值中的宿主调用误当纯文本并发执行。

字符编码对照 Android Studio JBR OpenJDK 25.0.3，GB2312、GBK、GB18030 分别遍历
全部 1,111,936 个 Unicode 标量，编码无差异；GB18030 编码后解码遍历同一标量集合，
无往返差异。标准四字节范围来源为 [WHATWG GB18030 index](https://encoding.spec.whatwg.org/index-gb18030-ranges.txt)，
实现复用包内映射而没有复制整张 GBK 大表。这个比对范围不包含非法 UTF-16 孤立代理项。

## 真实样本复测（2026-09-08）

读取五份样本得到 9473 条解析结果、7456 个唯一来源，其中 7049 个具备静态可运行
结构。**这个数字不表示网站在线或能完成阅读**；导入报错 16 条、文件内重复 38 条。

小说按 selector/script/XPath/backgroundWeb 四类各取两项，实际结果：

| 样本 | 最终结果 |
| --- | --- |
| 空白小说 | 搜索、详情、1826 章目录、首章 4572 字符通过。 |
| 笔趣阁2、三一读书 | 搜索 HTTP 403。 |
| 笔趣阁82 | 搜索 HTTP 404。 |
| 英文小说网、内裤奇缘小说 | 页面匹配到元素，但没有同时有效的书名和链接。 |
| 废文网 | 搜索页 bookList 无匹配项。 |
| 探探书屋 | 已通过搜索/详情/目录；正文源脚本对 `result.match(...)[1]` 取值时匹配为空。 |

上述剩余失败保留真实错误，没有通过特定域名补丁或伪造空结果掩盖。HTTP 返回码
是当前网络下的现场证据；无匹配、脚本空匹配仍需要对应站点页面或书源维护者进一步
确认，不能仅凭一次抽测认定网站永久失效。

漫画三项抽测：考拉漫画通过 1083 话目录及首张图片下载/解码；绅士漫画通过
1 个目录项、正文 75 张图片提取及首张图片下载/解码；MY 漫画搜索仍返回 HTTP 403。
未下载整套漫画，未展示或保存正文内容到仓库。

图片故障现场确认：`tuer.justpic01pt.com`、`t4.qy0.ru`、`img5.qy0.ru` 分别解析为
198.18.1.51、198.18.1.54、198.18.1.42。原图片策略拒绝该范围，而书源 transport
允许；统一策略后，之前两项 `stage=image` 失败的漫画均真实解码通过。

在线日志保存在 `/tmp/open-reading-text-live-verified-20260908.log`、
`/tmp/open-reading-comic-live-verified-20260908.log` 和
`/tmp/open-reading-comic-second-verified-20260908.log`。诊断测试本身通过只代表探测
执行完成，源可用性以 `SUMMARY` 及逐项结果为准。

## 验证边界

离线契约和网络/图片回归可复现通用缺口；真实样本验证当前 Mac 网络上的完整流程。
未在手机/平板真机上跑整套书源，未对每个失效样本在 Legado 设备端做在线对照，
也未验证所有 WebView 登录、验证码和任意 JVM/Rhino API。保留明确能力边界，
不把部分规则通过描述为完全兼容所有 Legado 书源。
未穷举畸形 GB18030 字节流与 Java 的错误恢复顺序；合法标量编解码已完整比对。

## 最终验收

- 38 个 source/network 测试文件：**362 项通过**，按单个 Flutter 命令、
  `--concurrency=1` 执行，日志 `/tmp/open-reading-verified-source-suite-20260908.log`。
- 响应 codec 独立进程：**5 项通过**，日志
  `/tmp/open-reading-verified-response-codec-20260908.log`。
- 漫画阅读器图片章节实际打开用例独立进程：**1 项通过**，日志
  `/tmp/open-reading-verified-comic-reader-20260908.log`。
- 合计 **368 项通过**；额外中途重跑的同一用例不重复计数。
- `flutter analyze --no-pub`：**No issues found**，日志
  `/tmp/open-reading-verified-analysis-20260908.log`。
- 本次 29 个 Dart 文件格式检查无改动；`git diff --check` 通过。
- 规则复审中页选 HTML、块/BR 文本、空格组合符、位置筛选四项反例已修复并复审通过。
- 早期多个 Flutter 命令并行时出现过共享 native-assets 生成竞争；已改为串行命令重跑。
  它属于测试启动基础设施问题，以上最终日志均为完整通过结果。

修改与断言保留在当前工作区，可从本文的文件表和新增 `*_legado_contract_test.dart`
查看行为契约。测试用 TLS 证书只用于本地测试，说明见 `test/fixtures/tls/README.md`。
