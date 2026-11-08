# ONE v3 API 接口参考

面向 `onepage.koplugin` 的最小数据契约。2026-11-08 实测可用。完整端点说明见 [one.koplugin 的文档](https://github.com/finlater/one.koplugin/blob/main/docs/one-api-reference.md)；本文件只记录壁纸插件用到的部分。

## 基本约定

- Base：`http://v3.wufazhuce.com:8000`（**明文 HTTP，8000 端口**，HTTPS 443 不通）
- 所有请求必带 `?version=3.5.0&platform=android`，缺参返回 `wrong args`
- 无鉴权、无 cookie、无 UA 校验
- 响应：`{ "res": 0, "data": ... }`；`res=0` 但 `data` 缺失表示内容不存在（404 语义）
- 图片 CDN 支持明文 HTTP 与 HTTPS，均实测 200；插件沿用接口返回的 `http://`，与 v3 一致，避免 LuaSec/CA bundle 差异

## 三次请求

### 1. 定位当天图文 id

```text
GET /api/hp/idlist/0?version=3.5.0&platform=android
→ { "res": 0, "data": ["5283", "5307", "5303", "5301", ...] }
```

**关键坑：`data[1]` 才是当天，不是 `max(id)`。**

列表是运营精选位，数字 id 是预分配的乱序值，但顺序按日期倒序且连续。2026-11-08 实测：

| 取值 | id | 内容 |
| --- | --- | --- |
| `data[1]` | 5283 | VOL.5146 / 2026-11-08（今天） |
| `data[2]` | 5307 | VOL.5145 / 2026-11-07（昨天） |
| `max(id)` | 5310 | VOL.5139 / 2026-11-01（一周前） |

所以插件取 `data[1]`，再用 `hp_makettime` 与「北京时间今天（YYYYMMDD）」比对；不匹配时按数组顺序最多探测 10 个 id，找到日期匹配的那一期。全都对不上返回 `no_today`，主进程按 404 冷却 2 小时。

### 2. 图文详情

```text
GET /api/hp/detail/5283?version=3.5.0&platform=android
```

| 字段 | 今日实测值 | 壁纸用途 |
| --- | --- | --- |
| `hpcontent_id` | `"5283"` | 仅诊断 |
| `hp_title` | `"VOL.5146"` | 日期块期号、圆角卡页脚 |
| `hp_makettime` | `"2026-11-08 06:00:00"` | 校验当天；日期块「8 / Nov 2026」 |
| `hp_content` | `"我拼命稳住情绪，不让任何人发现异状。这真的太难了。 by 艾莉·布罗什"` | 正文（去掉 `by …` 后缀），署名单独留存 |
| `hp_author` | `"摄影＆Volodymyr Lymariev 作品"` | 分类「摄影」+ 摄影署名 |
| `image_authors` | `"Volodymyr Lymariev"` | 署名兜底 |
| `text_author_name` | `"艾莉·布罗什"` | 文案作者（诊断/后续扩展） |
| `hp_img_url` | `"http://image.wufazhuce.com/Fl93rM1GcYl_kdoacl-qOqTiMqMY"` | 照片 |
| `hp_img_original_url` | 同上 | 原图兜底 |

注意：**接口返回的是纯照片**，没有任何文字层。参考图里的分类条、文案、VOL、日期都是 App 合成层，必须由插件用 `TextBoxWidget` 自己渲染。

`hp_content` 的 `by` 拆分按字面量 `" by "` 处理；`hp_author` 的分隔符是全角 `＆`，**不能用 Lua 字符类 `[^＆&]`**（Lua 模式按字节，会把中文 UTF-8 的 continuation 字节当分隔符，切出非法字符串），用 `string.find(..., 1, true)` 定位。

### 3. 图片

```text
GET http://image.wufazhuce.com/Fl93rM1GcYl_kdoacl-qOqTiMqMY?imageMogr2/thumbnail/1080x/format/jpg
→ 200 image/jpeg, 1080x720, 74 991 B
```

原图 2559×1706、773 785 B。CDN 是七牛，`imageMogr2/thumbnail/1080x/format/jpg` 只对该 host 有效。URL 归一化规则：去掉已有 query、保留原协议、仅对 `image.wufazhuce.com` 追加缩略参数。

图片按 center-cover 裁切到竖屏区域，与 ONE App 观感一致。

**下载白名单**：只接受 `image.wufazhuce.com`。`hp_img_url` 来自明文 HTTP，可能被中间人改写；`parse_detail` 与 `write_image` 各校验一次，3xx 重定向也只允许同域名跳一次，否则返回 `invalid_host` / `redirect_error`。

## 本地元数据

图片旁保存 `YYYYMMDD.json`（`onepage_api.lua` 用 `dkjson.encode` 写）：

```json
{
  "date": "20261108",
  "vol": "5146",
  "quote": "我拼命稳住情绪，不让任何人发现异状。这真的太难了。",
  "author": "艾莉·布罗什",
  "category": "摄影",
  "image_author": "Volodymyr Lymariev",
  "image_url": "http://image.wufazhuce.com/...?...",
  "hp_id": "5283",
  "makettime": "2026-11-08 06:00:00"
}
```

渲染器读不到 JSON 时退化为「纯照片 + 日期」，不阻塞出图。

## 失败状态

| 状态 | 含义 | 主进程行为 |
| --- | --- | --- |
| `no_today` | **至少一次** detail 探测拿到了响应，但日期都不匹配（真未发布） | 映射为 `http_404`，冷却 2 小时，保留上一张壁纸 |
| `http_404` | HTTP 404 | 同上 |
| `network_error` / `http_5xx` | 一次可用响应都没拿到（全部探测失败） | 指数退避重试，最多 6 轮，**不进入冷却** |
| `timeout` | 探测途中的总时限耗尽（默认 60 秒任务预算） | 退避重试 |
| `invalid_host` | 图片 URL 不在 `image.wufazhuce.com` 白名单 | 拒绝下载，**冷却 1 小时**（域名迁移不会自愈） |
| `redirect_error` | 图片 3xx 跳到非白名单域名，或跳转超过一次 | 拒绝下载，**冷却 1 小时** |
| `invalid_file` | JPEG 头尾或解码校验失败 | 删除临时文件，保留上一张壁纸，退避重试 |
| `file_too_large` | 超过 4 MiB | **冷却 1 小时**（CDN 关掉缩略参数后不会自己恢复） |
| `bad_detail` | 详情都拿到了，但字段不可用（日期格式、图片 URL、文案缺失） | **冷却 1 小时**（多半是接口改字段） |
| `decode` / `nojson` | JSON 解析失败、响应超过 512 KB，或 `idlist` 返回空数组（正常总带历史条目） | `decode` 退避重试；`nojson` **冷却 1 小时**（缺 `dkjson` 不会自愈） |
| `http_4xx`（除 404） | 鉴权失效、接口下线等 | **冷却 1 小时** |
| `write_error` | 元数据写入失败 | 退避重试 |

`no_today` 与 `network_error` 必须区分：前者说明服务端明确没有今天的内容，可以安静等 2 小时；后者只是这一次没连上，若误判成 `no_today`，弱网下会整天不出图。

**为什么还要一条 1 小时冷却**：退避重试只覆盖「等一等就好」的失败。结构异常、域名迁移、缺解码库这类问题不会在 5 分钟内自愈，若照旧走 6 轮退避，5 分钟兜底循环会重新起一轮，一天下来是上万次请求。这些状态改为冷却 1 小时，冷却期间在诊断页可以看到剩余分钟数；手动「下载今日一页壁纸」会跳过冷却强制试一次。

**超时口径**：单次请求 20 秒，且每次请求的超时会被裁剪到任务剩余预算（60 秒减 8 秒留白），保证子进程能在父进程 SIGKILL 之前收尾、通过管道报 `timeout` 并清掉临时文件。

## 降级链（当前实现 / 后续）

1. `idlist/0` → `data[1]` + 日期校验（已实现）
2. 遍历 idlist 前 10 个找日期匹配（已实现）
3. 本地 7 天内可用壁纸（已实现：失败时保留 `display/wallpaper.png`）
4. VOL 锚点反查 / PC HTML 抓站（未实现，留待 v3 接口失效时补）
