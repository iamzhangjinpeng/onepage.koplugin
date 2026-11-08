local _ = require("gettext")

return {
    fullname = _("一页壁纸"),
    description = _("每天取 ONE · 一个当日图文，生成全屏或白底圆角卡壁纸，并可自动配置 KOReader 屏保。"),
    author = "iamzhangjinpeng",
    version = "0.1.1",
    depends = {},
    device_support = { "Kindle" },
}
