"""Offline unit tests for the pure-Lua parts of onepage.koplugin.

    python3 -m pip install lupa
    python3 -m unittest discover -s tests -v

No KOReader runtime and no network are required. Renderer and UI code are
syntax-checked only; their behaviour needs a real Kindle.
"""

import unittest
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

TODAY_DETAIL = {
    "hpcontent_id": "5283",
    "hp_title": "VOL.5146",
    "hp_makettime": "2026-11-08 06:00:00",
    "hp_content": "我拼命稳住情绪，不让任何人发现异状。这真的太难了。 by 艾莉·布罗什",
    "hp_author": "摄影＆Volodymyr Lymariev 作品",
    "image_authors": "Volodymyr Lymariev",
    "text_author_name": "艾莉·布罗什",
    "hp_img_url": "http://image.wufazhuce.com/Fl93rM1GcYl_kdoacl-qOqTiMqMY",
    "hp_img_original_url": "http://image.wufazhuce.com/Fl93rM1GcYl_kdoacl-qOqTiMqMY",
}

IDLIST = ["5283", "5307", "5303", "5301", "5299", "5295", "5310", "5305", "5297", "5291"]


class LuaTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = LuaRuntime(unpack_returned_tuples=True)
        cls.api = cls.lua.eval('dofile("%s")' % (ROOT / "onepage_api.lua"))
        cls.layout = cls.lua.eval('dofile("%s")' % (ROOT / "onepage_layout.lua"))
        cls.validate = cls.lua.eval(
            'function(m, L) local a, b = m.validate(L); return a, b or "" end')
        cls.wrap_fetch = cls.lua.eval(
            'function(f) return function(id) return f(id) end end')

    def detail(self, **overrides):
        data = dict(TODAY_DETAIL)
        data.update(overrides)
        return self.lua.table_from(data)

    def ids(self):
        return self.lua.table_from(IDLIST)


class TestSyntax(LuaTestCase):
    def test_all_lua_files_compile(self):
        compile_file = self.lua.eval(
            'function(p) local f, e = loadfile(p); if f then return "OK" else return e end end')
        for path in sorted(ROOT.glob("*.lua")):
            with self.subTest(file=path.name):
                self.assertEqual(compile_file(str(path)), "OK")


class TestApiParsing(LuaTestCase):
    def test_clean_strips_control_characters(self):
        self.assertEqual(self.api.clean("  一句话\0带\t控制符  "), "一句话 带 控制符")

    def test_normalize_image_url_adds_thumbnail(self):
        url = self.api.normalize_image_url(TODAY_DETAIL["hp_img_url"], 1080)
        self.assertEqual(
            url,
            "http://image.wufazhuce.com/Fl93rM1GcYl_kdoacl-qOqTiMqMY"
            "?imageMogr2/thumbnail/1080x/format/jpg",
        )

    def test_normalize_image_url_drops_existing_query(self):
        source = "https://image.wufazhuce.com/abc?old=1#frag"
        self.assertEqual(
            self.api.normalize_image_url(source, 900),
            "https://image.wufazhuce.com/abc?imageMogr2/thumbnail/900x/format/jpg",
        )

    def test_normalize_image_url_rejects_bad_input(self):
        self.assertIsNone(self.api.normalize_image_url("javascript:alert(1)", 1080))
        self.assertIsNone(self.api.normalize_image_url("", 1080))
        self.assertEqual(
            self.api.normalize_image_url("https://example.com/a.jpg", 1080),
            "https://example.com/a.jpg",
        )

    def test_iso_to_compact(self):
        self.assertEqual(self.api.iso_to_compact("2026-11-08 06:00:00"), "20261108")
        self.assertIsNone(self.api.iso_to_compact("bad date"))

    def test_parse_detail_today(self):
        meta = self.api.parse_detail(self.detail())
        self.assertEqual(meta["date"], "20261108")
        self.assertEqual(meta["vol"], "5146")
        self.assertEqual(meta["quote"], "我拼命稳住情绪，不让任何人发现异状。这真的太难了。")
        self.assertEqual(meta["author"], "艾莉·布罗什")
        self.assertEqual(meta["category"], "摄影")
        self.assertEqual(meta["image_author"], "Volodymyr Lymariev")
        self.assertIn("thumbnail/1080x", meta["image_url"])

    def test_parse_detail_fullwidth_separator_keeps_utf8_intact(self):
        # Regression: [^＆&] as a Lua character class is byte-oriented and used
        # to cut Chinese text at UTF-8 continuation byte 0xBC.
        meta = self.api.parse_detail(self.detail(
            hp_author="摄影＆张三 作品",
            hp_content="今天天气很好，适合出门。 by 李四",
            text_author_name="",
        ))
        self.assertEqual(meta["category"], "摄影")
        self.assertEqual(meta["image_author"], "张三")
        self.assertEqual(meta["quote"], "今天天气很好，适合出门。")
        self.assertEqual(meta["author"], "李四")

    def test_parse_detail_without_byline(self):
        meta = self.api.parse_detail(self.detail(
            hp_content="只有一句话。", text_author_name="", hp_author=""))
        self.assertEqual(meta["quote"], "只有一句话。")
        self.assertIsNone(meta["author"])
        self.assertEqual(meta["category"], "摄影")

    def test_parse_detail_rejects_incomplete(self):
        self.assertIsNone(self.api.parse_detail(self.detail(hp_makettime="")))
        self.assertIsNone(self.api.parse_detail(self.detail(
            hp_img_url="", hp_img_original_url="")))
        self.assertIsNone(self.api.parse_detail(self.detail(hp_content="")))
        self.assertIsNone(self.api.parse_detail("not a table"))


class TestPickToday(LuaTestCase):
    def test_first_id_is_today(self):
        calls = []

        def fetch(hp_id):
            calls.append(str(hp_id))
            return self.detail() if str(hp_id) == "5283" else None

        meta = self.api.pick_today(self.ids(), self.wrap_fetch(fetch), "20261108")
        self.assertIsNotNone(meta)
        self.assertEqual(meta["vol"], "5146")
        self.assertEqual(calls, ["5283"])

    def test_max_id_is_not_today(self):
        """max(id)=5310 is a week old; picking it would show a stale wallpaper."""
        fetch = self.wrap_fetch(lambda hp_id: self.detail(
            hp_makettime="2026-11-01 06:00:00", hp_title="VOL.5139"
        ) if str(hp_id) == "5310" else None)
        self.assertIsNone(self.api.pick_today(self.ids(), fetch, "20261108"))

    def test_wrong_date_returns_nil(self):
        fetch = self.wrap_fetch(lambda _: self.detail())
        self.assertIsNone(self.api.pick_today(self.ids(), fetch, "20261107"))

    def test_falls_through_to_matching_id(self):
        calls = []

        def fetch(hp_id):
            calls.append(str(hp_id))
            if str(hp_id) == "5303":
                return self.detail(hp_title="VOL.9999")
            return None

        meta = self.api.pick_today(self.ids(), self.wrap_fetch(fetch), "20261108")
        self.assertIsNotNone(meta)
        self.assertEqual(meta["vol"], "9999")
        self.assertEqual(calls[:3], ["5283", "5307", "5303"])


class TestLayout(LuaTestCase):
    SCREENS = [(1072, 1448), (1080, 1080), (1448, 1072), (600, 800), (758, 1024)]

    def test_defaults(self):
        self.assertEqual(self.layout.style("banana"), "fullscreen")
        self.assertEqual(self.layout.style("card"), "card")
        self.assertEqual(self.layout.contrast(None), "high")
        self.assertEqual(self.layout.month_name(11), "Nov")
        self.assertEqual(self.layout.month_name(1), "Jan")

    def test_layouts_are_valid_for_all_screens_styles_palettes(self):
        for width, height in self.SCREENS:
            for style in ["fullscreen", "card"]:
                for contrast in ["high", "classic"]:
                    with self.subTest(size=(width, height), style=style, contrast=contrast):
                        L = self.layout.for_screen(width, height, style, contrast)
                        ok, reason = self.validate(self.layout, L)
                        self.assertTrue(ok, reason)
                        c = L["content"]
                        self.assertEqual(c["photo"]["h"] + c["cat"]["h"] + c["info"]["h"], c["h"])
                        self.assertEqual(c["info"]["w"] + c["date"]["w"], c["w"])
                        self.assertGreaterEqual(L["fonts"]["quote"], 11)

    def test_card_has_rounded_bounds_and_branding(self):
        L = self.layout.for_screen(1072, 1448, "card", "high")
        self.assertIsNotNone(L["card"])
        self.assertGreater(L["card"]["radius"], 0)
        self.assertIsNotNone(L["header"])
        self.assertIsNotNone(L["footer"])
        self.assertEqual(L["colors"]["info"], 0xFF)

    def test_fullscreen_has_no_card(self):
        L = self.layout.for_screen(1072, 1448, "fullscreen", "classic")
        self.assertIsNone(L["card"])
        self.assertEqual(L["colors"]["info"], 0xD9)

    def test_row_inset_is_symmetric_and_monotonic(self):
        radius, height = 40, 1000
        top = self.layout.row_inset(0, height, radius, radius)
        bottom = self.layout.row_inset(height - 1, height, radius, radius)
        self.assertEqual(top, bottom)
        self.assertGreater(top, 0)
        previous = top
        for row in range(1, radius):
            current = self.layout.row_inset(row, height, radius, radius)
            self.assertLessEqual(current, previous)
            previous = current
        self.assertEqual(self.layout.row_inset(500, height, radius, radius), 0)
        self.assertEqual(self.layout.row_inset(10, height, 0, 0), 0)


if __name__ == "__main__":
    unittest.main()
