#!/usr/bin/env python3
"""
测试阿里百练 qwen-plus 联网搜索，对比不同 prompt 对时间处理的影响。

测试场景：
  A) 不带日期 — 模拟原始 test_web_search.py 的做法（只发用户原文）
  B) 带日期 — 模拟当前 LlmClient.kt 的做法（system prompt 里写"今天是X月X日"）
  C) 带日期 + 明确指令 — system prompt 强调"当前日期是X，基于当前时间回答"

用法：
  source ~/workspace/llm_py_env/bin/activate
  python script/test_bailian_search.py
"""

import os
import json
import requests
from datetime import datetime

BAILIAN_API_KEY = os.environ.get("BAILIAN_API_KEY")
if not BAILIAN_API_KEY:
    raise ValueError("请设置 BAILIAN_API_KEY 环境变量")

# 阿里百练 OpenAI 兼容接口
BAILIAN_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
MODEL = "qwen-plus"

today_str = datetime.now().strftime("%Y年%m月%d日 %A")

QUERY = "看下今天世界杯的赛程"


def call_bailian(messages, label, enable_search=True):
    """调用百练 API，打印结果"""
    print(f"\n{'='*60}")
    print(f"【{label}】")
    print(f"{'='*60}")
    print(f"system prompt: {messages[0]['content'] if messages[0]['role'] == 'system' else '(无)'}")
    print(f"user query: {messages[-1]['content']}")
    print(f"enable_search: {enable_search}")
    print(f"--- 调用中 ---")

    body = {
        "model": MODEL,
        "messages": messages,
        "stream": False,
        "max_tokens": 1024,
        "temperature": 0.7,
    }

    # 百练的联网搜索参数
    if enable_search:
        body["enable_search"] = True

    try:
        resp = requests.post(
            BAILIAN_URL,
            headers={
                "Authorization": f"Bearer {BAILIAN_API_KEY}",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=60,
        )
        resp.raise_for_status()
        result = resp.json()
        content = result["choices"][0]["message"]["content"]
        print(f"--- 回答 ---\n{content}\n")
        return content
    except Exception as e:
        print(f"--- 错误: {e} ---")
        if hasattr(e, 'response') and e.response is not None:
            print(f"response body: {e.response.text[:500]}")
        return None


# ── 测试 A: 不带日期（模拟原 test_web_search.py）──
call_bailian(
    messages=[
        {"role": "user", "content": QUERY},
    ],
    enable_search=True,
    label="A) 不带日期 — 仅用户问题",
)

# ── 测试 B: 带日期（模拟当前 LlmClient.kt）──
call_bailian(
    messages=[
        {
            "role": "system",
            "content": f"你是安卓语音助手，请用简洁的口语化中文回答，回答控制在100字以内。今天是{today_str}。",
        },
        {"role": "user", "content": QUERY},
    ],
    enable_search=True,
    label="B) 带日期 system prompt（模拟 LlmClient.kt）",
)

# ── 测试 C: 带日期 + 明确时间指令 ──
call_bailian(
    messages=[
        {
            "role": "system",
            "content": (
                f"当前日期是{today_str}。"
                f"重要：你的知识截止日期远早于当前日期。"
                f"当用户问到与时间相关的问题（如赛程、天气、新闻），你必须依赖联网搜索结果，"
                f"并以当前日期{today_str}为基准来组织回答。"
                f"如果联网搜索返回的结果与当前日期不符，明确指出时间差异。"
                f"回答控制在150字以内。"
            ),
        },
        {"role": "user", "content": QUERY},
    ],
    enable_search=True,
    label="C) 带日期 + 明确时间指令",
)

# ── 测试 D: 不带搜索，对比 ──
call_bailian(
    messages=[
        {
            "role": "system",
            "content": f"你是安卓语音助手，请用简洁的口语化中文回答，回答控制在100字以内。今天是{today_str}。",
        },
        {"role": "user", "content": QUERY},
    ],
    enable_search=False,
    label="D) 带日期但不开启搜索（对照组）",
)

print(f"\n{'='*60}")
print(f"总结: 当前日期实际为 {today_str}")
print(f"如果模型回答提到'2026年才举办'，说明模型没有正确使用当前日期信息。")
print(f"{'='*60}")
