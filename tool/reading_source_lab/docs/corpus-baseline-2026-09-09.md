# Reading source corpus audit

> Offline structural audit; no scripts or network requests were executed. Configuration values are omitted.

**80% execution compatibility target: `not_verified`.** Executed sources: **0**; unknown: **7506**. No execution pass rate is available.

Inventoried **12** JSON files: **11** source files, **1** unrelated files, **0** URL lists, **0** unreadable or malformed files.

Source records: **9571**; valid records: **9570**; invalid records: **1**; duplicates: **2064**; unique sources: **7506**; invalid/empty URLs among unique sources: **82**.

Unrelated records: **273**; unfetched source-list URLs: **0**. These are retained separately from the source denominator.

## Selection and manifest

full bookSourceUrl including fragment; missing URL retains its record.
maximum integer lastUpdateTime, then relative path, then zero-based record index. Selection occurs before any per-file deduplication.

Manifest SHA-256: `1af560be1521f8648175b46175c7a6b81a4362a4e64aed602c99fd57afd002b0`.
UTF-8 sorted relative path, tab, SHA-256 (or -), newline. Paths are relative to the common input-file parent.

## Files

| File | Classification | Records | Selected in file | Errors | SHA-256 |
|---|---|---:|---:|---:|---|
| MY漫画.json | sources | 1 | 1 | 0 | `f10b8a15618c2759839f7073980f57b75c520624aa164abc25b7b553ff7c5edb` |
| bookSource-230824.json | sources | 4513 | 4494 | 0 | `7498b1c92d8c3006424625194369363865986d638b436da1a253e9635940043d` |
| shareBookSource.json | sources | 3949 | 3936 | 1 | `3c6ba7a86c63a41d18edc8c1a112b4bf902eb6489260012844adc929cec44cf8` |
| shuyuan.json | sources | 1061 | 1054 | 0 | `5fc53fe3eec0e366a85bd0ec50c176bc37a310d6d1d8b2a084d0e1f620929ecc` |
| 光遇聚合 26.8.7.json | sources | 1 | 1 | 0 | `a683bee2f27afa45848c015709b51a5634b6c51cc49778327e50d8969b21d3ec` |
| 替换规则/替换净化.json | unrelated | 273 | 0 | 0 | `9bcb78950f2ea1be698e9f30349c62fa2230643b6fd3913e79a39bb6d839f5da` |
| 漫画源/漫画书源_合集.json | sources | 3 | 3 | 0 | `32e2bd15465fe0ecede68188c620cfe5ffdd210f11ec1cdb2f97a139244119bf` |
| 漫画源/绅士漫画_wnacg.json | sources | 1 | 1 | 0 | `1a308be63a6e697de58c24413762f7bb4aa331aff6538d384edc7cdf739bc63f` |
| 漫画源/考拉漫画.json | sources | 1 | 1 | 0 | `5b2a84d7130d66c79234a89470b90f2ac522fa98645e0762515c6d63d8a7c6da` |
| 漫画源/配置文件_39个(1).json | sources | 39 | 39 | 0 | `d995943be4867c70c9a4275c0258e6975c64b7665e3ee40ff9cfed7be59934ed` |
| 漫画源/🔞漫小肆韩漫.json | sources | 1 | 1 | 0 | `a2ba1bd4deb35c692fb43f44e546e1a16104bd8622cfc2b8603ad329675cf3cb` |
| 🔞漫小肆韩漫.json | sources | 1 | 1 | 0 | `a2ba1bd4deb35c692fb43f44e546e1a16104bd8622cfc2b8603ad329675cf3cb` |

## Structural readiness

**6865 / 7506 (91.46%)** unique sources have a text type, valid HTTP(S) URL, search entry, catalog rules, and content rules. This is an offline structural readiness rate, not an execution compatibility or live-site success rate.

Content types: `0`=7252, `1`=88, `2`=127, `3`=39.

Capability readiness: `incomplete_structure`=120, `needs_runtime_validation`=4158, `no_detected_extended_requirements`=2974, `outside_text_chain`=254. All execution outcomes remain unknown, including sources without detected extended requirements.

## Feature dependency totals

Counts use globally selected sources. Pattern detection is heuristic and implementation scope is descriptive, not a test verdict.

| Feature | Sources | Implementation scope |
|---|---:|---|
| `regex` | 6404 | regular-expression evaluator |
| `css` | 5766 | HTML selector evaluator |
| `javascript` | 3669 | native runtime; unavailable on Web |
| `cookie` | 3195 | source session storage |
| `post` | 2309 | HTTP request transport |
| `jsonpath` | 1161 | JSONPath evaluator |
| `login` | 883 | requires session or user interaction |
| `state` | 866 | source and book variable subset |
| `xpath` | 648 | selector subset |
| `java_dom` | 507 | Java-style DOM helper subset |
| `webview` | 378 | requires a native browser host |
| `crypto` | 309 | cryptographic helper subset |
| `browser_interaction` | 52 | requires a user interaction host |
| `interleave` | 20 | list interleaving |
| `head` | 12 | HTTP request transport |
| `cache_api` | 6 | source session cache subset |
| `shared_script` | 2 | shared script loading; execution unverified |

## Script API occurrences

| API | Occurrences |
|---|---:|
| `java.get` | 1424 |
| `java.ajax` | 1423 |
| `cookie.getKey` | 1334 |
| `java.md5Encode` | 1273 |
| `java.getString` | 1100 |
| `java.put` | 870 |
| `java.timeFormat` | 408 |
| `java.log` | 384 |
| `java.base64DecodeToByteArray` | 311 |
| `source.getKey` | 308 |
| `java.lang` | 246 |
| `cookie.removeCookie` | 185 |
| `java.getElements` | 179 |
| `source.getLoginHeaderMap` | 165 |
| `java.aesBase64DecodeToString` | 159 |
| `source.bookSourceComment` | 157 |
| `java.encodeURI` | 120 |
| `java.base64Decode` | 113 |
| `source.bookSourceUrl` | 100 |
| `java.toast` | 98 |
| `java.getElement` | 96 |
| `source.getVariable` | 93 |
| `java.toNumChapter` | 83 |
| `java.longToast` | 82 |
| `java.getStringList` | 72 |
| `java.base64Encode` | 66 |
| `java.util` | 45 |
| `java.security` | 43 |
| `java.post` | 40 |
| `source.key` | 40 |
| `java.createSymmetricCrypto` | 32 |
| `java.getCookie` | 30 |
| `source.getLoginHeader` | 30 |
| `source.getLoginInfoMap` | 28 |
| `java.t2s` | 27 |
| `cookie.setCookie` | 26 |
| `java.setContent` | 26 |
| `cookie.getCookie` | 25 |
| `java.timeFormatUTC` | 25 |
| `java.connect` | 21 |
| `java.getZipStringContent` | 21 |
| `source.header` | 18 |
| `source.putLoginHeader` | 18 |
| `source.setVariable` | 17 |
| `java.io` | 16 |
| `java.startBrowserAwait` | 15 |
| `java.queryTTF` | 14 |
| `source.loginUrl` | 14 |
| `java.refreshTocUrl` | 13 |
| `java.webView` | 13 |
| `java.desEncodeToBase64String` | 12 |
| `java.head` | 12 |
| `source.getSource` | 12 |
| `java.randomUUID` | 11 |
| `java.replaceFont` | 10 |
| `java.startBrowser` | 9 |
| `java.HMacHex` | 8 |
| `java.aesBase64DecodeToByteArray` | 8 |
| `java.getVerificationCode` | 8 |
| `java.queryBase64TTF` | 6 |
| `java.getStrResponse` | 5 |
| `java.hexDecodeToString` | 5 |
| `java.md5Encode16` | 5 |
| `java.base64Decoder` | 4 |
| `java.digestHex` | 4 |
| `java.ajaxAll` | 3 |
| `java.androidId` | 3 |
| `java.getWebViewUA` | 3 |
| `source.variableComment` | 3 |
| `java.deviceID` | 2 |
| `java.getAppVariant` | 2 |
| `java.initUrl` | 2 |
| `java.refreshBookUrl` | 2 |
| `java.refreshExplore` | 2 |
| `source.getHeaderMap` | 2 |
| `source.removeLoginHeader` | 2 |
| `source.variable` | 2 |
| `java.aesEncodeToBase64String` | 1 |
| `java.bytesToStr` | 1 |
| `java.digestBase64Str` | 1 |
| `java.htmlFormat` | 1 |
| `java.key` | 1 |
| `java.net` | 1 |
| `java.open` | 1 |
| `java.openVideoPlayer` | 1 |
| `java.qread` | 1 |
| `java.reLoginView` | 1 |
| `java.s2t` | 1 |
| `java.searchBook` | 1 |
| `java.showBrowser` | 1 |
| `java.showReadingBrowser` | 1 |
| `java.startBrowserDp` | 1 |
| `java.strToBytes` | 1 |
| `source.getLoginInfo` | 1 |
| `source.loginUi` | 1 |
| `source.putLoginInfo` | 1 |

## Java collection compatibility occurrences

| Method | Occurrences |
|---|---:|
| `get()` | 1704 |
| `size()` | 630 |
| `toArray()` | 210 |
| `isEmpty()` | 2 |
