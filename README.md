# onepage.koplugin · 一页壁纸

每天（北京时间）从「ONE · 一个」取当日图文，在 Kindle 上本地合成一张设备分辨率的灰阶壁纸：照片 + 一句话 + 期号 + 日期，并自动接管 KOReader 锁屏屏保。

**v0.1.0** · 需要 Kindle 版 KOReader。

## 两种壁纸

| 全屏 | 白底圆角卡 |
| --- | --- |
| 照片与文字铺满屏幕，还原 ONE App 的图文卡片 | 同一张卡片放进白色圆角卡，浅灰画布留白，卡外有「ONE · 一个」与期号/日期/摄影署名 |
| 分区：照片 72.2% / 分类条 4.9% / 文案区 22.9%，日期块占宽 17.6% | 四角按圆弧逐行裁切，照片与文字面板一起变圆 |

两种样式都可切换**高对比白**（默认）和**经典灰**配色。浅灰底在 16 级灰墨水屏上容易糊成一片，所以默认用高对比。配色是样式的子选项，不是第三种样式。

切换样式或配色时，如果当天图片已缓存，直接离线重绘，不重新联网。

## 安装

1. 从 Releases 下载 `onepage.koplugin-vX.Y.Z.zip`，解压得到 `onepage.koplugin/` 文件夹。
2. USB 连接 Kindle，把整个文件夹放到 `/mnt/us/koreader/plugins/`。
3. 完全退出并重新打开 KOReader，在「工具 → 一页壁纸」中找到菜单。

源码归档（Source code zip）解压后需手动把文件夹改名为 `onepage.koplugin`。

## 菜单

| 菜单项 | 作用 |
| --- | --- |
| 自动配置屏保 | 默认开启。开启前备份原屏保设置，关闭时恢复。 |
| 下载今日一页壁纸 | 手动触发；今日图片已有效时提示已存在，手动请求可跳过 404 冷却。 |
| 壁纸类型 | 全屏 / 白底圆角卡。 |
| 配色 | 高对比白（默认）/ 经典灰。 |
| 检查插件更新 | 手动检查 GitHub 正式版，校验 SHA-256 后安装并保留回滚备份。 |
| 诊断 | 今日图片/文案状态、网络、屏保配置、当前样式与配色、最近请求结果。 |

## 数据与缓存

每天 3 次请求（图文 id 列表 → 图文详情 → 图片）：

```text
GET http://v3.wufazhuce.com:8000/api/hp/idlist/0?version=3.5.0&platform=android
GET http://v3.wufazhuce.com:8000/api/hp/detail/{id}?...
GET http://image.wufazhuce.com/...?imageMogr2/thumbnail/1080x/format/jpg
```

图片经 CDN 缩略到 1080 宽（实测约 75 KB，原图约 774 KB），避免 Kindle 解码大图时内存吃紧。全部请求在后台子进程执行，单次任务总时限 60 秒，不阻塞阅读界面。

图片只允许从 `image.wufazhuce.com` 下载。接口是明文 HTTP，若响应被篡改、把 `hp_img_url` 指向别的域名，插件会拒绝下载而不是照单全收；3xx 重定向也只允许同域名跳一次。

本地文件：

```text
/mnt/us/koreader/screenshots/onepage/YYYYMMDD.jpg        原图（缩略后）
/mnt/us/koreader/screenshots/onepage/YYYYMMDD.json       当日文案元数据
/mnt/us/koreader/screenshots/onepage/wallpaper/           渲染缓存 PNG
/mnt/us/koreader/screenshots/onepage/wallpaper/display/wallpaper.png   实际屏保图
```

只有校验通过的 PNG 才会发布到 `display/`。渲染失败、接口未发布、断网时保留上一张可用壁纸，不显示空白屏保。今日内容未发布按 404 处理，冷却 2 小时；跨午夜按北京时间自动换图。

元数据缺失时渲染器退化为「纯照片 + 日期」，不会出现方块字或空白文案。

## 已知限制

- 依赖非官方 v3 接口（`http://v3.wufazhuce.com:8000`，明文 HTTP，无鉴权、无 SLA）。接口变更或下线时，插件会保留最近一张可用壁纸；PC HTML 兜底解析器留待后续版本。
- 图片域名白名单固定为 `image.wufazhuce.com`；CDN 若迁移域名，需要随版本更新。
- 首版只做壁纸，不提供文章/问答阅读与历史任意日期回看（那是 one.koplugin 的职责）。
- 中文渲染依赖 KOReader 内置 `cfont` 字体与 `TextBoxWidget`；字形缺失时自动缩字号、超长句省略，仍失败则退纯照片。
- Kindle 实机显示需设备安装验证，桌面离线单测只覆盖纯逻辑。

## 开发检查

```sh
python3 -m pip install lupa
python3 -m unittest discover -s tests -v
python3 scripts/probe.py            # 联网核对今日接口字段
sh scripts/package_release.sh      # 生成安装 zip
```

测试用 `lupa` 的 Lua 运行时加载 `onepage_api.lua` / `onepage_layout.lua`，覆盖日期定位、字段解析、URL 归一化、两套样式的版式边界与圆角 inset，并编译检查全部 Lua 文件语法；不访问网络。

## 声明

本项目仅供个人学习使用，不得用于商业用途。图文内容版权归「ONE · 一个」及原作者所有；插件只在设备本地缓存，不上传、不分发图片或文案。请遵守其用户协议与相关法律法规。

## 参考

- 调度、屏保接管、PNG 发布与回滚：[danxiangli.koplugin](https://github.com/iamzhangjinpeng/danxiangli.koplugin)
- 中文排版、16 级灰抖动输出：[yiyan.koplugin](https://github.com/iamzhangjinpeng/yiyan.koplugin)
- ONE 接口字段与日期反查：[one.koplugin](https://github.com/finlater/one.koplugin)
