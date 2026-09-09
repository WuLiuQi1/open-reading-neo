# Reading Source Lab

这是一个独立、无第三方运行时依赖的阅读书源解析与兼容性审计项目。它不联网、不执行
书源脚本，也不会输出请求头、登录配置或 Cookie 的具体值；用途是把大批 JSON 书源转成
可重复验证的结构统计和 Open Reading 兼容矩阵。

## 能做什么

- 读取单个书源、书源数组、`sourceUrls` 清单和常见包装对象。
- 递归读取目录内全部 JSON，也接受文件与目录混用；同一个文件只读取一次。
- 审计按完整 `bookSourceUrl` 去重（保留 `#` 片段），选择最大 `lastUpdateTime`；同时间按
  相对路径、原始记录索引决胜。选择直接作用于原始记录，避免提前丢失较新的重复配置。
- 为全部输入保存相对路径、字节数和 SHA-256；坏 JSON、无关 JSON 和未下载 URL 清单
  分开计数。缺失名称记为错误，缺失或无效 URL 仍保留在分母中。
- 识别搜索、发现、详情、目录、正文能力，以及 JS、WebView、POST、XPath、JSONPath、
  CSS、正则、状态变量、登录、Cookie、加密和非文字内容依赖。
- 生成 JSON 或 Markdown 报告；报告只包含文件清单、字段/API 名和数量，不输出来源名称、
  脚本、请求头、登录字段或 Cookie 值。
- 核心阅读链结构准备率要求文字类型、有效地址、搜索、目录和正文结构齐全。
  扩展能力只描述检测到的依赖，所有来源的执行兼容结果都明确为未知。

## 使用

```bash
cd tool/reading_source_lab
PYTHONPATH=src python3 -m reading_source_lab.cli \
  --format markdown \
  --output report.md \
  /path/to/sources-a.json /path/to/sources-b.json
```

不安装也可以直接运行：

```bash
PYTHONPATH=tool/reading_source_lab/src \
python3 -m reading_source_lab.cli --format json /path/to/sources.json
```

递归审计语料目录并保存报告：

```bash
PYTHONPATH=tool/reading_source_lab/src \
python3 -m reading_source_lab.cli --format markdown \
  --output report.md /path/to/corpus
```

测试：

```bash
PYTHONPATH=tool/reading_source_lab/src \
python3 -m unittest discover -s tool/reading_source_lab/tests
```

## 设计边界

审计结果是结构和依赖模式统计，不能证明规则正确执行，也不表示目标网站在线、验证码、
登录、付费或风控已通过。80% 执行兼容目标固定报告为 `not_verified`，执行数为 0，
通过率为 `null`。验证目标需在固定语料上使用相同响应快照比对参考执行结果，再单独
验证搜索→详情→目录→正文的在线链路；未知、引擎差异、网站失效必须区分。

JSON schema v2 的 `files` 保留逐文件的解析、错误、结构和能力数量，新增清单信息；
`corpus` 和顶层 API/功能统计使用全局选择后的唯一来源。`totals` 区分原始、有效、无效、
重复和唯一记录。原 `compatibility`/`support` 标签改为 `capability_readiness`/
`capability_scope`，避免把静态标签误读为运行证明。现有独立 `parse_payload` 默认导入语义
仍保留最后一条重复配置；审计显式保留原始候选后执行版本选择。

最新固定清单见 [2026-09-09 基线](docs/corpus-baseline-2026-09-09.md)。早期
[三批样本报告](docs/sample-baseline.md) 保留作历史资料，其逐文件总和没有跨文件去重。

规则研究基于公开阅读书源执行实现的源码快照（下载日期 2026-08-04）。关键语义来源和
Open Reading 对照见 [docs/compatibility.md](docs/compatibility.md)。
