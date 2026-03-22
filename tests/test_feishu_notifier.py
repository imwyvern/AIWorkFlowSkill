#!/usr/bin/env python3

from unittest.mock import Mock, patch

from lib.feishu_notifier import FeishuNotifier, create_feishu_notifier_from_config


class TestFeishuNotifier:
    def test_create_notifier_from_config_without_webhook(self):
        assert create_feishu_notifier_from_config({"feishu": {}}) is None

    def test_create_notifier_from_config_with_webhook(self):
        notifier = create_feishu_notifier_from_config(
            {
                "feishu": {
                    "webhook_url": "https://open.feishu.cn/open-apis/bot/v2/hook/test",
                    "secret": "abc",
                    "message_format": "post",
                    "title": "Build Update",
                }
            }
        )
        assert notifier is not None
        assert notifier.webhook_url.endswith("/test")
        assert notifier.secret == "abc"
        assert notifier.message_format == "post"
        assert notifier.title == "Build Update"

    def test_build_payload_text_format(self):
        notifier = FeishuNotifier("https://example.com/hook", message_format="text")
        payload = notifier._build_payload("hello")
        assert payload["msg_type"] == "text"
        assert payload["content"]["text"] == "hello"

    def test_build_payload_post_format(self):
        notifier = FeishuNotifier(
            "https://example.com/hook",
            message_format="post",
            title="Autopilot Status",
        )
        payload = notifier._build_payload("build finished")
        assert payload["msg_type"] == "post"
        assert payload["content"]["post"]["zh_cn"]["title"] == "Autopilot Status"
        assert payload["content"]["post"]["zh_cn"]["content"][0][0]["text"] == "build finished"

    def test_invalid_message_format_falls_back_to_text(self):
        notifier = FeishuNotifier("https://example.com/hook", message_format="weird")
        payload = notifier._build_payload("hello")
        assert payload["msg_type"] == "text"

    @patch("lib.feishu_notifier.requests.post")
    def test_send_simple_success(self, mock_post):
        response = Mock()
        response.json.return_value = {"code": 0}
        response.raise_for_status.return_value = None
        mock_post.return_value = response

        notifier = FeishuNotifier("https://example.com/hook")
        assert notifier.send_simple("hello") is True

        _, kwargs = mock_post.call_args
        assert kwargs["json"]["msg_type"] == "text"
        assert kwargs["json"]["content"]["text"] == "hello"

    @patch("lib.feishu_notifier.requests.post")
    def test_send_simple_success_post_format(self, mock_post):
        response = Mock()
        response.json.return_value = {"code": 0}
        response.raise_for_status.return_value = None
        mock_post.return_value = response

        notifier = FeishuNotifier("https://example.com/hook", message_format="post", title="Review Result")
        assert notifier.send_simple("LGTM") is True

        _, kwargs = mock_post.call_args
        assert kwargs["json"]["msg_type"] == "post"
        assert kwargs["json"]["content"]["post"]["zh_cn"]["title"] == "Review Result"

    @patch("lib.feishu_notifier.requests.post")
    def test_send_simple_failure_on_nonzero_code(self, mock_post):
        response = Mock()
        response.json.return_value = {"code": 99991663, "msg": "invalid signature"}
        response.raise_for_status.return_value = None
        mock_post.return_value = response

        notifier = FeishuNotifier("https://example.com/hook", secret="abc")
        assert notifier.send_simple("hello") is False
