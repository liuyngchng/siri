#!/usr/bin/env python3
"""
将 Markdown 文档构建为 Milvus Lite 向量数据库。

用法:
    python build_md_vectordb.py \
        --docs ./docs \            # md 文件目录
        --db ./vectordb/md.db \    # 输出数据库路径
        --embedding openai         # 嵌入模型 (openai / local / ollama)
        --chunk-size 500           # 文本块大小（字符数）

查询:
    python build_md_vectordb.py --db ./vectordb/md.db --query "安卓语音助手怎么实现"
"""

import argparse
import os
import re
import sys
from pathlib import Path
from typing import List, Tuple

# ---------------------------------------------------------------------------
# 依赖检查
# ---------------------------------------------------------------------------
MISSING = []
try:
    from pymilvus import MilvusClient, DataType
except ImportError:
    MISSING.append("pymilvus (pip install pymilvus)")

try:
    import numpy as np
except ImportError:
    MISSING.append("numpy")


def check_deps():
    if MISSING:
        print("缺少依赖，请先安装：")
        for m in MISSING:
            print(f"  {m}")
        print("\n一键安装: pip install pymilvus numpy")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Markdown 分块
# ---------------------------------------------------------------------------
def split_by_headings(text: str, base_title: str = "") -> List[Tuple[str, str]]:
    """
    按 ## 标题切分，返回 [(标题, 内容), ...]。
    标题保留完整层级路径方便检索。
    """
    sections = re.split(r"\n(?=## )", text)  # 在 ## 前断开
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
    """
    将正文按 chunk_size 切分，带上标题前缀。
    """
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
            # overlap：保留上一块末尾几句
            overlap_text = current[-overlap:] if len(current) > overlap else current
            current = overlap_text + "\n\n" + para
            current_len = len(current)
        else:
            if current:
                current += "\n\n" + para
            else:
                current = para
            current_len += para_len

    if current.strip():
        chunk_title = f"{title} (chunk {len(results) + 1})" if title else f"chunk {len(results) + 1}"
        results.append((chunk_title, current.strip()))

    return results


def load_markdown_files(docs_dir: str, chunk_size: int = 500, overlap: int = 100) -> List[Tuple[str, str, str]]:
    """
    扫描目录下所有 .md 文件，返回 [(文件名, 块标题, 块内容), ...]
    """
    all_chunks = []
    doc_root = Path(docs_dir)
    if not doc_root.exists():
        print(f"错误: 目录不存在 -> {docs_dir}")
        sys.exit(1)

    md_files = sorted(doc_root.rglob("*.md"))
    if not md_files:
        print(f"警告: 目录 {docs_dir} 下未找到 .md 文件")
        return all_chunks

    for md_file in md_files:
        rel_path = str(md_file.relative_to(doc_root))
        print(f"  读取: {rel_path}")
        content = md_file.read_text(encoding="utf-8")

        # 先用 ## 切分
        sections = split_by_headings(content, base_title=rel_path)
        if not sections:
            # 没有二级标题，直接按块切分
            chunks = chunk_text(rel_path, content, chunk_size, overlap)
            for title, body in chunks:
                all_chunks.append((rel_path, title, body))
        else:
            for title, body in sections:
                chunks = chunk_text(title, body, chunk_size, overlap)
                for c_title, c_body in chunks:
                    all_chunks.append((rel_path, c_title, c_body))

    print(f"  共生成 {len(all_chunks)} 个文本块")
    return all_chunks


# ---------------------------------------------------------------------------
# 嵌入模型（支持多种后端）
# ---------------------------------------------------------------------------
class EmbeddingModel:
    """嵌入模型基类"""
    def embed(self, texts: List[str]) -> List[List[float]]:
        raise NotImplementedError

    @property
    def dim(self) -> int:
        raise NotImplementedError


class OpenAIEmbedding(EmbeddingModel):
    """OpenAI 兼容 API（也支持 DeepSeek / vLLM / Ollama 等）"""

    def __init__(self, api_base: str = None, api_key: str = None, model: str = None):
        self.api_base = api_base or os.getenv("EMBED_API_BASE", "https://api.openai.com/v1")
        self.api_key = api_key or os.getenv("EMBED_API_KEY", os.getenv("OPENAI_API_KEY", "sk-xxx"))
        self.model = model or os.getenv("EMBED_MODEL", "text-embedding-3-small")

        try:
            from openai import OpenAI
        except ImportError:
            print("请安装 openai: pip install openai")
            sys.exit(1)

        self.client = OpenAI(base_url=self.api_base, api_key=self.api_key)

    @property
    def dim(self) -> int:
        return 1536  # text-embedding-3-small 默认维度

    def embed(self, texts: List[str]) -> List[List[float]]:
        resp = self.client.embeddings.create(model=self.model, input=texts)
        return [d.embedding for d in resp.data]


class LocalEmbedding(EmbeddingModel):
    """本地模型（sentence-transformers）"""

    def __init__(self, model_name: str = None):
        self.model_name = model_name or os.getenv(
            "LOCAL_EMBED_MODEL", "BAAI/bge-small-zh-v1.5"
        )
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError:
            print("请安装 sentence-transformers: pip install sentence-transformers")
            sys.exit(1)

        print(f"  加载本地模型: {self.model_name} ...")
        self._model = SentenceTransformer(self.model_name)

    @property
    def dim(self) -> int:
        return self._model.get_sentence_embedding_dimension()

    def embed(self, texts: List[str]) -> List[List[float]]:
        embeddings = self._model.encode(texts, normalize_embeddings=True)
        return embeddings.tolist()


class OllamaEmbedding(EmbeddingModel):
    """Ollama 本地 API"""

    def __init__(self, base_url: str = None, model: str = None):
        self.base_url = base_url or os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
        self.model = model or os.getenv("OLLAMA_EMBED_MODEL", "nomic-embed-text")

        try:
            import requests
        except ImportError:
            print("请安装 requests: pip install requests")
            sys.exit(1)

        self.requests = requests
        # 获取模型维度
        info = requests.post(
            f"{self.base_url}/api/embeddings",
            json={"model": self.model, "prompt": "test"},
        )
        self._dim = len(info.json()["embedding"])

    @property
    def dim(self) -> int:
        return self._dim

    def embed(self, texts: List[str]) -> List[List[float]]:
        results = []
        for text in texts:
            resp = self.requests.post(
                f"{self.base_url}/api/embeddings",
                json={"model": self.model, "prompt": text},
            )
            results.append(resp.json()["embedding"])
        return results


def create_embedding_model(backend: str) -> EmbeddingModel:
    """工厂函数"""
    if backend == "openai":
        return OpenAIEmbedding()
    elif backend == "local":
        return LocalEmbedding()
    elif backend == "ollama":
        return OllamaEmbedding()
    else:
        print(f"不支持的嵌入后端: {backend}，可选: openai / local / ollama")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Milvus 建库 & 写入
# ---------------------------------------------------------------------------
COLLECTION_NAME = "md_documents"


def create_collection(client: MilvusClient, dim: int):
    """创建或重建集合"""
    if client.has_collection(COLLECTION_NAME):
        client.drop_collection(COLLECTION_NAME)
        print(f"  已删除旧集合: {COLLECTION_NAME}")

    schema = client.create_schema(
        auto_id=True,
        enable_dynamic_field=False,
    )
    schema.add_field("id", DataType.INT64, is_primary=True, auto_id=True)
    schema.add_field("file", DataType.VARCHAR, max_length=512)
    schema.add_field("title", DataType.VARCHAR, max_length=1024)
    schema.add_field("content", DataType.VARCHAR, max_length=65535)
    schema.add_field("vector", DataType.FLOAT_VECTOR, dim=dim)

    index_params = client.prepare_index_params()
    index_params.add_index(
        field_name="vector",
        index_type="AUTOINDEX",
        metric_type="COSINE",
    )

    client.create_collection(
        collection_name=COLLECTION_NAME,
        schema=schema,
        index_params=index_params,
    )
    print(f"  集合 '{COLLECTION_NAME}' 创建成功 (dim={dim})")


def build_db(
    docs_dir: str,
    db_path: str,
    embed_backend: str,
    chunk_size: int = 500,
    overlap: int = 100,
    batch_size: int = 32,
):
    """核心流程：读 md → 分块 → 嵌入 → 写入 Milvus"""
    check_deps()

    # 1. 加载嵌入模型
    print(f"[1/4] 初始化嵌入模型 (backend={embed_backend}) ...")
    embed_model = create_embedding_model(embed_backend)
    dim = embed_model.dim

    # 2. 连接 / 创建数据库
    print(f"[2/4] 初始化 Milvus Lite 数据库: {db_path}")
    client = MilvusClient(db_path)
    create_collection(client, dim)

    # 3. 读取 & 分块
    print(f"[3/4] 读取 Markdown 文档: {docs_dir}")
    chunks = load_markdown_files(docs_dir, chunk_size, overlap)
    if not chunks:
        print("没有可写入的数据。")
        return

    # 4. 生成嵌入 & 批量写入
    print(f"[4/4] 生成嵌入并写入数据库 (batch={batch_size})...")
    total = len(chunks)
    for i in range(0, total, batch_size):
        batch = chunks[i : i + batch_size]
        texts = [b[2] for b in batch]  # content
        embeddings = embed_model.embed(texts)

        records = []
        for j, (file_path, title, content) in enumerate(batch):
            records.append({
                "file": file_path,
                "title": title,
                "content": content,
                "vector": embeddings[j],
            })

        client.insert(collection_name=COLLECTION_NAME, data=records)
        progress = min(i + batch_size, total)
        print(f"  [{progress}/{total}] 已写入")

    print(f"\n✅ 完成！数据库位置: {db_path}")
    print(f"   集合名称: {COLLECTION_NAME}")
    print(f"   文档块数: {total}")
    print(f"   嵌入维度: {dim}")


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------
def search_db(db_path: str, query: str, embed_backend: str, top_k: int = 5):
    """检索相关文档块"""
    check_deps()

    print(f"查询: \"{query}\"\n")
    print(f"{'─' * 60}")

    embed_model = create_embedding_model(embed_backend)
    client = MilvusClient(db_path)

    query_vec = embed_model.embed([query])[0]

    results = client.search(
        collection_name=COLLECTION_NAME,
        data=[query_vec],
        limit=top_k,
        output_fields=["file", "title", "content"],
    )

    for i, hits in enumerate(results):
        for j, hit in enumerate(hits):
            score = hit["distance"]
            entity = hit["entity"]
            print(f"#{j+1}  [{score:.4f}]  📄 {entity['file']}")
            print(f"     📌 {entity['title']}")
            # 截断显示
            preview = entity["content"][:300].replace("\n", " ")
            print(f"     💬 {preview}...")
            print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Markdown → Milvus Lite 向量数据库",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 构建
  python build_md_vectordb.py --docs ./docs --db ./vectordb/md.db --embedding local

  # 用 OpenAI 接口构建
  python build_md_vectordb.py --docs ./docs --db ./vectordb/md.db --embedding openai

  # 查询
  python build_md_vectordb.py --db ./vectordb/md.db --query "语音助手架构"
        """,
    )
    parser.add_argument("--docs", type=str, help="Markdown 文档目录")
    parser.add_argument("--db", type=str, default="./vectordb/md.db", help="数据库路径 (默认 ./vectordb/md.db)")
    parser.add_argument("--embedding", type=str, default="openai",
                        choices=["openai", "local", "ollama"],
                        help="嵌入模型后端 (默认 openai)")
    parser.add_argument("--chunk-size", type=int, default=500, help="文本块大小 (默认 500)")
    parser.add_argument("--overlap", type=int, default=100, help="文本块重叠字符数 (默认 100)")
    parser.add_argument("--batch-size", type=int, default=32, help="嵌入批处理大小 (默认 32)")
    parser.add_argument("--query", type=str, help="查询模式: 检索相关文档")
    parser.add_argument("--top-k", type=int, default=5, help="查询返回条数 (默认 5)")

    args = parser.parse_args()

    if args.query:
        # 查询模式
        if not os.path.exists(args.db):
            print(f"数据库不存在: {args.db}")
            sys.exit(1)
        search_db(args.db, args.query, args.embedding, args.top_k)
    elif args.docs:
        # 构建模式
        build_db(
            docs_dir=args.docs,
            db_path=args.db,
            embed_backend=args.embedding,
            chunk_size=args.chunk_size,
            overlap=args.overlap,
            batch_size=args.batch_size,
        )
    else:
        parser.print_help()
        print("\n请指定 --docs (构建模式) 或 --query (查询模式)")


if __name__ == "__main__":
    main()
