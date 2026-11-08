"""Network and packaging tests for onepage.koplugin, run against fakes.

    python3 -m pip install lupa
    python3 -m unittest discover -s tests -v

Every outbound call in the plugin is resolved through `require` at call time
(`socket.http`, `ssl.https`, `socketutil`, `dkjson`, `ffi/sha2`,
`ffi/archiver`), so preloading `package.loaded` with fakes exercises the real
control flow — redirects, size caps, zip hardening — without a network stack
or a KOReader runtime. File I/O is real, in a temporary directory.
"""

import hashlib
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

FAKES = r'''
-- KOReader runs LuaJIT (5.1), where loadstring exists; lupa ships 5.4+.
_G.loadstring = _G.loadstring or load

local queue = {}
local Fake = {}
_G.Fake = Fake

local function push(entry) queue[#queue + 1] = entry end

function Fake.push_body(body) push{ status = 200, body = body } end
function Fake.push_body_in_chunks(body, size)
    local chunks, index = {}, 1
    while index <= #body do
        chunks[#chunks + 1] = body:sub(index, index + size - 1)
        index = index + size
    end
    push{ status = 200, chunks = chunks }
end
function Fake.push_status(code, location)
    push{ status = code, headers = { location = location } }
end
function Fake.push_failure(err) push{ err = err } end
function Fake.pending() return #queue end
function Fake.reset() queue = {} end

-- socket.http and ssl.https are consumed the same way: one table argument,
-- three return values. `tcp` is only touched by onepage_update.get.
local http = {}
function http.request(request)
    local entry = table.remove(queue, 1)
    if not entry then error("unexpected request: no fake queued") end
    if entry.err then return nil, entry.err end
    local sink = request and request.sink
    if sink then
        if entry.chunks then
            for _, chunk in ipairs(entry.chunks) do sink(chunk) end
        elseif entry.body then
            sink(entry.body)
        end
        sink(nil)
    end
    return 1, entry.status or 200, entry.headers or {}
end
http.tcp = function() return function() return {} end end
package.loaded["socket.http"] = http
package.loaded["ssl.https"] = http
package.loaded["socketutil"] = { set_timeout = function() return true end }

package.loaded["logger"] = {
    info = function() end, warn = function() end,
    err = function() end, dbg = function() end,
}
package.loaded["ffi/util"] = {
    fsyncOpenedFile = function() return true end,
    fsyncDirectory = function() return true end,
    -- main.lua uses this one; harmless under the tests.
    exists = function(path) return py_mode(path) ~= nil end,
}
package.loaded["ffi"] = { C = { getpid = function() return 4242 end } }
package.loaded["ffi/sha2"] = { sha256 = function(data) return py_sha256(data) end }

package.loaded["dkjson"] = { decode = function(text) return py_decode(text) end }

package.loaded["libs/libkoreader-lfs"] = {
    mkdir = function(path) return py_mkdir(path) end,
    rmdir = function(path) return py_rmdir(path) end,
    symlinkattributes = function(path) return py_mode(path) end,
    attributes = function(path)
        local kind = py_mode(path)
        if kind then return { mode = kind } end
    end,
    dir = function(path)
        local names, list = {}, {}
        for name in py_listdir(path):gmatch("[^%z]+") do names[#names + 1] = name end
        local index = 0
        return function()
            index = index + 1
            return names[index]
        end, list
    end,
}

-- A fake ffi/archiver.Reader. Tests describe the archive as a flat list and
-- never build a real zip: the entry table is what the plugin iterates.
local archive = { entries = {} }
local Reader = {}
Reader.__index = Reader
function Reader.new() return setmetatable({}, Reader) end
function Reader:open() return true end
function Reader:close() return true end
function Reader:iterate()
    local entries, index = archive.entries, 0
    return function()
        index = index + 1
        return entries[index]
    end
end
function Reader:extractToMemory(path)
    for _, entry in ipairs(archive.entries) do
        if entry.path == path then return entry.data end
    end
end
Fake.set_entries = function(entries) archive.entries = entries end
Fake.set_archive_error = function(value) Reader.err = value end
package.loaded["ffi/archiver"] = { Reader = Reader }
'''


def to_lua(lua, value):
    """Python -> real Lua table (lupa would otherwise hand over a proxy)."""
    if isinstance(value, dict):
        table = lua.table()
        for key, item in value.items():
            table[key] = to_lua(lua, item)
        return table
    if isinstance(value, (list, tuple)):
        return lua.table_from([to_lua(lua, item) for item in value])
    return value


class FakeRuntime(unittest.TestCase):
    """One Lua state per class: module loading is the expensive part."""

    @classmethod
    def setUpClass(cls):
        cls.lua = LuaRuntime(unpack_returned_tuples=True)
        cls._install_callbacks()
        cls.lua.execute(FAKES)
        cls.api = cls.lua.eval('dofile("%s")' % (ROOT / "onepage_api.lua"))
        cls.update = cls.lua.eval('dofile("%s")' % (ROOT / "onepage_update.lua"))
        cls.fake = cls.lua.globals().Fake
        cls.call_fetch = cls.lua.eval(
            'function(m, opts) local s = m.fetch_today(opts); return s or "" end')
        cls.call_check = cls.lua.eval(
            'function(m, current) return m.check(current) or "" end')
        cls.call_parse = cls.lua.eval(
            'function(m, status) return m.parse_result(status) end')
        cls.call_paths = cls.lua.eval(
            'function(m, path) return m.paths(path) end')
        cls.call_prepare = cls.lua.eval(
            'function(m, stage, release) return m.prepare(stage, release) or "" end')
        cls.call_install = cls.lua.eval(
            'function(m, paths, stage) return m.install(paths, stage) or "" end')
        cls.call_has_backup = cls.lua.eval(
            'function(m, paths) return m.has_backup(paths) == true end')

    @classmethod
    def _install_callbacks(cls):
        def mode(path):
            if os.path.isdir(path):
                return "directory"
            if os.path.islink(path):
                return "link"
            if os.path.isfile(path):
                return "file"
            return None

        def mkdir(path):
            try:
                os.makedirs(path)
                return True
            except OSError:
                return False

        def rmdir(path):
            try:
                os.rmdir(path)
                return True
            except OSError:
                return False

        def listdir(path):
            try:
                return "\0".join(os.listdir(path))
            except OSError:
                return ""

        def sha256(data):
            if isinstance(data, str):
                try:
                    data = data.encode("latin-1")
                except UnicodeEncodeError:
                    data = data.encode("utf-8")
            return hashlib.sha256(data).hexdigest()

        def decode(text):
            if isinstance(text, bytes):
                text = text.decode("utf-8")
            return to_lua(cls.lua, json.loads(text))

        globals_ = cls.lua.globals()
        globals_.py_mode = mode
        globals_.py_mkdir = mkdir
        globals_.py_rmdir = rmdir
        globals_.py_listdir = listdir
        globals_.py_sha256 = sha256
        globals_.py_decode = decode

    def setUp(self):
        self.fake.reset()
        self.fake.set_entries(self.lua.table_from([]))
        self.fake.set_archive_error(False)
        self.tmp = tempfile.mkdtemp(prefix="onepage-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, *parts):
        return os.path.join(self.tmp, *parts)

    def read(self, path):
        with open(path, "rb") as handle:
            return handle.read()


# ---------------------------------------------------------------------------
# Api.fetch_today against a scripted server
# ---------------------------------------------------------------------------

DETAIL = {
    "hpcontent_id": "5283",
    "hp_title": "VOL.5146",
    "hp_makettime": "2026-11-08 06:00:00",
    "hp_content": "我拼命稳住情绪，不让任何人发现异状。 by 艾莉·布罗什",
    "text_author_name": "艾莉·布罗什",
    "hp_img_url": "http://image.wufazhuce.com/Fl93rM1GcYl_kdoacl-qOqTiMqMY",
}

JPEG = b"\xff\xd8" + b"\x00" * 2048 + b"\xff\xd9"


class FetchCase(FakeRuntime):
    def enqueue_idlist(self, *ids):
        self.fake.push_body(json.dumps({"res": 0, "data": list(ids)}))

    def enqueue_detail(self, **overrides):
        data = dict(DETAIL)
        data.update(overrides)
        self.fake.push_body(json.dumps({"res": 0, "data": data}))

    def options(self):
        return to_lua(self.lua, {
            "date_str": "20261108",
            "image_tmp": self.path("image.jpg"),
            "meta_tmp": self.path("meta.json"),
            "timeout": 5,
        })

    def fetch_today(self):
        return self.call_fetch(self.api, self.options())


class TestFetchToday(FetchCase):
    def test_downloads_image_and_metadata(self):
        self.enqueue_idlist("5283", "5307")
        self.enqueue_detail()
        self.fake.push_body(JPEG)
        self.assertEqual(self.fetch_today(), "downloaded")
        self.assertEqual(self.read(self.path("image.jpg")), JPEG)
        meta = json.loads(self.read(self.path("meta.json")).decode("utf-8"))
        self.assertEqual(meta["date"], "20261108")
        self.assertEqual(meta["quote"], "我拼命稳住情绪，不让任何人发现异状。")
        self.assertEqual(self.fake.pending(), 0)

    def test_idlist_http_error_is_reported_verbatim(self):
        self.fake.push_status(404)
        self.assertEqual(self.fetch_today(), "http_404")

    def test_socket_timeout_is_not_reported_as_http_status(self):
        self.fake.push_failure("timeout")
        self.assertEqual(self.fetch_today(), "timeout")

    def test_connection_reset_is_a_network_error(self):
        self.fake.push_failure("closed")
        self.assertEqual(self.fetch_today(), "network_error")

    def test_res_non_zero_is_a_decode_error(self):
        self.fake.push_body(json.dumps({"res": 1, "data": []}))
        self.assertEqual(self.fetch_today(), "decode")

    def test_truncated_idlist_is_a_decode_error(self):
        self.fake.push_body('{"res":0,"data":["5283"')
        self.assertEqual(self.fetch_today(), "decode")

    def test_empty_idlist_does_not_mean_no_today(self):
        self.fake.push_body(json.dumps({"res": 0, "data": []}))
        self.assertEqual(self.fetch_today(), "decode")

    def test_oversized_idlist_is_rejected_before_decoding(self):
        filler = json.dumps({"res": 0, "data": ["5" * 512 * 1024]})
        self.fake.push_body_in_chunks(filler, 65536)
        self.assertEqual(self.fetch_today(), "decode")

    def test_no_matching_date_is_no_today(self):
        self.enqueue_idlist("5307", "5303")
        self.enqueue_detail(hp_makettime="2026-11-07 06:00:00")
        self.enqueue_detail(hp_makettime="2026-11-06 06:00:00")
        self.assertEqual(self.fetch_today(), "no_today")

    def test_image_on_foreign_host_never_opens_a_socket(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail(hp_img_url="http://evil.example/x.jpg")
        self.assertEqual(self.fetch_today(), "invalid_host")
        self.assertEqual(self.fake.pending(), 0)
        self.assertFalse(os.path.exists(self.path("image.jpg")))

    def test_same_host_redirect_is_followed_once(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_status(302, "https://image.wufazhuce.com/moved.jpg")
        self.fake.push_body(JPEG)
        self.assertEqual(self.fetch_today(), "downloaded")
        self.assertEqual(self.read(self.path("image.jpg")), JPEG)

    def test_redirect_off_the_whitelist_is_refused(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_status(302, "https://evil.example/x.jpg")
        self.assertEqual(self.fetch_today(), "redirect_error")
        self.assertEqual(self.fake.pending(), 0)
        self.assertFalse(os.path.exists(self.path("image.jpg")))

    def test_second_redirect_is_not_followed(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_status(301, "https://image.wufazhuce.com/moved.jpg")
        self.fake.push_status(301, "https://image.wufazhuce.com/again.jpg")
        # Only one hop is tolerated, and the second is never requested.
        self.assertEqual(self.fetch_today(), "http_301")
        self.assertEqual(self.fake.pending(), 0)
        self.assertFalse(os.path.exists(self.path("image.jpg")))

    def test_image_without_jpeg_markers_is_rejected(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_body(b"GIF89a" + b"\0" * 2048)
        self.assertEqual(self.fetch_today(), "invalid_file")
        self.assertFalse(os.path.exists(self.path("image.jpg")))

    def test_truncated_jpeg_is_rejected(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_body(b"\xff\xd8" + b"\0" * 2048)
        self.assertEqual(self.fetch_today(), "invalid_file")
        self.assertFalse(os.path.exists(self.path("image.jpg")))

    def test_image_under_one_kilobyte_is_rejected(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_body(b"\xff\xd8" + b"\0" * 64 + b"\xff\xd9")
        self.assertEqual(self.fetch_today(), "invalid_file")

    def test_image_over_the_cap_is_rejected_and_removed(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_body_in_chunks(b"\xff\xd8" + b"\0" * (5 * 1024 * 1024), 65536)
        self.assertEqual(self.fetch_today(), "file_too_large")
        self.assertFalse(os.path.exists(self.path("image.jpg")))
        self.assertFalse(os.path.exists(self.path("meta.json")))

    def test_unwritable_metadata_path_reports_write_error(self):
        self.enqueue_idlist("5283")
        self.enqueue_detail()
        self.fake.push_body(JPEG)
        opts = to_lua(self.lua, {
            "date_str": "20261108",
            "image_tmp": self.path("image.jpg"),
            "meta_tmp": self.path("missing-dir", "meta.json"),
            "timeout": 5,
        })
        self.assertEqual(self.call_fetch(self.api, opts), "write_error")
        self.assertFalse(os.path.exists(self.path("image.jpg")))


# ---------------------------------------------------------------------------
# Update.check: release JSON hardening
# ---------------------------------------------------------------------------

# Deliberately unrelated to the shipping version: these cases are about the
# JSON contract, not about which release happens to be current.
VERSION = "9.9.9"
ASSET_ID = 412345678
DIGEST = "a" * 64


def release(**overrides):
    data = {
        "tag_name": "v" + VERSION,
        "draft": False,
        "prerelease": False,
        "body": "修正分隔线",
        "assets": [{
            "id": ASSET_ID,
            "name": "onepage.koplugin-v%s.zip" % VERSION,
            "state": "uploaded",
            "size": 20480,
            "digest": "sha256:" + DIGEST,
            "url": "https://api.github.com/repos/iamzhangjinpeng/onepage.koplugin"
                   "/releases/assets/%d" % ASSET_ID,
            "browser_download_url": "https://github.com/iamzhangjinpeng/onepage.koplugin"
                                    "/releases/download/v%s/onepage.koplugin-v%s.zip"
                                    % (VERSION, VERSION),
        }],
    }
    data.update(overrides)
    return data


class TestUpdateCheck(FakeRuntime):
    def check(self, payload=None, current="0.0.9", body=None):
        self.fake.push_body(body if body is not None else
                            json.dumps(payload if payload is not None else release()))
        return self.call_check(self.update, current)

    def check_release(self, current):
        return self.call_check(self.update, current)

    def test_valid_release_round_trips_through_parse_result(self):
        status = self.check()
        self.assertTrue(status.startswith("available\n"), status)
        parsed = self.call_parse(self.update, status)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["version"], VERSION)
        self.assertEqual(parsed["size"], 20480)
        self.assertEqual(parsed["digest"], DIGEST)
        self.assertEqual(parsed["asset_id"], str(ASSET_ID))
        self.assertEqual(parsed["notes"], "修正分隔线")

    def test_same_version_is_current(self):
        self.assertEqual(self.check(current=VERSION), "current")

    def test_newer_local_version_is_current(self):
        self.assertEqual(self.check(current="10.0.0"), "current")

    def test_draft_release_is_refused(self):
        self.assertEqual(self.check(release(draft=True)), "bad_release")

    def test_prerelease_is_refused(self):
        self.assertEqual(self.check(release(prerelease=True)), "bad_release")

    def test_two_part_tag_is_refused(self):
        self.assertEqual(self.check(release(tag_name="v0.2")), "bad_release")

    def test_oversized_asset_is_refused(self):
        data = release()
        data["assets"][0]["size"] = 2 * 1024 * 1024
        self.assertEqual(self.check(data), "too_large")

    def test_missing_digest_is_refused(self):
        data = release()
        del data["assets"][0]["digest"]
        self.assertEqual(self.check(data), "bad_release")

    def test_short_digest_is_refused(self):
        data = release()
        data["assets"][0]["digest"] = "sha256:abc"
        self.assertEqual(self.check(data), "bad_release")

    def test_renamed_asset_is_missing_asset(self):
        data = release()
        data["assets"][0]["name"] = "onepage.zip"
        self.assertEqual(self.check(data), "missing_asset")

    def test_asset_url_must_match_the_id(self):
        data = release()
        data["assets"][0]["url"] += "0"
        self.assertEqual(self.check(data), "bad_release")

    def test_asset_still_uploading_is_missing_asset(self):
        data = release()
        data["assets"][0]["state"] = "open"
        self.assertEqual(self.check(data), "missing_asset")

    def test_no_newer_asset_at_all_is_missing_asset(self):
        self.assertEqual(self.check(release(assets=[])), "missing_asset")

    def test_http_error_is_propagated(self):
        self.fake.push_status(404)
        self.assertEqual(self.check_release("0.0.9"), "http_404")

    def test_transport_failure_is_reported_as_network_error(self):
        # onepage_update.get does not distinguish a socket timeout: any
        # transport failure is a single retryable network_error.
        self.fake.push_failure("timeout")
        self.assertEqual(self.check_release("0.0.9"), "network_error")

    def test_multiline_notes_survive_parse_result(self):
        status = self.check(body=json.dumps(release(body="第一行\r\n第二行\n第三行")))
        parsed = self.call_parse(self.update, status)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["notes"], "第一行\n第二行\n第三行")

    def test_long_notes_are_capped_on_a_character_boundary(self):
        body = "宽" * 400
        status = self.check(body=json.dumps(release(body=body)))
        parsed = self.call_parse(self.update, status)
        self.assertTrue(parsed["notes"].endswith("…"))
        self.assertLessEqual(len(parsed["notes"]), 481)
        self.assertNotIn("\ufffd", parsed["notes"])

    def test_parse_result_rejects_a_truncated_status(self):
        self.assertIsNone(self.call_parse(self.update, "available\n0.2.0\n20480\n" + DIGEST))

    def test_parse_result_rejects_a_non_hex_digest(self):
        status = "available\n0.2.0\n20480\n%s\n%d\n说明" % ("z" * 64, ASSET_ID)
        self.assertIsNone(self.call_parse(self.update, status))

    def test_parse_result_rejects_zero_size(self):
        status = "available\n0.2.0\n0\n%s\n%d\n说明" % (DIGEST, ASSET_ID)
        self.assertIsNone(self.call_parse(self.update, status))


# ---------------------------------------------------------------------------
# Update.prepare: zip hardening
# ---------------------------------------------------------------------------

GOOD_META = 'return {\n    name = "onepage",\n    version = "%s",\n}\n' % VERSION


def file_entry(path, contents):
    return {"path": path, "size": len(contents.encode("utf-8")),
            "mode": "file", "data": contents}


def lua_file(name, contents=None):
    return file_entry("onepage.koplugin/" + name, contents)


class TestUpdatePrepare(FakeRuntime):
    def entries(self, meta_version=VERSION, main=None):
        files = {
            "_meta.lua": GOOD_META.replace(VERSION, meta_version),
            "main.lua": main or "return {}\n",
            "onepage_api.lua": "return {}\n",
            "onepage_layout.lua": "return {}\n",
            "onepage_wallpaper.lua": "return {}\n",
            "onepage_update.lua": "return {}\n",
        }
        return [lua_file(name, contents) for name, contents in files.items()]

    def prepare(self, entries=None, payload=None, digest=None, size=None):
        entries = self.entries() if entries is None else entries
        for entry in entries:
            if entry.get("size") is None:
                entry["size"] = len(entry["data"].encode("utf-8"))
        self.fake.set_entries(to_lua(self.lua, entries))
        data = payload if payload is not None else b"PK\x03\x04" + b"\x00" * 64
        stage = self.path("stage")
        os.makedirs(stage)
        self.fake.push_body(data)
        result = to_lua(self.lua, {
            "version": VERSION,
            "size": len(data) if size is None else size,
            "digest": digest if digest is not None else hashlib.sha256(data).hexdigest(),
            "asset_id": str(ASSET_ID),
        })
        return self.call_prepare(self.update, stage, result), stage

    def test_complete_package_is_prepared(self):
        status, stage = self.prepare()
        self.assertEqual(status, "prepared")
        for name in ("_meta.lua", "main.lua", "onepage_update.lua", "onepage_api.lua"):
            self.assertTrue(os.path.isfile(os.path.join(stage, "new", name)), name)

    def test_directory_entries_are_created(self):
        entries = [{"path": "onepage.koplugin/docs/", "size": 0, "mode": "directory"}] \
            + self.entries()
        status, stage = self.prepare(entries)
        self.assertEqual(status, "prepared")
        self.assertTrue(os.path.isdir(os.path.join(stage, "new", "docs")))

    def test_path_traversal_is_refused(self):
        # safe_path refuses this outright. Even without it the write cannot
        # escape: ensure_directory cannot mkdir an existing "..".
        entries = self.entries() + [file_entry(
            "onepage.koplugin/../../evil.lua", "return {}\n")]
        status, stage = self.prepare(entries)
        self.assertEqual(status, "bad_zip")
        self.assertFalse(os.path.exists(self.path("evil.lua")))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "..", "evil.lua")))

    def test_absolute_path_is_refused(self):
        entries = self.entries() + [file_entry(
            "onepage.koplugin//etc/evil.lua", "return {}\n")]
        self.assertEqual(self.prepare(entries)[0], "bad_zip")

    def test_entry_outside_the_plugin_directory_is_refused(self):
        entries = self.entries() + [file_entry("other/main.lua", "return {}\n")]
        self.assertEqual(self.prepare(entries)[0], "bad_zip")

    def test_missing_required_file_is_refused(self):
        entries = [entry for entry in self.entries() if entry["path"] != "onepage.koplugin/main.lua"]
        self.assertEqual(self.prepare(entries)[0], "bad_zip")

    def test_version_mismatch_is_refused(self):
        self.assertEqual(self.prepare(self.entries(meta_version="0.2.0"))[0], "bad_zip")

    def test_syntax_error_is_refused(self):
        self.assertEqual(self.prepare(self.entries(main="return {{{\n"))[0], "bad_zip")

    def test_bytecode_is_refused(self):
        entries = self.entries(main="\27LuaQ\0\0")
        status, stage = self.prepare(entries)
        self.assertEqual(status, "bad_zip")

    def test_duplicate_entry_is_refused(self):
        entries = self.entries() + [lua_file("main.lua", "return 1\n")]
        self.assertEqual(self.prepare(entries)[0], "bad_zip")

    def test_too_many_entries_are_refused(self):
        # A valid package plus enough padding to pass MAX_ENTRIES; without the
        # cap this archive would extract cleanly, so the cap is what fails it.
        entries = self.entries() + [
            lua_file("pad%d.lua" % index, "return {}\n") for index in range(92)]
        self.assertGreater(len(entries), 96)
        self.assertEqual(self.prepare(entries)[0], "bad_zip")

    def test_digest_mismatch_is_refused(self):
        self.assertEqual(self.prepare(digest="0" * 64)[0], "bad_digest")

    def test_size_mismatch_is_refused(self):
        # The release advertises 100 bytes but only 68 arrive.
        self.assertEqual(self.prepare(payload=b"PK\x03\x04" + b"\x00" * 64,
                                      size=100)[0], "bad_digest")

    def test_non_zip_payload_is_refused(self):
        self.assertEqual(self.prepare(payload=b"GIF89a" + b"\x00" * 64)[0], "bad_zip")

    def test_archiver_error_is_refused(self):
        self.fake.set_archive_error(True)
        self.assertEqual(self.prepare()[0], "bad_zip")

    def test_empty_file_is_refused(self):
        entries = self.entries()
        entries.append(file_entry("onepage.koplugin/empty.lua", ""))
        self.assertEqual(self.prepare(entries)[0], "bad_zip")


# ---------------------------------------------------------------------------
# Update.install: the rename dance
# ---------------------------------------------------------------------------

class TestUpdateInstall(FakeRuntime):
    def setUp(self):
        super().setUp()
        self.live = self.path("plugins", "onepage.koplugin")
        os.makedirs(self.live)
        Path(self.live, "main.lua").write_text("old\n")
        self.stage = self.path("stage")
        os.makedirs(os.path.join(self.stage, "new"))
        Path(self.stage, "new", "main.lua").write_text("new\n")
        self.handles = self.call_paths(self.update, self.live)

    def test_install_keeps_the_old_tree_as_a_backup(self):
        self.assertEqual(self.call_install(self.update, self.handles, self.stage), "installed")
        self.assertEqual(Path(self.live, "main.lua").read_text(), "new\n")
        backup = Path(self.live + ".previous", "main.lua")
        self.assertEqual(backup.read_text(), "old\n")
        self.assertTrue(self.call_has_backup(self.update, self.handles))

    def test_existing_backup_blocks_a_second_install(self):
        self.call_install(self.update, self.handles, self.stage)
        os.makedirs(os.path.join(self.stage, "new"))
        self.assertEqual(self.call_install(self.update, self.handles, self.stage), "install_error")

    def test_missing_stage_tree_is_refused(self):
        shutil.rmtree(os.path.join(self.stage, "new"))
        self.assertEqual(self.call_install(self.update, self.handles, self.stage), "install_error")
        self.assertEqual(Path(self.live, "main.lua").read_text(), "old\n")

    def test_missing_live_directory_is_refused(self):
        shutil.rmtree(self.live)
        self.assertEqual(self.call_install(self.update, self.handles, self.stage), "install_error")

    def test_paths_rejects_a_foreign_directory(self):
        self.assertIsNone(self.call_paths(self.update, self.path("other.koplugin")))

    def test_paths_lays_out_backup_and_work(self):
        base = self.path("plugins", "onepage.koplugin")
        self.assertEqual(self.handles["live"], base)
        self.assertEqual(self.handles["backup"], base + ".previous")
        self.assertEqual(self.handles["work"], base + ".update")
        self.assertEqual(self.handles["parent"], self.path("plugins"))


if __name__ == "__main__":
    unittest.main()
