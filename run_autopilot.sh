#!/bin/bash
# Autopilot v3 launcher for launchd
# 确保 PATH 包含 homebrew
export PATH="/opt/homebrew/bin:$PATH"
cd ~/.autopilot && exec /usr/bin/python3 autopilot.py
