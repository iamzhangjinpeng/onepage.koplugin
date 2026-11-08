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
- `TextBoxWidget` **永远从盒子顶部开始画**：`height_adjust` 只是把盒子收缩到行数高度（注释里的 "for nicer centering" 指的是外层容器可以据此居中），它不会在固定高度的盒子里垂直居中。所以短文案会贴顶、下面空一大片。`paint_text(..., "center")` 会先 `getSize().h` 量出收缩后的高度再补偏移，这才是 ONE 卡片的观感。

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
| M1 | 数据层 + 版式计算 + 离线单测 | 完成（96 项） |
| M2 | 三种样式渲染（全屏 / 白底圆角卡 / 满版圆角卡） | 前两种真机验收通过；满版卡待真机确认 |
| M3 | 菜单、调度、后台下载、屏保接管 | 完成，真机验证通过 |
| M4 | 降级链、诊断、在线更新 | 完成；PC HTML 兜底解析器未实现 |
| M5 | Release 打包与真机安装验证 | 完成，v0.2.0 自更新链路真机通过 |

## 真机验证清单（必须做）

每条的**操作步骤、故障注入方法、通过标准和取证方式**见 [`field-test.md`](field-test.md)；这里只留一行验收标准，免得两处各写一份步骤、改一处忘一处。

1. 冷启动 KOReader，等待 8 秒后自动出今日壁纸；屏保显示正确、无黑边、无文字残缺。
2. 在菜单依次切换「全屏 → 白底圆角卡 → 满版圆角卡」，确认离线重绘、四角圆滑、卡外留白与页脚正确；满版卡的圆角要切在照片上，不能露出白边。
3. 切换「高对比白 ↔ 经典灰」，确认生成不同的缓存 PNG，屏保刷新。
4. 关闭「自动配置屏保」，确认原屏保设置被完整恢复。
5. 断网 / 关闭 Wi-Fi 时重启，确认仍显示上一张可用壁纸，不出现空白屏保。
6. 06:00 之前（或手动改设备时间）触发，确认 `no_today` 走 2 小时冷却且不反复请求。
7. 跨午夜唤醒，确认自动换成新一天的图与文案。
8. 长文案（>3 行）与英文文案，确认自动缩字号、省略号正常，无越界。
9. 在线更新：从 Release 下载 zip，校验 SHA-256，替换后重启，备份目录清理正常。
10. 内存观察：Kindle 上渲染 1072×1448 不崩溃（缩略图 75 KB，解码后及时 free）。
11. 把一个能通过头尾校验但无法解码的 JPEG 改名成 `YYYYMMDD.jpg` 放进缓存目录，确认插件识别为坏图并重新下载，而不是一直提示「今日壁纸已存在」。
12. 切成横屏后锁屏，确认 `wallpaper/` 下**仍然只有** `1072x1448` 一份，屏保是一张不变形的竖版图。KOReader 的屏保在画图前会强制转回竖屏（`Screensaver:show()` → `modeExpectsPortrait()`），所以不能按当前方向渲染。
13. 接口故障冷却：临时把 `image.wufazhuce.com` 改成 `127.0.0.1` 重打包，确认提示「1 小时内不再重试」，且 5 分钟内不再发起请求；诊断页显示剩余分钟。
14. 断网 + 清空 `screenshots/onepage/`（模拟全新安装后第一次就失败），确认屏保是「今日图文暂不可用 / 联网后会自动更新」的占位图，而不是 KOReader 的启动图标；恢复网络后应被真实壁纸覆盖。
15. 旧尺寸自清理：手工塞一个 `1448x1072` 的 PNG 进 `wallpaper/`（模拟旧版本遗留的横版），再锁屏解锁，确认它被删掉、`display/wallpaper.png` 仍是 `1072x1448`。
16. 调度归属：开一本书 → 退出到文件管理器 → 等 6 分钟，确认日志里仍有「一页壁纸: 请求今日图文」。若没有，说明关书时 `onCloseWidget` 把唯一活着的实例停掉了，需要改成「先建实例持锁、后建实例只注册菜单」，再让新实例接管时立即补跑一次（`init` 里直接复位 `_loop_at`）——不能靠 `onResume` 转发，见第 17 条。
17. 唤醒补跑：锁屏后等 10 分钟，唤醒并解锁，确认 `onepage.log` 在 1 分钟内出现一次新检查（没有 `请求今日图文` 也算，说明日期串比对跑了）。它靠的是「挂起期间定时器不前进、恢复后第一个 tick 就是过期任务」，插件没有 `onResume` 钩子——`broadcastEvent("Resume")` 只发给窗口栈里的 widget，插件实例不在其中。

## 离线测试

`tests/test_core.py` 覆盖纯函数（排版、解析、选日、域名白名单），`tests/test_pipeline.py` 覆盖真实 I/O 路径。两个模块的外部依赖全部走 `require`，所以把 `package.loaded` 换成假的，就能在没有网络、没有 KOReader 的情况下跑通完整控制流。

| 被替换的模块 | 替身做什么 |
| --- | --- |
| `socket.http` / `ssl.https` | 按队列吐出预置响应：状态码、`Location`、分块 body、socket 错误 |
| `libs/libkoreader-lfs` | 桥到 Python `os`，临时目录当设备 |
| `ffi/util` | `fsync*` 恒真 |
| `ffi/sha2` | 走 `hashlib` |
| `ffi/archiver` | 用一个 entry 列表代替真实 zip |

覆盖到的错误分支：超时 / 连接被重置 / 非 200 / `res≠0` / 超长响应 / 同域一次重定向 / 越权重定向 / 缺 SOI-EOI / 不足 1 KB / 超上限；发布 JSON 的 draft、prerelease、改名资源、摘要格式、体积；zip 的路径穿越、绝对路径、重复条目、字节码、版本不符、条目上限、摘要不符；安装的备份占位与回滚。

```
python3 -m pip install lupa
python3 -m unittest discover -s tests -v
```

这套用例做过变异验证：去掉重定向白名单、JPEG 首尾标记、条目上限、摘要校验、版本校验中任意一处，都会有对应用例立刻失败。`safe_path` 是唯一测不出来的——它被 `ensure_directory` 的 `mkdir` 兜住了（`..` 已存在，建不出来），属于第二层护栏。

## 已知风险

- v3 接口无 SLA，失效后需要补 VOL 锚点反查或 PC HTML 兜底解析器。
- 图片域名白名单固定为 `image.wufazhuce.com`，CDN 迁移域名需要随版本更新。
- 一次抓取最多 1 次 idlist + 10 次 detail + 1 次图片，全部串行；单请求 20 秒、总预算 60 秒，每次请求的超时会裁剪到剩余预算，超出返回 `timeout` 并退避重试。
- JPEG 解码上限 8 MP：CDN 缩略失效时会回原图（实测 2559×1706 = 4.37 MP），阈值必须高于它，否则完全不出图；`MAX_IMAGE_EDGE = 4096` 仍限制单边。
- `TextBoxWidget` / `ditherblitFrom` 的行为在不同 KOReader 版本可能略有差异，需实机确认。
- 横图裁成竖屏时主体可能被切（今日照片的招牌在右侧，center-cover 实测仍完整）；后续可加焦点偏移设置。
- 壁纸**始终按竖版渲染**（`Screensaver:show()` 对图片型屏保恒定 `modeExpectsPortrait()`，会先转回竖屏再建 widget），所以只有一个 `1072x1448` 尺寸；旧版本遗留的横版文件在下次运行时按尺寸不符删掉。同一天里，换样式 / 换配色各留一份 PNG（最多 8 张、约 2 MB），跨日才整批清理。
- 占位壁纸只在「连缓存都没有」时写一次；它绕过按日缓存，所以不会被 `prune` 当成旧图删掉，也不会被误认为当天的渲染结果。
- 字号全部由宽度推导，这对竖屏成立、对横屏不成立（横版卡片又宽又扁）。`for_screen` 里已按各自的槽位高度给 `quote` / `category` / `day` 加了上限，新增字号时别只按宽度算，`tests/test_core.py::test_fonts_fit_their_slots_in_every_orientation` 会兜住。
- 插件实例的调度归属依赖 KOReader 是否对插件实例调用 `onCloseWidget`，这一点离线无法确认，见真机清单第 16 条。

## 代码约定

- Lua 5.1 语法（KOReader 用 LuaJIT），不用 `goto`、`table.unpack`。
- 代码注释用英文，用户可见文案用中文并包裹 `gettext()`。
- 循环变量不用 `_`（是翻译函数）。
- 新功能先补测试：纯逻辑进 `tests/test_core.py`，涉及网络 / 文件 / 解压的分支进 `tests/test_pipeline.py`，再动实现代码。
