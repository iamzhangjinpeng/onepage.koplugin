# 开发指南

## 模块划分

| 文件 | 职责 | 依赖 |
| --- | --- | --- |
| `_meta.lua` | 插件元信息与版本 | gettext |
| `main.lua` | 菜单、北京时间调度、后台子进程下载、屏保接管/恢复、诊断、在线更新编排 | 移植自 danxiangli.koplugin |
| `onepage_api.lua` | v3 接口请求、当日 id 定位、字段归一化、URL 缩略、临时文件写入 | 纯 Lua + socket.http / dkjson（仅子进程） |
| `onepage_layout.lua` | 两种样式的几何、字号、灰度配色、圆角 inset | **纯 Lua，无 KOReader 依赖** |
| `onepage_wallpaper.lua` | 解码/裁切/中文排版/圆角合成/16 级灰抖动/PNG 校验/发布缓存 | Blitbuffer / RenderImage / TextBoxWidget / Font |
| `onepage_update.lua` | GitHub Release 校验、SHA-256、备份回滚 | 移植自 danxiangli.koplugin |

把纯逻辑（`onepage_api.lua` 的解析函数、`onepage_layout.lua`）与 KOReader API 分开，是为了能在桌面用 `lupa` 离线跑单测，不必装 KOReader。

## 数据流

```text
启动 / 唤醒 / 定时 / 手动
  → main.lua 调度（北京时间 UTC+8 判定今日）
  → 子进程 dofile(onepage_api.lua).fetch_today()
      idlist/0 → data[1]（校验 hp_makettime）
      → hp/detail/{id} → YYYYMMDD.json.tmp
      → 图片（1080x 缩略）→ YYYYMMDD.jpg.tmp
  → 子进程解码校验（Wallpaper.validate_source）→ 父进程头尾校验 → rename 两个临时文件
  → onepage_wallpaper.prepare()
      读 YYYYMMDD.json
      → Layout.for_screen(W, H, style, contrast)
      → 照片 center-cover 裁切 + TextBoxWidget 写中文
      → 圆角卡：逐行 arc inset 贴到浅灰画布
      → ditherblitFrom 出 16 级灰 PNG
      → 校验 PNG 后发布 display/wallpaper.png
  → 屏保设置（random_image + 专用目录 + 拉伸 + 隐藏文字）
```

## 中文排版要点

- 用 `TextBoxWidget` 而不是自己断行：`height_adjust`、`height_overflow_show_ellipsis`、`alignment_strict`、`auto_para_direction` 全部打开，字号从目标值逐次减 1 直到不溢出。
- `Font:getFace("cfont", size)` 会按屏幕 DPI 再缩放一次，所以传参前要除以 `Screen:scaleBySize(1024)/1024`（yiyan.koplugin 的做法）。
- Lua 模式按字节处理，**不要把全角字符放进 `[...]` 字符类**。解析 `hp_author` 时用 `string.find(s, "＆", 1, true)` 定位。
- 所有 widget 与 BlitBuffer 都要 `free()`，包括每次缩字号试验中创建的 widget。

## 圆角卡实现

`onepage_layout.lua` 给的是绝对坐标；渲染时先画到 `panel`（卡片尺寸），再把 panel 逐行 `blitFrom` 到浅灰画布：

```lua
for row = 0, panel_h - 1 do
    local inset = Layout.row_inset(row, panel_h, radius, radius)
    canvas:blitFrom(panel, card.x + inset, card.y + row,
                    inset, row, panel_w - 2 * inset, 1)
end
```

这样照片区和文案区的四角一起被裁圆，不需要预置背景 PNG，也不需要 `paintRoundedRect` 之后再单独处理图片。

## 里程碑状态

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| M0 | 建仓、接口快照、文档 | 完成 |
| M1 | 数据层 + 版式计算 + 离线单测 | 完成（29 项） |
| M2 | 两种样式渲染（全屏 / 白底圆角卡） | 完成（待真机验证） |
| M3 | 菜单、调度、后台下载、屏保接管 | 完成（移植自单向历） |
| M4 | 降级链、诊断、在线更新 | 更新器已移植；PC HTML 兜底未实现 |
| M5 | Release 打包与真机安装验证 | 打包脚本已就绪，**真机未验证** |

## 真机验证清单（必须做）

1. 冷启动 KOReader，等待 8 秒后自动出今日壁纸；屏保显示正确、无黑边、无文字残缺。
2. 在菜单切换「全屏 ↔ 白底圆角卡」，确认离线重绘、四角圆滑、卡外留白与页脚正确。
3. 切换「高对比白 ↔ 经典灰」，确认生成不同的缓存 PNG，屏保刷新。
4. 关闭「自动配置屏保」，确认原屏保设置被完整恢复。
5. 断网 / 关闭 Wi-Fi 时重启，确认仍显示上一张可用壁纸，不出现空白屏保。
6. 06:00 之前（或手动改设备时间）触发，确认 `no_today` 走 2 小时冷却且不反复请求。
7. 跨午夜唤醒，确认自动换成新一天的图与文案。
8. 长文案（>3 行）与英文文案，确认自动缩字号、省略号正常，无越界。
9. 在线更新：从 Release 下载 zip，校验 SHA-256，替换后重启，备份目录清理正常。
10. 内存观察：Kindle 上渲染 1072×1448 不崩溃（缩略图 75 KB，解码后及时 free）。
11. 把一个能通过头尾校验但无法解码的 JPEG 改名成 `YYYYMMDD.jpg` 放进缓存目录，确认插件识别为坏图并重新下载，而不是一直提示「今日壁纸已存在」。

## 已知风险

- v3 接口无 SLA，失效后需要补 VOL 锚点反查或 PC HTML 兜底解析器。
- 图片域名白名单固定为 `image.wufazhuce.com`，CDN 迁移域名需要随版本更新。
- 一次抓取最多 1 次 idlist + 10 次 detail + 1 次图片，全部串行；总预算 60 秒，超出返回 `timeout` 并退避重试。
- `TextBoxWidget` / `ditherblitFrom` 的行为在不同 KOReader 版本可能略有差异，需实机确认。
- 横图裁成竖屏时主体可能被切（今日照片的招牌在右侧，center-cover 实测仍完整）；后续可加焦点偏移设置。
- 圆角卡在横屏设备上按竖屏尺寸生成（沿用单向历策略）。

## 代码约定

- Lua 5.1 语法（KOReader 用 LuaJIT），不用 `goto`、`table.unpack`。
- 代码注释用英文，用户可见文案用中文并包裹 `gettext()`。
- 循环变量不用 `_`（是翻译函数）。
- 新功能先补 `tests/test_core.py` 的纯逻辑用例，再动渲染代码。
