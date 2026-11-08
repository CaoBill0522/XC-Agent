"""本地模拟的 OpenAI / Anthropic 兼容服务（流式），仅用于测试 App。
用法：python3 tool/mock_server.py <port> [fail]
fail 模式下所有对话请求返回 500，用于测试渠道故障切换。"""
import base64, json, struct, sys, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]); FAIL = len(sys.argv) > 2 and sys.argv[2] == 'fail'
# 带 responses 参数时支持 /v1/responses（含模拟 web_search 来源）；默认像多数中转站一样返回 404。
RESPONSES = 'responses' in sys.argv[2:]
KEY = "sk-test-local"
MODELS = ["mock-chat", "mock-reasoner", "gpt-4o", "dall-e-3", "claude-sonnet-4-5"]

def png(w=96, h=96, rgb=(52, 130, 255)):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

ANSWER_LONG = """为什么课堂会这么用：

- 在最简单的假设下（忽略死亡、迁移），r 确实可以近似理解为"每个个体单位时间产生的后代数"，所以叫 offspring rate 是有直觉依据的简化。
- 更准确的术语是 **per capita growth rate**（人均增长率）或 **intrinsic rate of natural increase**，等于出生率减死亡率（b − d）。

## 完整结论

这张白板的核心是**演示如何把现实问题规范地写成初值问题**：

$$\\frac{dP}{dt} = rP, \\quad P(0) = P_0, \\quad r > 0$$

方程描述变化规律，解为 $P(t) = P_0 e^{rt}$。"""

ANSWER = "你好！这是**模拟回答**。\n\n- 支持 Markdown 列表\n- 支持 `行内代码`\n\n```python\nprint('hello')\n```\n\n公式：$E=mc^2$"

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass

    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

    def start_sse(self):
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()

    def sse(self, data, event=None):
        s = (f'event: {event}\n' if event else '') + f'data: {data}\n\n'
        b = s.encode(); self.wfile.write(b'%x\r\n' % len(b) + b + b'\r\n'); self.wfile.flush()

    def end_sse(self): self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()

    def authed(self):
        ok = self.headers.get('Authorization') == f'Bearer {KEY}' or self.headers.get('x-api-key') == KEY
        if not ok: self.send_json(401, {"error": {"message": "Incorrect API key provided (mock)"}})
        return ok

    def do_GET(self):
        if self.path.startswith('/v1/models') and self.authed():
            self.send_json(200, {"object": "list", "data": [{"id": m} for m in MODELS]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if not self.authed(): return
        if FAIL: return self.send_json(500, {"error": {"message": f"mock upstream down on :{PORT}"}})
        model = body.get('model', '')
        reasoning = 'reasoner' in model
        last = ''
        for m in body.get('messages', body.get('input', [])):
            c = m.get('content'); last = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)[:80]
        base = ANSWER_LONG if 'long' in last else ANSWER
        answer = f"[{model} @ :{PORT}] " + base + f"\n\n> 收到：{last[:60]}"
        if 'image' in json.dumps(body.get('messages', []))[:100000] and 'image_url' in json.dumps(body.get('messages', [])):
            answer = f"[{model}] 我看到了你发的图片。" 

        if self.path == '/v1/images/generations':
            return self.send_json(200, {"data": [{"b64_json": base64.b64encode(png()).decode(), "revised_prompt": "一张蓝色方块（模拟）"}]})
        if self.path == '/v1/chat/completions':
            self.start_sse()
            if reasoning:
                for w in ['先分析问题，', '再组织答案。']:
                    self.sse(json.dumps({"choices": [{"delta": {"reasoning_content": w}}]})); time.sleep(0.15)
            for i in range(0, len(answer), 6):
                self.sse(json.dumps({"choices": [{"delta": {"content": answer[i:i+6]}}]})); time.sleep(0.03)
            if 'web_search_options' in body or any(t.get('type') == 'web_search' for t in body.get('tools', [])):  # 模拟联网搜索的引用来源
                self.sse(json.dumps({"choices": [{"delta": {"annotations": [
                    {"type": "url_citation", "url_citation": {"url": f"https://www.source{i}.example.com/news/{i}", "title": f"模拟来源标题 {i}：一条比较长的新闻标题"}}
                    for i in range(1, 9)]}}]}))
            self.sse(json.dumps({"choices": [], "usage": {"prompt_tokens": 12, "completion_tokens": 42}}))
            self.sse('[DONE]'); return self.end_sse()
        if self.path == '/v1/messages':
            self.start_sse()
            self.sse(json.dumps({"type": "message_start", "message": {"usage": {"input_tokens": 9}}}), 'message_start')
            for i in range(0, len(answer), 6):
                self.sse(json.dumps({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": answer[i:i+6]}}), 'content_block_delta'); time.sleep(0.03)
            self.sse(json.dumps({"type": "message_delta", "usage": {"output_tokens": 40}}), 'message_delta')
            return self.end_sse()
        if self.path == '/v1/responses' and RESPONSES:
            self.start_sse()
            if any(t.get('type') == 'web_search' for t in body.get('tools', [])):
                for i in range(1, 9):
                    self.sse(json.dumps({"type": "response.output_text.annotation.added", "annotation": {"type": "url_citation", "url": f"https://www.source{i}.example.com/news/{i}", "title": f"模拟来源标题 {i}"}}))
            for i in range(0, len(answer), 6):
                self.sse(json.dumps({"type": "response.output_text.delta", "delta": answer[i:i+6]})); time.sleep(0.03)
            self.sse(json.dumps({"type": "response.completed", "response": {"usage": {"input_tokens": 9, "output_tokens": 40}}}))
            return self.end_sse()
        self.send_json(404, {"error": {"message": f"Invalid URL (POST {self.path})"}})

ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
