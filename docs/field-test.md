# 真机测试指南

`docs/development.md` 里的 16 条是**验收标准**，本文是**怎么在这些标准上动手**。按顺序做，第 1 节不过就别往下走。

## 0. 准备

| 项目 | 说明 |
| --- | --- |
| 设备 | 已越狱、已装 Kindle 版 KOReader 的 Kindle（安装 KOReader 本身不在本文范围） |
| 安装路径 | `koreader/plugins/onepage.koplugin/`，USB 挂载后是 `/Volumes/Kindle/koreader/plugins/onepage.koplugin/` |
| 日志 | `koreader/crash.log`。`logger.info` / `logger.warn` 都写在这里，**不需要开任何开关** |
| 重启规则 | 插件只在 KOReader 启动时加载。**每次换代码都必须完全退出 KOReader 再打开**，热重载不存在 |
| 回滚 | 动手前把整个 `onepage.koplugin/` 文件夹复制一份；出问题直接覆盖回去 |

部署与取日志：

```bash
scripts/deploy_usb.sh /Volumes/Kindle --fresh   # 拷代码 + 清空 onepage 缓存
scripts/collect_logs.sh /Volumes/Kindle         # 取 crash.log、缓存 PNG、目录清单
```

`--fresh` 只做一件事：删掉 `koreader/screenshots/onepage/` 这一个目录（当日 jpg、同名 json、`wallpaper/` 下所有渲染 PNG、`display/wallpaper.png`），让下次启动像全新安装一样重新下载和渲染。KOReader 设置、别的插件一概不动。

- **该用**：改了版式常量、字号、配色、缓存键；测占位图；测首装；怀疑 PNG 损坏。
- **别用**：只改网络/调度/文案时没必要；**离线时更别用**——缓存清空后没网可下载，屏保只剩占位图。
- 不带 `--fresh` 时只替换插件代码、保留缓存，所以改了版式又忘了加 `--fresh`，旧 PNG 会直接命中缓存，新代码根本不跑，看起来像"改了没效果"。

USB 的时机：Kindle 停在主页（KOReader 已退出）时插线才会挂载成 U 盘；KOReader 正在运行时用「工具 → USB 存储模式」交还分区。

## 1. 五分钟冒烟测试

1. `scripts/deploy_usb.sh /Volumes/Kindle --fresh`，弹出 Kindle。
2. 打开 KOReader，**等 15 秒**（首次检查延迟 8 秒，加上下载）。
3. 菜单 → 工具 → 一页壁纸 → 诊断，逐行核对：

   | 行 | 期望 |
   | --- | --- |
   | 今日图片 | 已就绪 (YYYYMMDD)，且日期是北京时间今天 |
   | 最近状态 | `ok` |
   | 网络 | 已连接 |
   | 屏保类型 / 屏保目录 | `random_image` / `.../onepage/wallpaper/display/` |
   | 拉伸填充 | `true` |

4. 按电源键锁屏 → 应显示今日图文，两侧无黑边，底部无「Sleeping」字样。
5. 解锁，退出 KOReader，插 USB，`scripts/collect_logs.sh /Volumes/Kindle`。
6. 看 `onepage.log`：应只有 `请求今日图文` 与 `完成` 两条 info，没有 warn。看收集到的 PNG：1080 宽左右、灰阶、日期是今天。

任何一步不对，先看 `onepage.log` 的最后一条 warn，再去第 2 节找对应条目。

## 2. 十六项逐条

### 1. 冷启动自动出图

退出 KOReader 再打开，不动任何菜单，等 15 秒后锁屏。
**通过**：显示今日图文。**排查**：`onepage.log` 无 `请求今日图文` → `init` 没跑到，检查插件目录名与 `_meta.lua`。

### 2. 样式切换（离线重绘）

先断网（飞行模式），菜单 → 壁纸类型 → 白底圆角卡。
**通过**：立刻出图、四角圆滑、卡外有浅灰留白与页脚，`onepage.log` 里**没有**新的 `请求今日图文`（说明是离线重绘）。锁屏确认屏保同步换了。

### 3. 配色切换

菜单 → 配色 → 经典灰。
**通过**：`wallpaper/` 下多出一个 `card-classic-...png`；锁屏后文字对比度明显下降但清晰。切回高对比白，应直接命中缓存、不重渲染。

### 4. 关闭「自动配置屏保」

菜单 → 自动配置屏保（取消勾选）。
**通过**：诊断里屏保类型/目录恢复成关闭前的值，`拉伸填充` 恢复原状；重启 KOReader 后不再被改回去。

### 5. 断网重启

飞行模式 + 退出重开 KOReader。
**通过**：仍显示上一张壁纸，`display/wallpaper.png` 未被删除或改小；`最近状态` 为 `no_network`。

### 6. 未发布（404 冷却）

最省事的做法不是等早上 6 点，而是**把设备时间往后调 3 天**（设置 → 设备选项 → 设备时间）。然后菜单 → 下载今日一页壁纸。
**通过**：提示「今日图片未发布 (404)」，诊断出现「冷却: 今日图未发布，剩余 119 分钟」；此后 5 分钟内 `onepage.log` 不再出现新的 `请求今日图文`。测完把时间调回来。

### 7. 跨午夜

把时间调到 23:58，锁屏等 3 分钟再解锁（解锁会触发 `onResume`）。
**通过**：壁纸换成新一天；`wallpaper/` 里新日期的 PNG 出现，旧日期的被清理（同日其它方向/样式除外）。

### 8. 长文案与英文

临时把缓存里的 `YYYYMMDD.json` 的 `quote` 换成长中文（>80 字）和一段英文，删掉对应渲染 PNG（`wallpaper/` 下 `YYYYMMDD-*.png`），再开 KOReader。
**通过**：字号自动缩小、无越界、无方块字；实在放不下时末尾是省略号而不是压到日期块上。

### 9. 在线更新

需要先有一个 GitHub Release（当前 `dist/` 还没上传，这一项先跳过）。
**通过**：菜单 → 检查插件更新 → 提示新版本 → 下载安装 → 重启后版本号变化，`onepage.koplugin.previous` 备份在首次成功出图后被清掉。

### 10. 内存

用 kterm（或 KUAL 终端）在渲染时跑 `free -m` / `top -b -n1 | head`。
**通过**：渲染期间可用内存不跌破 15 MB，`crash.log` 里没有 `not enough memory`。峰值不在解码那一步，而在「缩放到覆盖屏幕」：1080×720 的 JPEG 解码成 RGB 约 3 MB，放大到盖住 1072×1448 屏幕后是 2171×1448 ≈ 12.6 MB，这一张才是要盯的。

### 11. 坏图识别

把任意一个非 JPEG 文件（比如一段文本）命名成 `screenshots/onepage/20261108.jpg` 覆盖今日图，重开 KOReader。
**通过**：菜单 → 下载今日一页壁纸能重新下载成功；诊断里今日图片从「文件损坏」变回「已就绪」。**排查**：如果一直提示「今日壁纸已存在」，说明 `is_valid_jpeg` 的头尾校验被绕过。

### 12. 横屏

KOReader 菜单 → 设置（齿轮）→ 屏幕 → 旋转 → 横屏，然后锁屏再解锁（触发 `onResume`）。
**通过**：`wallpaper/` 下出现 `1448x1072` 的 PNG，屏保是横版布局、不是拉伸的竖版；重点看日期数字有没有压到月份行、分类条文字有没有溢出到文案区。

### 13. 接口故障冷却（1 小时）

改 `onepage_api.lua` 的 `Api.IMAGE_HOSTS` 为 `{ ["image.wufazhuce.com.offline"] = true }`，重新部署（`--fresh`），手动下载今日一页壁纸。
**通过**：提示「图片地址不在受信域名内（1 小时内不再重试）」，诊断显示「冷却: 接口不可用，剩余 60 分钟」；5 分钟内不再发请求。测完改回来。同理可把 `Api.V3_BASE` 指到 `http://127.0.0.1:1` 测 `network_error` 的指数退避（这条**不该**进冷却，应该在 10/20/40…秒后重试 6 轮）。

### 14. 全新安装占位图

`scripts/deploy_usb.sh /Volumes/Kindle --fresh`，飞行模式，重开 KOReader。
**通过**：屏保是浅灰底 +「今日图文暂不可用 / 联网后会自动更新」，不是 KOReader 的启动图标；`display/wallpaper.png` 约 20 KB。关掉飞行模式、手动下载，占位图应被真实壁纸覆盖。

### 15. 横竖缓存共存

竖屏出图 → 转横屏 → 锁屏解锁 → 再转回竖屏 → 锁屏解锁。
**通过**：`wallpaper/` 下同时存在 `1072x1448` 与 `1448x1072` 两份；转回竖屏后竖版 PNG 的 mtime 没有变（说明没重渲染、直接命中缓存），锁屏立刻生效。

### 16. 调度归属

开一本书读两页 → 退回文件管理器 → **等 6 分钟**（跨过 5 分钟的兜底检查）→ 取日志。
**通过**：`onepage.log` 在这 6 分钟里仍出现 `请求今日图文`。**如果没出现**，说明关书时的 `onCloseWidget` 把唯一活着的实例停掉了，需要按 `docs/development.md` 第 16 条末尾的方案改「先建实例持锁、后建实例只注册菜单」。

## 3. 故障注入速查

| 想复现 | 怎么做 | 期望状态 |
| --- | --- | --- |
| 未发布 | 设备时间 +3 天 | `http_404`，冷却 2 小时 |
| 断网 | 飞行模式 | `no_network`，保留旧图 |
| 弱网/连不上 | `Api.V3_BASE` 改 `http://127.0.0.1:1` | `network_error`，指数退避 6 轮 |
| CDN 换域名 | `Api.IMAGE_HOSTS` 加 `.offline` 后缀 | `invalid_host`，冷却 1 小时 |
| 接口改字段 | 把 `parse_detail_full` 里的 `hp_content` 改成 `hp_content_x` | `bad_detail`，冷却 1 小时 |
| 缺元数据 | 只删 `YYYYMMDD.json`，保留 jpg | 退化为「纯照片 + 日期」，不出方块字 |
| 坏图 | 文本文件改名成 `YYYYMMDD.jpg` | `invalid_file`，重新下载 |
| 渲染失败 | 缓存目录 `chmod 000`（或用满磁盘） | 保留上一张壁纸，不写半个文件 |

改完任何一项记得改回去再打包，别把注入用的补丁提交了。

## 4. 取证与回报

```bash
scripts/collect_logs.sh /Volumes/Kindle
```

产物在 `fieldtest/<时间戳>/`：`crash.log`（全量尾部 3000 行）、`onepage.log`（只含本插件）、`listing.txt`（三个目录的 `ls -la`）、所有 PNG。回报时给这四样 + 一句「第几条、期望什么、实际什么」，比截图有用得多。

## 5. 恢复原状

1. 菜单 → 自动配置屏保 取消勾选：这会恢复插件接管前的屏保设置（类型、目录、拉伸、Sleeping 文字）。
2. 要彻底清掉，退出 KOReader 后删 `koreader/plugins/onepage.koplugin/` 与 `koreader/screenshots/onepage/` 两个目录即可，插件不在设置里留别的键。
3. 停用/卸载后锁屏回到系统自带屏保，这是预期行为。
