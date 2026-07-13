#!/usr/bin/env python3
"""TableVision Backend — macOS Vision OCR + AI structuring + 静态前端"""
import http.server, json, subprocess, os, sys, tempfile, re, urllib.request, threading
from pathlib import Path
from io import BytesIO
from fpdf import FPDF
from socketserver import ThreadingMixIn

PORT = 8765
BASE_DIR = Path(__file__).parent
OCR_BIN = BASE_DIR / 'ocr'
FRONTEND = BASE_DIR / 'outputs' / 'image-to-table.html'
CN_FONT = '/System/Library/Fonts/STHeiti Medium.ttc'

# AI API config (DeepSeek by default, OpenAI compatible)
AI_API_KEY = os.environ.get('OPENAI_API_KEY', '')
AI_BASE_URL = os.environ.get('OPENAI_BASE_URL', 'https://api.deepseek.com/v1')
AI_MODEL = os.environ.get('AI_MODEL', 'deepseek-chat')

class ThreadedHTTPServer(ThreadingMixIn, http.server.HTTPServer):
    """Handle requests concurrently so health checks work during OCR"""
    daemon_threads = True

def parse_multipart(body, boundary):
    """Simple multipart/form-data parser"""
    parts = {}
    boundary = boundary.encode() if isinstance(boundary, str) else boundary
    delim = b'--' + boundary
    chunks = body.split(delim)
    for chunk in chunks[1:]:
        if chunk.startswith(b'--'): break
        if b'\r\n\r\n' not in chunk: continue
        header_block, data = chunk.split(b'\r\n\r\n', 1)
        data = data.rstrip(b'\r\n')
        name_match = re.search(rb'name="([^"]+)"', header_block)
        fname_match = re.search(rb'filename="([^"]+)"', header_block)
        if name_match:
            name = name_match.group(1).decode()
            parts[name] = {
                'data': data,
                'filename': fname_match.group(1).decode() if fname_match else None
            }
    return parts


def generate_pdf(headers, rows):
    """Generate a PDF table with Chinese font support using fpdf2"""
    import warnings
    warnings.filterwarnings('ignore')

    pdf = FPDF(orientation='L', unit='mm', format='A4')
    pdf.add_font('CN', '', CN_FONT)
    pdf.set_auto_page_break(auto=True, margin=15)
    pdf.add_page()

    # Title
    pdf.set_font('CN', size=14)
    pdf.cell(text='TableVision — 表格导出', new_x='LMARGIN', new_y='NEXT')
    pdf.ln(4)

    n_cols = len(headers)
    page_w = pdf.w - pdf.l_margin - pdf.r_margin  # usable width
    col_w = page_w / n_cols if n_cols else page_w

    # Header row
    pdf.set_font('CN', size=9)
    pdf.set_fill_color(40, 50, 70)
    pdf.set_text_color(230, 235, 240)
    for h in headers:
        pdf.cell(w=col_w, h=8, text=h, border=1, fill=True, align='C')
    pdf.ln()

    # Data rows
    pdf.set_text_color(30, 30, 30)
    pdf.set_font('CN', size=8)
    for ri, row in enumerate(rows):
        # Calculate max lines needed for this row
        cells_text = []
        max_lines = 1
        for ci, h in enumerate(headers):
            text = row.get(h, '') if isinstance(row, dict) else (row[ci] if ci < len(row) else '')
            # Replace \\n with actual newlines
            text = text.replace('\\n', '\n')
            lines = text.split('\n')
            cells_text.append(lines)
            max_lines = max(max_lines, len(lines))

        row_h = max(7, max_lines * 5.5)

        # Alternate row background
        if ri % 2 == 0:
            pdf.set_fill_color(245, 247, 250)
        else:
            pdf.set_fill_color(255, 255, 255)

        x_start = pdf.get_x()
        y_start = pdf.get_y()

        # Check if we need a new page
        if y_start + row_h > pdf.h - 15:
            pdf.add_page()
            y_start = pdf.get_y()

        for ci, lines in enumerate(cells_text):
            x = x_start + ci * col_w
            pdf.set_xy(x, y_start)
            # Draw cell background and border
            pdf.rect(x, y_start, col_w, row_h, style='DF')
            # Write text lines
            for li, line in enumerate(lines):
                pdf.set_xy(x + 1, y_start + 1 + li * 5.5)
                pdf.cell(w=col_w - 2, h=5, text=line[:80])  # truncate very long lines

        pdf.set_xy(x_start, y_start + row_h)

    return pdf.output()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write(f"  [{self.log_date_time_string()}] {fmt % args}\n")
        sys.stderr.flush()

    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(FRONTEND.read_bytes())
        elif self.path == '/health':
            ai_available = bool(AI_API_KEY)
            self._json(200, {'status': 'ok', 'ocr': str(OCR_BIN.exists()), 'ai': ai_available})
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == '/api/ocr':
            self._handle_ocr()
        elif self.path == '/api/export-pdf':
            self._handle_export_pdf()
        elif self.path == '/api/ai-structure':
            self._handle_ai_structure()
        else:
            self.send_error(404)

    def _handle_ocr(self):
        length = int(self.headers.get('Content-Length', 0))
        ctype = self.headers.get('Content-Type', '')

        img_data = None

        if 'multipart/form-data' in ctype:
            boundary_match = re.search(r'boundary=([^\s;]+)', ctype)
            if not boundary_match:
                self._json(400, {'error': 'Missing boundary'})
                return
            body = self.rfile.read(length)
            parts = parse_multipart(body, boundary_match.group(1))
            if 'image' in parts:
                img_data = parts['image']['data']
        elif 'application/octet-stream' in ctype or 'image/' in ctype:
            img_data = self.rfile.read(length)
        else:
            self._json(400, {'error': f'Unsupported: {ctype}'})
            return

        if not img_data:
            self._json(400, {'error': 'No image data received'})
            return

        # Save to temp file
        with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as f:
            f.write(img_data)
            tmp_path = f.name

        try:
            print(f"  → OCR: {tmp_path} ({len(img_data)} bytes)")
            sys.stdout.flush()
            result = subprocess.run(
                [str(OCR_BIN), tmp_path],
                capture_output=True, text=True, timeout=300
            )
            raw = result.stdout.strip()
            lines = [l for l in raw.split('\n') if l.strip() and not l.startswith('Unable to find')]
            print(f"  → Got {len(lines)} lines")
            sys.stdout.flush()
            self._json(200, {'lines': lines, 'count': len(lines)})
        except subprocess.TimeoutExpired:
            self._json(504, {'error': 'OCR timeout'})
        except Exception as e:
            print(f"  → ERROR: {e}")
            sys.stdout.flush()
            self._json(500, {'error': str(e)})
        finally:
            os.unlink(tmp_path)

    def _handle_export_pdf(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
            headers = data.get('headers', [])
            rows = data.get('rows', [])
        except Exception as e:
            self._json(400, {'error': f'Invalid JSON: {e}'})
            return

        if not headers:
            self._json(400, {'error': 'No headers provided'})
            return

        try:
            pdf_bytes = generate_pdf(headers, rows)
            self.send_response(200)
            self.send_header('Content-Type', 'application/pdf')
            self.send_header('Content-Disposition', 'attachment; filename="table-data.pdf"')
            self.send_header('Content-Length', len(pdf_bytes))
            self._cors_headers()
            self.end_headers()
            self.wfile.write(pdf_bytes)
            print(f"  → PDF exported ({len(pdf_bytes)} bytes)")
            sys.stdout.flush()
        except Exception as e:
            print(f"  → PDF ERROR: {e}")
            sys.stdout.flush()
            self._json(500, {'error': str(e)})

    def _handle_ai_structure(self):
        """AI-powered structuring: raw OCR lines → structured 5-column JSON"""
        if not AI_API_KEY:
            self._json(503, {'error': 'AI not configured. Set OPENAI_API_KEY environment variable.'})
            return

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
            lines = data.get('lines', [])
        except Exception as e:
            self._json(400, {'error': f'Invalid JSON: {e}'})
            return

        if not lines:
            self._json(400, {'error': 'No OCR lines provided'})
            return

        # Build prompt
        raw_text = '\n'.join(lines)
        prompt = f"""你是一个精确的数据提取助手。以下是从中国零售调价表格图片中OCR识别出的原始文本。

请从原始文本中提取每一行数据，输出为JSON数组。每一行包含以下10个字段：

| 序号 | 字段名 | 说明 | 示例 |
|------|--------|------|------|
| 1 | 商品代码 | 5-6位纯数字，如102419 | "102419" |
| 2 | 商品名称 | 商品名称，如"娃哈哈AD钙" | "外星人电解质青柠味900ml" |
| 3 | 售卖单位 | 瓶/盒/公斤/袋/包/排/支/提/罐/桶/个/条 | "瓶" |
| 4 | 原售价 | 纯数字价格，如6.9 | "6.9" |
| 5 | 现售价 | 纯数字价格，如6.5 | "6.5" |
| 6 | 原会员价 | 纯数字价格，如6.5 | "/" |
| 7 | 现会员价 | 纯数字价格，如6.5 | "6.5" |
| 8 | 生效日期 | 日期格式如"6月25日"或"7月13日" | "6月25日" |
| 9 | 门店区域 | 浙江/全国/江苏等 | "浙江" |
| 10 | 备注 | 取消会员价/新增特价等 | "取消会员价" |

**关键规则：**
- "6月25日"、"7月2日"这类X月X日格式的值一定是"生效日期"，绝对不要放入价格列
- 纯数字(如6.9、12.8、55.6)才是价格
- 如果一行有4个价格，按顺序：原售价→现售价→原会员价→现会员价
- 如果只有1-2个价格，填前两个价格列，其余价格列填"/"
- 任何字段缺失都填"/"，不要留空

原始OCR文本：
{raw_text[:8000]}

只返回JSON数组，格式：
[{{"商品代码":"102419","商品名称":"新版娃哈哈AD钙","售卖单位":"排","原售价":"7.2","现售价":"7.2","原会员价":"6.8","现会员价":"/","生效日期":"6月11日","门店区域":"浙江","备注":"/"}}]"""

        try:
            print(f"  → AI structuring {len(lines)} lines...")
            sys.stdout.flush()

            req_body = json.dumps({
                'model': AI_MODEL,
                'messages': [
                    {'role': 'system', 'content': '你是一个精确的数据提取助手，只返回JSON。'},
                    {'role': 'user', 'content': prompt}
                ],
                'temperature': 0.1,
                'max_tokens': 8000
            }).encode()

            req = urllib.request.Request(
                f"{AI_BASE_URL}/chat/completions",
                data=req_body,
                headers={
                    'Content-Type': 'application/json',
                    'Authorization': f'Bearer {AI_API_KEY}'
                }
            )

            with urllib.request.urlopen(req, timeout=60) as resp:
                result = json.loads(resp.read())
                content = result['choices'][0]['message']['content']

            # Extract JSON array from response
            content = content.strip()
            if content.startswith('```'):
                content = re.sub(r'^```\w*\n?', '', content)
                content = re.sub(r'\n?```$', '', content)

            rows = json.loads(content)
            print(f"  → AI returned {len(rows)} rows")
            sys.stdout.flush()
            self._json(200, {'rows': rows, 'count': len(rows)})

        except Exception as e:
            print(f"  → AI ERROR: {e}")
            sys.stdout.flush()
            self._json(500, {'error': str(e)})

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors_headers()
        self.end_headers()

    def _json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _cors_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

if __name__ == '__main__':
    if not OCR_BIN.exists():
        print(f"ERROR: OCR binary not found: {OCR_BIN}")
        print("Run: swiftc -o ocr ocr.swift -framework Vision -framework AppKit")
        sys.exit(1)
    if not FRONTEND.exists():
        print(f"ERROR: Frontend not found: {FRONTEND}")
        sys.exit(1)

    print(f"""
╔══════════════════════════════════════════╗
║       TableVision — 图片转表格           ║
║  macOS Vision OCR Engine (本地处理)      ║
╠══════════════════════════════════════════╣
║  → http://localhost:{PORT}               ║
║  Ctrl+C 停止                            ║
╚══════════════════════════════════════════╝
""")
    server = ThreadedHTTPServer(('0.0.0.0', PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  已停止")
        server.server_close()
