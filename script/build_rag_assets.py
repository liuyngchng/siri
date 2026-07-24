#!/usr/bin/env python3
"""
将 Markdown 知识库预处理为 RAG 资源文件（Android / iOS 通用）。

用法:
    # Android
    python build_rag_assets.py --docs ./docs --out ./android/app/src/main/assets/rag/

    # iOS
    python build_rag_assets.py --docs ./docs --out ./ios/SiriApp/RagAssets/

输出:
    chunks.json  — 元数据数组 [{"file": ..., "title": ..., "content": ...}, ...]
    vectors.bin  — float32 向量矩阵 (num_chunks × dim)，小端序
    bm25_index.json — BM25 倒排索引

依赖:
    pip install openai numpy
"""

import argparse
import json
import os
import re
import struct
import sys
from pathlib import Path
from typing import List, Tuple

# ---------------------------------------------------------------------------
# 依赖检查
# ---------------------------------------------------------------------------
try:
    import numpy as np
except ImportError:
    print("缺少依赖: numpy")
    print("请安装: pip install numpy")
    sys.exit(1)

try:
    from openai import OpenAI
except ImportError:
    print("缺少依赖: openai")
    print("请安装: pip install openai")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Markdown 分块（复用自 build_md_vectordb.py）
# ---------------------------------------------------------------------------
MAX_VARCHAR_LEN = 65535


def split_by_headings(text: str, base_title: str = "") -> List[Tuple[str, str]]:
    """按 ## 标题切分，返回 [(标题, 内容), ...]"""
    sections = re.split(r"\n(?=## )", text)
    chunks = []
    for sec in sections:
        lines = sec.strip().split("\n", 1)
        heading = lines[0].lstrip("#").strip() if lines else ""
        body = lines[1].strip() if len(lines) > 1 else ""
        full_title = f"{base_title} > {heading}" if base_title else heading
        if body:
            chunks.append((full_title, body))
    return chunks


def chunk_text(title: str, body: str, chunk_size: int = 500, overlap: int = 100) -> List[Tuple[str, str]]:
    """将正文按 chunk_size 切分，带上标题前缀"""
    paragraphs = re.split(r"\n\s*\n", body)
    results = []
    current = ""
    current_len = 0

    for para in paragraphs:
        para = para.strip()
        if not para:
            continue
        para_len = len(para)

        if current_len + para_len > chunk_size and current:
            chunk_title = f"{title} (chunk {len(results) + 1})" if title else f"chunk {len(results) + 1}"
            results.append((chunk_title, current.strip()))
            overlap_text = current[-overlap:] if len(current) > overlap else current
            current = overlap_text + "\n\n" + para
            current_len = len(current)
        else:
            current = (current + "\n\n" + para).strip() if current else para
            current_len += para_len

    if current.strip():
        chunk_title = f"{title} (chunk {len(results) + 1})" if title else f"chunk {len(results) + 1}"
        results.append((chunk_title, current.strip()))

    return results


def _fixed_window_split(text: str, window: int, overlap: int, title: str) -> List[Tuple[str, str]]:
    """最终兜底：纯机械固定窗口切分"""
    results = []
    start = 0
    n = len(text)
    chunk_idx = 1
    while start < n:
        end = min(start + window, n)
        results.append((f"{title} (part {chunk_idx})", text[start:end]))
        chunk_idx += 1
        start = end - overlap if end < n else n
    return results


def safe_split_long_chunk(title: str, content: str, max_len: int = MAX_VARCHAR_LEN) -> List[Tuple[str, str]]:
    """多级兜底拆分，保证不超 VARCHAR 上限"""
    if len(content) <= max_len:
        return [(title, content)]

    def _split_by_delimiter(text: str, delimiter_pattern: str, join_sep: str = " ") -> List[str]:
        parts = re.split(delimiter_pattern, text)
        out, buf = [], ""
        for p in parts:
            p = p.strip()
            if not p:
                continue
            if len(buf) + len(p) > max_len and buf:
                out.append(buf.strip())
                buf = p
            else:
                buf = (buf + join_sep + p).strip() if buf else p
        if buf.strip():
            out.append(buf.strip())
        return out

    # Level 1: 按空行拆
    fragments = _split_by_delimiter(content, r"\n\s*\n", join_sep="\n\n")
    if all(len(f) <= max_len for f in fragments):
        return [(f"{title} (part {i+1})", f) for i, f in enumerate(fragments)]

    # Level 2: 按句子标点拆
    sentence_fragments = []
    for f in fragments:
        if len(f) <= max_len:
            sentence_fragments.append(f)
        else:
            sentence_fragments.extend(_split_by_delimiter(f, r"(?<=[。！？])", join_sep=""))
    if all(len(f) <= max_len for f in sentence_fragments):
        return [(f"{title} (part {i+1})", f) for i, f in enumerate(sentence_fragments)]

    # Level 3: 按换行拆
    line_fragments = []
    for f in sentence_fragments:
        if len(f) <= max_len:
            line_fragments.append(f)
        else:
            line_fragments.extend(_split_by_delimiter(f, r"\n", join_sep="\n"))
    if all(len(f) <= max_len for f in line_fragments):
        return [(f"{title} (part {i+1})", f) for i, f in enumerate(line_fragments)]

    # Level 4: 固定窗口兜底
    result = []
    idx = 1
    window = max_len - 100
    overlap = 100
    for f in line_fragments:
        if len(f) <= max_len:
            result.append((f"{title} (part {idx})", f))
            idx += 1
        else:
            for t, c in _fixed_window_split(f, window, overlap, title):
                result.append((f"{title} (part {idx})", c))
                idx += 1
    return result


def load_markdown_files(docs_paths: List[str], chunk_size: int = 500, overlap: int = 100) -> List[Tuple[str, str, str]]:
    """
    读取多个 .md 文件或目录，返回 [(文件名, 块标题, 块内容), ...]
    docs_paths 可以混合文件路径和目录路径。
    """
    all_chunks = []
    md_files: List[Path] = []

    for p in docs_paths:
        doc_path = Path(p)
        if not doc_path.exists():
            print(f"警告: 路径不存在 -> {p}")
            continue
        if doc_path.is_file():
            if doc_path.suffix == ".md":
                md_files.append(doc_path)
        else:
            md_files.extend(sorted(doc_path.rglob("*.md")))

    # 去重
    md_files = list(dict.fromkeys(md_files))

    if not md_files:
        print("警告: 未找到 .md 文件")
        return all_chunks

    for md_file in md_files:
        rel_path = str(md_file)
        print(f"  读取: {rel_path}")
        content = md_file.read_text(encoding="utf-8")

        sections = split_by_headings(content, base_title=rel_path)
        if not sections:
            chunks = chunk_text(rel_path, content, chunk_size, overlap)
            for title, body in chunks:
                all_chunks.append((rel_path, title, body))
        else:
            for title, body in sections:
                chunks = chunk_text(title, body, chunk_size, overlap)
                for c_title, c_body in chunks:
                    all_chunks.append((rel_path, c_title, c_body))

    # 兜底拆分超长块
    safe_chunks = []
    overflow_count = 0
    for file_path, title, body in all_chunks:
        if len(body) > MAX_VARCHAR_LEN:
            overflow_count += 1
            for s_title, s_body in safe_split_long_chunk(title, body):
                safe_chunks.append((file_path, s_title, s_body))
        else:
            safe_chunks.append((file_path, title, body))
    if overflow_count > 0:
        new_total = len(safe_chunks)
        print(f"  触发兜底拆分: {overflow_count} 个超长块 → {new_total - len(all_chunks) + overflow_count} 个安全块")
    all_chunks = safe_chunks

    print(f"  共生成 {len(all_chunks)} 个文本块")
    return all_chunks


# ---------------------------------------------------------------------------
# 嵌入
# ---------------------------------------------------------------------------
class EmbeddingClient:
    """OpenAI 兼容 embedding API（百炼 / DeepSeek / SiliconFlow 等）"""

    def __init__(self, api_base: str, api_key: str, model: str):
        self.model = model
        # Strip trailing /v1 if present, OpenAI client appends it
        base = api_base.rstrip("/")
        self.client = OpenAI(base_url=base, api_key=api_key)
        # 探测维度
        test_resp = self.client.embeddings.create(model=self.model, input=["dim test"])
        self._dim = len(test_resp.data[0].embedding)

    @property
    def dim(self) -> int:
        return self._dim

    def embed_batch(self, texts: List[str]) -> List[List[float]]:
        """批量嵌入，返回 float 列表"""
        resp = self.client.embeddings.create(model=self.model, input=texts)
        return [d.embedding for d in resp.data]


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
def write_assets(chunks: List[Tuple[str, str, str]], vectors: List[List[float]], out_dir: str):
    """写入 chunks.json + vectors.bin + bm25_index.json"""
    os.makedirs(out_dir, exist_ok=True)

    # chunks.json: 元数据
    metadata = [
        {"file": file_path, "title": title, "content": content}
        for file_path, title, content in chunks
    ]
    chunks_path = os.path.join(out_dir, "chunks.json")
    with open(chunks_path, "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)
    print(f"  写入: {chunks_path} ({len(metadata)} 条)")

    # vectors.bin: float32 raw bytes
    vecs = np.array(vectors, dtype=np.float32)
    vecs_path = os.path.join(out_dir, "vectors.bin")
    with open(vecs_path, "wb") as f:
        f.write(struct.pack("<ii", vecs.shape[0], vecs.shape[1]))  # header: num_vectors, dim
        f.write(vecs.tobytes())
    print(f"  写入: {vecs_path} ({vecs.shape[0]} × {vecs.shape[1]} float32, {os.path.getsize(vecs_path)} bytes)")

    # bm25_index.json: BM25 倒排索引
    bm25_index = build_bm25_index([c[2] for c in chunks])
    bm25_path = os.path.join(out_dir, "bm25_index.json")
    with open(bm25_path, "w", encoding="utf-8") as f:
        json.dump(bm25_index, f, ensure_ascii=False)
    print(f"  写入: {bm25_path} ({len(bm25_index.get('terms', {}))} terms)")


# ---------------------------------------------------------------------------
# BM25 倒排索引
# ---------------------------------------------------------------------------
def tokenize(text: str) -> List[str]:
    """简单分词：中文按字+二元组，英文按空格/标点切词"""
    tokens = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch.isspace():
            i += 1
            continue
        # 英文/数字：累积连续字母数字
        if ch.isascii() and ch.isalnum():
            word = ""
            while i < len(text) and text[i].isascii() and text[i].isalnum():
                word += text[i].lower()
                i += 1
            tokens.append(word)
        elif '一' <= ch <= '鿿' or '㐀' <= ch <= '䶿':
            # 中文字符：单字 + 二元组
            tokens.append(ch)
            i += 1
        else:
            # 标点/其他：跳过
            i += 1

    # 添加二元组（字符级别 bigram）
    bigrams = []
    for j in range(len(tokens) - 1):
        bigrams.append(tokens[j] + tokens[j + 1])
    tokens.extend(bigrams)
    return tokens


def build_bm25_index(doc_texts: List[str]) -> dict:
    """构建 BM25 倒排索引，输出为 Android 可直接加载的 JSON"""
    num_docs = len(doc_texts)
    doc_lengths = []
    inverted_index: dict[str, list[list[int]]] = {}  # term -> [[doc_idx, tf], ...]

    for idx, text in enumerate(doc_texts):
        tokens = tokenize(text)
        dl = len(tokens)
        doc_lengths.append(dl)

        # 统计词频
        tf_map: dict[str, int] = {}
        for t in tokens:
            tf_map[t] = tf_map.get(t, 0) + 1

        for term, tf in tf_map.items():
            if term not in inverted_index:
                inverted_index[term] = []
            inverted_index[term].append([idx, tf])

    # 转成紧凑格式：posting list 展平为 [doc_idx, tf, doc_idx, tf, ...]，减去 json 开销
    # 但对移动端来说，nested list 也够用，保持简单
    avgdl = sum(doc_lengths) / num_docs if num_docs > 0 else 0.0

    return {
        "num_docs": num_docs,
        "avgdl": round(avgdl, 2),
        "k1": 1.2,
        "b": 0.75,
        "doc_lengths": doc_lengths,
        "terms": inverted_index,
    }


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Markdown → Android RAG assets")
    parser.add_argument("--docs", type=str, nargs="+", required=True,
                        help="Markdown 文件或目录（可多个）")
    parser.add_argument("--out", type=str, default="./android/app/src/main/assets/rag/",
                        help="输出目录 (默认 ./android/app/src/main/assets/rag/)")
    parser.add_argument("--api-base", type=str,
                        default=os.getenv("RAG_API_BASE") or os.getenv("BAILIAN_API") or "",
                        help="Embedding API base URL")
    parser.add_argument("--api-key", type=str,
                        default=os.getenv("RAG_API_KEY") or os.getenv("BAILIAN_API_KEY") or "",
                        help="API Key")
    parser.add_argument("--embedding-model", type=str,
                        default=os.getenv("RAG_EMBED_MODEL") or os.getenv("BAILIAN_EMBEDDING") or "text-embedding-v3",
                        help="Embedding 模型名称 (默认 text-embedding-v3)")
    parser.add_argument("--chunk-size", type=int, default=500, help="文本块大小 (默认 500)")
    parser.add_argument("--overlap", type=int, default=100, help="重叠字符数 (默认 100)")
    parser.add_argument("--batch-size", type=int, default=32, help="嵌入批大小 (默认 32)")

    args = parser.parse_args()

    if not args.api_base or not args.api_key:
        print("错误: 需要提供 --api-base 和 --api-key，或设置环境变量 RAG_API_BASE / RAG_API_KEY")
        print("百炼示例: --api-base https://dashscope.aliyuncs.com/compatible-mode/v1 --api-key sk-xxx")
        sys.exit(1)

    # 1. 分块
    print(f"[1/3] 读取并分块 Markdown 文件 (chunk_size={args.chunk_size})...")
    chunks = load_markdown_files(args.docs, args.chunk_size, args.overlap)
    if not chunks:
        print("没有可处理的数据。")
        return

    # 2. 嵌入
    print(f"[2/3] 调用 embedding API 生成向量 (model={args.embedding_model}, batch={args.batch_size})...")
    client = EmbeddingClient(api_base=args.api_base, api_key=args.api_key, model=args.embedding_model)
    print(f"  向量维度: {client.dim}")

    vectors = []
    total = len(chunks)
    for i in range(0, total, args.batch_size):
        batch = chunks[i : i + args.batch_size]
        texts = [b[2] for b in batch]  # content
        embeddings = client.embed_batch(texts)
        vectors.extend(embeddings)
        progress = min(i + args.batch_size, total)
        print(f"  [{progress}/{total}] 已嵌入")

    # 3. 输出
    print(f"[3/3] 写入资源文件到 {args.out}...")
    write_assets(chunks, vectors, args.out)

    print(f"\n✅ 完成！输出目录: {args.out}")
    print(f"   文档块数: {total}")
    print(f"   向量维度: {client.dim}")
    print(f"   文件: chunks.json + vectors.bin + bm25_index.json")


if __name__ == "__main__":
    main()
