# Flutter 书源兼容性验证记录

本次在现有 Flutter 阅读器上补齐书源规则语义，并清理解析器中的重复索引处理。参考代码固定到 `8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c`，样本来自用户提供的书资源目录。未新增依赖，未修改用户的书源文件。

**80% 执行兼容目标尚未验证。** 导入、结构审计、合成页面规则测试和真实网站抽测是四种不同证据，不互相替代。

## 本次修改

| 范围 | 改动 |
|---|---|
| `source_rule_parser.dart`、`source_rule_html.dart` | 合并选择与排除索引表示；按每个父节点处理索引；补齐 `children`、裸索引、多项排除、越界和步长语义；修正 own-text 匹配及 CSS `nth-child` 的元素位置计算。 |
| `source_rule_engine.dart`、`source_rule_interpolation.dart` | 保留显式 CSS 模式并传给组合规则；支持正文中的 `{{@css:…}}` 等嵌入选择器，保留多段文本。 |
| `source_script_bootstrap.dart` | 恢复脚本运行前的全局属性，避免共享函数和显式全局变量串到其他书源；异常和网络重放也执行恢复；补齐取值接口参数重载。 |
| `source_script_dom_api.dart` | 区分解码开关与显式内容参数；实体解码后解析相对 URL；URL 列表绝对化、去重，保留 data URL，过滤脚本导航；保留空规则列表的 null 语义。 |
| `lib/l10n`、两处说明注释、运行时布尔辅助函数及相关测试 | 采用独立命名和“通用书源”标签；四个测试文件改名为 `*_format_contract_test.dart`。 |
| `tool/reading_source_lab` | 递归清点全部 JSON，记录哈希；从原始记录直接选择最新版本；区分不相关文件、坏记录和结构准备度；生成可复现的 JSON/Markdown 报告。 |

没有删除现有根目录导出文件：这些文件承担旧导入路径兼容，并非第二套解析实现。网络/交互重放和失败队列恢复保留既有边界。工作区同时存在其他修改，运行时文件仅进行了精确命名替换，本地化只改两项标签并重新生成代码。

## 样本口径

完整报告：[语料审计](../tool/reading_source_lab/docs/corpus-baseline-2026-09-09.md)、[JSON 数据](../tool/reading_source_lab/docs/corpus-baseline-2026-09-09.json)。

- 12 个 JSON 文件：11 个书源文件；另一个是 273 条替换规则。
- 9,571 条原始书源记录，1 条缺少名称；去重 2,064 条后，7,506 个唯一配置。
- 使用完整书源标识保留 URL 片段，按 `(lastUpdateTime, 相对路径, 原始行号)` 选择新版。不同位置的同内容文件仍列入清单，其书源不会重复计数。
- 类型：文字 7,252、图片 127、音频 88、其他 39；82 个标识不是有效静态 HTTP(S) URL。部分不透明标识可由应用从规则中推导实际请求地址，因此这不等于导入失败数。
- Python 结构准备率：6,865 / 7,506 = **91.46%**，仅检查文字链必要字段和静态地址。
- 实际 Dart 导入：7,491 / 7,506；15 条拒绝，重复 0。现有能力扫描器认为其中 7,048 条可尝试执行，仍不是执行通过数。
- 输入清单 SHA-256：`1af560be1521f8648175b46175c7a6b81a4362a4e64aed602c99fd57afd002b0`。

严格兼容验收需让两端对相同响应快照执行搜索→详情→目录→正文，并比对输出及请求。以当前 7,506 个唯一配置为分母，至少需要 6,005 条配对结果一致；未执行和不支持的配置保留在分母。目前没有完成这一规模的配对验证。

## 行为与联网证据

- 先运行既有规则、脚本、请求回归；新 DOM 测试最初暴露 10 项失败，后续模式/位置边界也经过先失败后修复。
- 共享函数隔离最初 2 项失败；脚本取值重载最初 6 项失败；独立复核新增的全局变量、URL 解码顺序及重载边界再暴露 5 项失败，修复后根脚本测试组 59 项通过。
- 用户样本中一条英文来源的正文规则 `{{@css:.text-content1 .c-en@text||.text-content1@text}}` 原先得到空正文。现在有主选择、备用选择、多段正文和空结果的同步/异步回归。
- 首次真实网络抽测固定按四类各 2 个来源选择，共 8 个，2 个通过完整阅读链：一个取得 16 章目录及 5,399 字符正文，另一个取得 1,826 章目录及 4,572 字符正文。其余为 1 个正文空结果、1 个列表空结果、HTTP 403、HTTP 404、超时和缺少原生 WebView 宿主各 1 个。
- 修复正文模板后，单独复测上述原先正文为空的英文来源，完整阅读链通过，取得 **22 章目录、1,779 字符正文**。这项复测证明了对应引擎缺口的实际修复，不将单项复测换算成整个语料的兼容率。
- 该联网选择器先筛选可尝试来源，再按规则类型和更新时间选样，因此不能据此估计整个语料的成功率；测试进程退出成功仅表示诊断运行完毕。

## 验证命令

```bash
PYTHONPATH=tool/reading_source_lab/src python3 -m unittest discover -s tool/reading_source_lab/tests
PYTHONPATH=tool/reading_source_lab/src python3 -m reading_source_lab.cli /Users/xiaoyuan/work/书资源 --format json --output tool/reading_source_lab/docs/corpus-baseline-2026-09-09.json
flutter test --no-pub test/source_{config,dom_selection_contract,shared_script,rule*,script*,runtime*,request*}_test.dart test/book_source_{architecture,import_analyzer,add_controller}_test.dart
flutter test --no-pub test/book_source_add_flow_test.dart
flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings
flutter build apk --debug --no-pub
```

最终验证：

| 信号 | 结果 |
|---|---|
| 29 个核心/书源测试文件 | **350 项通过** |
| 独立导入窗口测试 | **12 项通过**，含中英日大字号布局 |
| Python 语料工具 | **12 项通过** |
| 全工程 Flutter 静态分析 | **No issues found** |
| 本任务 18 个可格式化 Dart 文件 | 无格式差异；其他脏运行时文件未整体格式化 |
| `git diff --check` | 通过 |
| 第一方代码、注释及测试命名扫描 | 无禁止品牌标识；许可、第三方依赖和用户数据不在清理范围 |

合计 **374 项测试通过**，包括 43 项新增语义回归。Flutter 调用顺序执行，含状态的导入窗口测试单独运行。本地化替换前后按键比较，除两个导入标签外其余已有值完全保留。新增测试和代码变化均有先失败后修复的记录，最终产品构建单独记录。

## 剩余范围

JSON 远程脚本清单、部分 Java/字体/压缩文件接口、完整 XPath、请求选项的部分扩展语义仍需补齐。远程库加载需要处理脚本请求头与串行执行器的重入关系，不能绕开现有受控网络层直接下载。

本机脚本测试使用 Apple JavaScriptCore，不能代表 Android QuickJS 与真机 WebView 验证；Web 端仍不支持脚本书源。尚未进行物理设备回归。许可和来源声明文件保留。

## Android 调试安装包

最终代码 `flutter build apk --debug --no-pub` 成功。安装包保存于 `output/source-compatibility-2026-09-09/open-reading-debug.apk`。

- 大小：184,927,778 bytes。
- SHA-256：`b4cbd36c4217ef9052a11e129cfcb3cd7f763810c01ba946b55ae629064668df`。
- 该产物用于本地调试，未发布，也未完成真机测试。
