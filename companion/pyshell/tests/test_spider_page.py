"""Pagination contract used by the original game source and companion consumer."""

import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


SHELL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHELL))
from base.spider import Spider  # noqa: E402


class SpiderPageTest(unittest.TestCase):
    def setUp(self):
        self.spider = Spider.__new__(Spider)

    def _original(self):
        path = Path(os.environ.get("XIUGOU_AUTHOR_GAME") or
                    r"E:\code\tvbox_1102\live-python\vod\game_live.py")
        if not path.is_file():
            self.skipTest("original game source missing; set XIUGOU_AUTHOR_GAME")
        spec = importlib.util.spec_from_file_location("author_game_page_fixture", path)
        author = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(author)
        return author.Spider.__new__(author.Spider)

    def test_original_game_search_slices_its_complete_platform_list(self):
        spider = self._original()
        result = spider.searchContent("fixture", False, "1")
        self.assertEqual((len(result["list"]), result["page"], result["pagecount"],
                          result["limit"], result["total"]), (3, 1, 1, 3, 3))
        self.assertEqual(spider.searchContent("fixture", False, "2"), {
            "list": [], "page": 2, "pagecount": 1, "limit": 3, "total": 3,
        })

    def test_original_game_search_preserves_upstream_page_two(self):
        spider = self._original()
        response = {"relateShow": [{"rid": "21", "roomName": "room twenty-one"},
                                    {"rid": "22", "roomName": "room twenty-two"}], "total": 42}
        with patch.object(spider, "_douyu", return_value=response) as request:
            result = spider._search_rooms("douyu", "fixture", 2)
        self.assertEqual([item["vod_id"] for item in result["list"]], ["douyu:21", "douyu:22"])
        self.assertEqual({key: value for key, value in result.items() if key != "list"}, {
            "page": 2, "pagecount": 3, "limit": 20, "total": 42,
        })
        self.assertEqual(request.call_args.args[1]["params"]["page"], 2)

    def test_complete_list_is_sliced_and_counts_all_items(self):
        items = [{"vod_id": str(index)} for index in range(5)]
        result = self.spider.page(items, 2, 2)
        self.assertEqual(result, {
            "list": [{"vod_id": "2"}, {"vod_id": "3"}],
            "page": 2, "pagecount": 3, "limit": 2, "total": 5,
        })
        self.assertEqual(len(items), 5)
        self.assertEqual(self.spider.page(items, 3, 2)["list"], [{"vod_id": "4"}])
        self.assertEqual(self.spider.page(items, 4, 2)["list"], [])

    def test_explicit_total_preserves_upstream_page_without_a_second_slice(self):
        items = [{"vod_id": "page-two-a"}, {"vod_id": "page-two-b"}]
        self.assertEqual(self.spider.page(items, 2, 20, 42), {
            "list": items, "page": 2, "pagecount": 3, "limit": 20, "total": 42,
        })
        self.assertEqual(self.spider.page(items, 3, 20, 42)["list"], items)

    def test_empty_results_keep_one_page_and_requested_page_number(self):
        for total in (None, 0):
            with self.subTest(total=total):
                self.assertEqual(self.spider.page([], 4, 60, total), {
                    "list": [], "page": 4, "pagecount": 1, "limit": 60, "total": 0,
                })
        self.assertEqual(self.spider.page([], 3, 20, 40)["pagecount"], 2)

    def test_invalid_pagination_arguments_fail_explicitly(self):
        for current, limit, total in ((0, 20, None), (-1, 20, None), (True, 20, None),
                                      (1.5, 20, None), (1, 0, None), (1, -1, None),
                                      (1, False, None), (1, 20, -1), (1, 20, True)):
            with self.subTest(current=current, limit=limit, total=total), self.assertRaises(ValueError):
                self.spider.page([], current, limit, total)
        with self.assertRaises(TypeError):
            self.spider.page("not a list", 1, 20)


if __name__ == "__main__":
    unittest.main()
