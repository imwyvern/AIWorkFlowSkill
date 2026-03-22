#!/usr/bin/env python3
"""
Feishu Notifier
- 发送飞书机器人 webhook 通知
- 支持可选签名（secret）
- 支持 text / post 两种消息格式
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import re
import time
from typing import Optional

import requests

logger = logging.getLogger(__name__)


class FeishuNotifier:
    """Feishu 机器人通知器"""

    def __init__(
        self,
        webhook_url: str,
        secret: Optional[str] = None,
        message_format: str = "text",
        title: str = "Autopilot Notification",
    ):
        self.webhook_url = webhook_url
        self.secret = secret
        self.message_format = message_format if message_format in {"text", "post"} else "text"
        self.title = title

    def _build_payload(self, text: str) -> dict:
        payload = self._build_message_payload(text)

        if self.secret:
            timestamp = str(int(time.time()))
            sign = self._generate_sign(timestamp)
            payload["timestamp"] = timestamp
            payload["sign"] = sign

        return payload

    def _build_message_payload(self, text: str) -> dict:
        if self.message_format == "post":
            return {
                "msg_type": "post",
                "content": {
                    "post": {
                        "zh_cn": {
                            "title": self._derive_post_title(text),
                            "content": self._build_post_content(text),
                        }
                    }
                },
            }

        return {
            "msg_type": "text",
            "content": {
                "text": text,
            },
        }

    def _build_post_content(self, text: str) -> list:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if not lines:
            return [[{"tag": "text", "text": "(empty message)"}]]
        return [[{"tag": "text", "text": line}] for line in lines]

    def _derive_post_title(self, text: str) -> str:
        project_name = self._extract_project_name(text)
        prefix = self._detect_title_prefix(text)
        if project_name:
            return f"{prefix} · {project_name}"
        return prefix

    def _detect_title_prefix(self, text: str) -> str:
        text = text.strip()
        if text.startswith("📊"):
            return "Autopilot Status"
        if text.startswith("❌") or text.startswith("🚨"):
            return "Autopilot Alert"
        if text.startswith("✅") or text.startswith("🎉"):
            return "Autopilot Complete"
        if text.startswith("📤"):
            return "Autopilot Dispatch"
        if text.startswith("⏸"):
            return "Autopilot Review Needed"
        return self.title

    def _extract_project_name(self, text: str) -> Optional[str]:
        patterns = [
            r"Autopilot[^\n|]*\|\s*([^\n]+)",
            r"项目\s+([^:\n]+)",
            r"^[✅❌📊📤🎉⏸🚨]+\s*([^:\n]+):",
        ]
        for pattern in patterns:
            match = re.search(pattern, text)
            if match:
                return match.group(1).strip()
        return None

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
    message_format = feishu_config.get("message_format", "text")
    title = feishu_config.get("title", "Autopilot Notification")

    if not webhook_url:
        return None

    return FeishuNotifier(
        webhook_url=webhook_url,
        secret=secret,
        message_format=message_format,
        title=title,
    )
