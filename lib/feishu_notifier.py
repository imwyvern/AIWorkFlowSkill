#!/usr/bin/env python3
"""
Feishu Notifier
- 发送飞书机器人 webhook 通知
- 支持可选签名（secret）
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import time
from typing import Optional

import requests

logger = logging.getLogger(__name__)


class FeishuNotifier:
    """Feishu 机器人通知器"""

    def __init__(self, webhook_url: str, secret: Optional[str] = None):
        self.webhook_url = webhook_url
        self.secret = secret

    def _build_payload(self, text: str) -> dict:
        payload = {
            "msg_type": "text",
            "content": {
                "text": text,
            },
        }

        if self.secret:
            timestamp = str(int(time.time()))
            sign = self._generate_sign(timestamp)
            payload["timestamp"] = timestamp
            payload["sign"] = sign

        return payload

    def _generate_sign(self, timestamp: str) -> str:
        string_to_sign = f"{timestamp}\n{self.secret}".encode("utf-8")
        digest = hmac.new(
            string_to_sign,
            msg=b"",
            digestmod=hashlib.sha256,
        ).digest()
        return base64.b64encode(digest).decode("utf-8")

    def send_simple(self, text: str) -> bool:
        try:
            response = requests.post(
                self.webhook_url,
                json=self._build_payload(text),
                timeout=30,
            )
            response.raise_for_status()
            data = response.json()
            code = data.get("code", 0)
            if code not in (0, "0", None):
                logger.warning(f"Feishu 发送失败: code={code}, msg={data.get('msg')}")
                return False
            return True
        except requests.RequestException as e:
            logger.warning(f"Feishu 发送失败: {e}")
            return False
        except ValueError as e:
            logger.warning(f"Feishu 响应解析失败: {e}")
            return False

    def notify(self, text: str) -> bool:
        return self.send_simple(text)


def create_feishu_notifier_from_config(config: dict) -> Optional[FeishuNotifier]:
    feishu_config = config.get("feishu", {})
    webhook_url = feishu_config.get("webhook_url")
    secret = feishu_config.get("secret")

    if not webhook_url:
        return None

    return FeishuNotifier(webhook_url=webhook_url, secret=secret)
