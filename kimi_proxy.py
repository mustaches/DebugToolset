# kimi_proxy.py
import os
import json
import httpx
import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import List, Optional, Literal

app = FastAPI(title="Kimi ↔ OpenAI Proxy for Antigravity IDE")

KIMI_API_KEY = os.environ.get("KIMI_API_KEY", "your-kimi-api-key")
KIMI_BASE_URL = "https://api.moonshot.cn/v1"

# ── 数据模型 ──
class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant", "tool"]
    content: str
    name: Optional[str] = None

class ChatCompletionRequest(BaseModel):
    model: str = "kimi-k2"  # Antigravity 传来的模型名
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = None
    stream: bool = False
    top_p: Optional[float] = None
    frequency_penalty: Optional[float] = None
    presence_penalty: Optional[float] = None

# ── 模型名映射 ──
MODEL_MAP = {
    "kimi-k2": "kimi-k2",
    "kimi-k2-6": "kimi-k2-6",
    "kimi-k2-6-202507": "kimi-k2-6-202507",
    "kimi-k1.5": "kimi-k1.5",
    "kimi-latest": "kimi-latest",
    # 如果 Antigravity 传的是 openai 模型名，映射到 kimi
    "gpt-4o": "kimi-k2",
    "gpt-4o-mini": "kimi-k2",
    "claude-sonnet-4.5": "kimi-k2",
}

def map_model(model: str) -> str:
    return MODEL_MAP.get(model, model)

# ── 流式转换：Kimi SSE → OpenAI SSE ──
async def stream_kimi_to_openai(kimi_stream, model: str):
    async for line in kimi_stream.aiter_lines():
        line = line.strip()
        if not line or not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            yield "data: [DONE]\n\n"
            break
        
        chunk = json.loads(data)
        # Kimi 的 chunk 格式与 OpenAI 基本一致，直接透传
        openai_chunk = {
            "id": chunk.get("id", ""),
            "object": "chat.completion.chunk",
            "created": chunk.get("created", 0),
            "model": model,
            "choices": [{
                "index": 0,
                "delta": chunk["choices"][0].get("delta", {}),
                "finish_reason": chunk["choices"][0].get("finish_reason")
            }]
        }
        yield f"data: {json.dumps(openai_chunk, ensure_ascii=False)}\n\n"

# ── 主接口 ──
@app.post("/v1/chat/completions")
async def chat_completions(req: ChatCompletionRequest):
    model = map_model(req.model)
    
    payload = {
        "model": model,
        "messages": [m.model_dump(exclude_none=True) for m in req.messages],
        "stream": req.stream,
    }
    if req.temperature is not None:
        payload["temperature"] = req.temperature
    if req.max_tokens is not None:
        payload["max_tokens"] = req.max_tokens
    if req.top_p is not None:
        payload["top_p"] = req.top_p
    
    async with httpx.AsyncClient(timeout=300.0) as client:
        response = await client.post(
            f"{KIMI_BASE_URL}/chat/completions",
            headers={"Authorization": f"Bearer {KIMI_API_KEY}"},
            json=payload
        )
    
    if req.stream:
        return StreamingResponse(
            stream_kimi_to_openai(response.aiter_lines(), model),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            }
        )
    else:
        # 非流式：直接透传（Kimi 返回格式已与 OpenAI 兼容）
        return Response(
            content=response.content,
            media_type="application/json",
            status_code=response.status_code
        )

@app.get("/v1/models")
async def list_models():
    """Antigravity 可能会查询可用模型"""
    return {
        "object": "list",
        "data": [
            {"id": "kimi-k2", "object": "model", "owned_by": "moonshot-ai"},
            {"id": "kimi-k2-6", "object": "model", "owned_by": "moonshot-ai"},
            {"id": "kimi-k1.5", "object": "model", "owned_by": "moonshot-ai"},
        ]
    }

@app.get("/health")
async def health():
    return {"status": "ok", "proxy": "kimi-openai"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=3000)
