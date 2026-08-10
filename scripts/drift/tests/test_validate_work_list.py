"""Unit tests for validate_work_list.py (stdlib unittest, no network)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import validate_work_list as vwl  # noqa: E402


class ValidateWorkListTests(unittest.TestCase):
    def test_accepts_individual_http_urls_and_empty_link_lists(self):
        work_list = [
            {
                "key": "widget-a",
                "doc_links": [
                    "https://learn.microsoft.com/widget",
                    "http://example.test/path?one=1&two=2",
                ],
            },
            {"key": "internal-trigger", "doc_links": []},
        ]

        vwl.validate_work_list(work_list)

    def test_rejects_a_merged_markdown_break_url(self):
        work_list = [
            {
                "key": "widget-a",
                "doc_links": [
                    "https://learn.microsoft.com/first<br>"
                    "https://learn.microsoft.com/second",
                ],
            }
        ]

        with self.assertRaises(vwl.WorkListValidationError) as context:
            vwl.validate_work_list(work_list)

        self.assertIn("widget-a", str(context.exception))
        self.assertIn("<br>", str(context.exception))

    def test_rejects_a_link_without_a_host(self):
        work_list = [{"key": "widget-a", "doc_links": ["https://"]}]

        with self.assertRaises(vwl.WorkListValidationError):
            vwl.validate_work_list(work_list)

    def test_rejects_two_urls_merged_without_markdown(self):
        work_list = [
            {
                "key": "widget-a",
                "doc_links": [
                    "https://learn.microsoft.com/firsthttps://learn.microsoft.com/second",
                ],
            }
        ]

        with self.assertRaises(vwl.WorkListValidationError):
            vwl.validate_work_list(work_list)

    def test_rejects_invalid_url_characters_and_percent_escapes(self):
        for url in (
            "https://learn.microsoft.com\\bad",
            "https://learn.microsoft.com/{bad}",
            "https://learn.microsoft.com/path%zz",
            "https://learn.microsoft.com/emphasized*",
        ):
            with self.subTest(url=url):
                work_list = [{"key": "widget-a", "doc_links": [url]}]

                with self.assertRaises(vwl.WorkListValidationError):
                    vwl.validate_work_list(work_list)

    def test_rejects_a_non_list_doc_links_field(self):
        work_list = [{"key": "widget-a", "doc_links": "https://learn.microsoft.com/widget"}]

        with self.assertRaises(vwl.WorkListValidationError):
            vwl.validate_work_list(work_list)


if __name__ == "__main__":
    unittest.main()
