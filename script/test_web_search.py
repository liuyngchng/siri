#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (c) [2025] [liuyngchng@hotmail.com] - All rights reserved.

import os
import requests
import json

def call_deepseek_agent(query):
    """
    调用DeepSeek API，支持联网搜索
    """
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        raise ValueError("请在环境变量中设置 DEEPSEEK_API_KEY")
    
    url = "https://api.deepseek.com/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    data = {
        "model": "deepseek-v4-flash-search",  # 或 "deepseek-v4-flash-search"
        "messages": [{"role": "user", "content": query}],
   #     "search_enable": True,  # 开启联网搜索
        "temperature": 0.7,  # 可选，控制随机性
        "max_tokens": 4096  # 可选，限制输出长度
    }
    
    try:
        response = requests.post(url, headers=headers, json=data, timeout=30)
        response.raise_for_status()  # 自动检查HTTP错误
        result = response.json()
        
        # 提取返回内容
        if "choices" in result and len(result["choices"]) > 0:
            content = result["choices"][0]["message"]["content"]
            return content
        else:
            return f"API返回格式异常: {result}"
            
    except requests.exceptions.Timeout:
        return "请求超时，请稍后重试"
    except requests.exceptions.ConnectionError:
        return "网络连接失败，请检查网络"
    except requests.exceptions.HTTPError as e:
        return f"HTTP错误: {e}"
    except Exception as e:
        return f"未知错误: {e}"


def main():
    """
    主入口：交互式对话
    """
    print("🤖 DeepSeek Agent 已启动（支持联网搜索）")
    print("输入 'quit' 或 'exit' 退出程序")
    print("-" * 50)
    
    while True:
        try:
            query = input("\n💬 请输入你的问题: ").strip()
            
            if query.lower() in ['quit', 'exit', 'q']:
                print("👋 再见！")
                break
            
            if not query:
                print("⚠️ 问题不能为空，请重新输入")
                continue
            
            print("🔍 正在查询中...")
            response = call_deepseek_agent(query)
            print(f"\n📝 回答:\n{response}")
            print("-" * 50)
            
        except KeyboardInterrupt:
            print("\n\n👋 检测到中断，退出程序")
            break
        except Exception as e:
            print(f"❌ 程序异常: {e}")


if __name__ == "__main__":
    main()
