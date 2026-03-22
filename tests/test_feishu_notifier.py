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
                }
            }
        )
        assert notifier is not None
        assert notifier.webhook_url.endswith("/test")
        assert notifier.secret == "abc"

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
    def test_send_simple_failure_on_nonzero_code(self, mock_post):
        response = Mock()
        response.json.return_value = {"code": 99991663, "msg": "invalid signature"}
        response.raise_for_status.return_value = None
        mock_post.return_value = response

        notifier = FeishuNotifier("https://example.com/hook", secret="abc")
        assert notifier.send_simple("hello") is False
