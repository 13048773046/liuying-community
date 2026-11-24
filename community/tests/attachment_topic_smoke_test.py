# -*- coding: utf-8 -*-
"""帖子附件 + 用户创建话题 冒烟测试（真实 HTTP + 临时 SQLite）。"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)
PORT = 8793
URL = "http://127.0.0.1:%d/community/api" % PORT
PASS = 0
FAIL = 0
FAILED = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILED.append("%s | %s" % (name, str(detail)[:160]))


def req(method, path, body=None, token=None, files=None, raw=False):
    headers = {}
    data = None
    if files:
        boundary = "----att" + uuid.uuid4().hex
        parts = []
        for k, (fn, content) in files.items():
            parts.append(("--" + boundary).encode())
            parts.append(('Content-Disposition: form-data; name="%s"; filename="%s"'
                          % (k, fn)).encode("utf-8"))
            parts.append(b"Content-Type: application/octet-stream")
            parts.append(b"")
            parts.append(content)
        parts.append(("--" + boundary + "--").encode())
        data = b"\r\n".join(parts)
        headers["Content-Type"] = "multipart/form-data; boundary=" + boundary
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            b = resp.read()
            if raw:
                return resp.status, b, resp.headers
            if "json" in resp.headers.get("Content-Type", ""):
                return resp.status, json.loads(b.decode())
            return resp.status, b.decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        if raw:
            return e.code, e.read(), e.headers
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {}


def main():
    from prepare_db import make_db, seed
    db = make_db()
    os.environ["COMMUNITY_DB"] = db
    os.environ["COMMUNITY_PORT"] = str(PORT)
    os.environ["COMMUNITY_HOST"] = "127.0.0.1"
    os.environ["COMMUNITY_LOG_LEVEL"] = "WARNING"
    users, tokens, _adm = seed()
    subprocess.run(["pkill", "-f", "community/server.py"], capture_output=True)
    time.sleep(0.8)
    proc = subprocess.Popen([sys.executable, os.path.join(BASE, "server.py")],
                            env=dict(os.environ),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.2)
    tok = tokens[0]
    tok2 = tokens[1]
    try:
        s, r = req("GET", "/boards")
        boards = r.get("list", []) if s == 200 else []
        check("版块列表可用", s == 200 and len(boards) >= 1, r)
        board = boards[0]["id"]
        parent_count = int(boards[0].get("postCount") or 0)

        # 用户创建话题
        s, r = req("POST", "/topics", {"name": "  周末骑行  "}, tok)
        check("用户创建话题", s == 200 and r.get("name") == "周末骑行" and r.get("created") is True, r)
        s, r = req("POST", "/topics", {"name": "周末骑行"}, tok2)
        check("话题大小写/重复幂等", s == 200 and r.get("created") is False, r)
        s, r = req("POST", "/topics", {"name": "#夜跑#"}, tok2)
        check("话题自动去 #", s == 200 and r.get("name") == "夜跑", r)
        s, r = req("GET", "/topics?q=" + urllib.parse.quote("骑行"), token=tok)
        check("话题搜索真实过滤", s == 200 and any(x.get("name") == "周末骑行" for x in r.get("list", [])), r)
        check("话题 mine 标记", any(x.get("mine") is True for x in r.get("list", [])), r)
        s, r = req("POST", "/topics", {"name": "   "}, tok)
        check("空话题拒绝", s == 400, r)
        s, r = req("GET", "/topics?hot=1", token=tok)
        check("热门话题仍可用", s == 200 and len(r.get("list", [])) > 0, r)

        # 附件上传
        pdf = b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n"
        s, r = req("POST", "/upload-attachment", token=tok,
                   files={"file": ("旅行清单.pdf", pdf)})
        check("PDF 附件上传", s == 200 and r.get("name", "").startswith("community_attach_"), r)
        fname = r.get("name", "")
        check("附件原始名保留", r.get("label") == "旅行清单.pdf", r)
        check("附件大小可信", r.get("size") == len(pdf) and r.get("mime") == "application/pdf", r)
        s, r = req("POST", "/upload-attachment", token=tok,
                   files={"file": ("fake.pdf", b"not a pdf")})
        check("伪装 PDF 被拒", s == 400, r)
        s, r = req("POST", "/upload-attachment", token=tok,
                   files={"file": ("notes.exe", b"MZ....")})
        check("exe 附件被拒", s == 400, r)

        # 发帖 + 附件落库
        s, r = req("POST", "/post", {
            "content": "周末骑行清单，文件在附件里。",
            "boardId": board,
            "topic": ["周末骑行"],
            "attachments": [{"name": fname, "label": "旅行清单.pdf"}],
        }, tok)
        check("附件帖发布", s == 200 and r.get("post", {}).get("id"), r)
        pid = r.get("post", {}).get("id", "")
        atts = r.get("post", {}).get("attachments") or []
        check("发帖返回附件", len(atts) == 1 and atts[0].get("label") == "旅行清单.pdf"
              and atts[0].get("size") == len(pdf), atts)

        s, r = req("GET", "/post/%s" % pid, token=tok)
        check("详情返回附件", s == 200 and len(r.get("post", {}).get("attachments") or []) == 1, r)

        # 版块计数：父版块应增加
        s, r = req("GET", "/boards")
        now_count = int(r.get("list", [{}])[0].get("postCount") or 0)
        check("版块计数增加", now_count == parent_count + 1, (parent_count, now_count))

        # 下载头：原始文件名 + attachment
        s, raw, hdr = req("GET", "/media/%s?name=%s" % (fname, urllib.parse.quote("旅行清单.pdf")), raw=True)
        disp = hdr.get("Content-Disposition", "")
        check("附件下载 200", s == 200 and raw == pdf, s)
        check("附件强制下载", "attachment" in disp and "filename*=UTF-8" in disp, disp)
        check("附件 MIME", hdr.get("Content-Type") == "application/pdf", hdr.get("Content-Type"))

        # 越权/数量校验
        s, r = req("POST", "/post", {
            "content": "伪造附件", "boardId": board,
            "attachments": [{"name": "community_attach_deadbeef_x.pdf", "label": "x.pdf"}],
        }, tok)
        check("伪造附件名被拒", s == 400, r)
        s, r = req("POST", "/post", {
            "content": "超量附件", "boardId": board,
            "attachments": [{"name": fname, "label": "a.pdf"}] * 3,
        }, tok)
        check("超量附件被拒", s == 400, r)
        s, r = req("POST", "/post", {
            "content": "空附件数组", "boardId": board, "attachments": [],
        }, tok)
        check("空附件正常发布", s == 200 and not (r.get("post", {}).get("attachments") or []), r)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    print("\n===== 附件/话题冒烟：PASS %d / FAIL %d =====" % (PASS, FAIL))
    for f in FAILED:
        print("FAIL:", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
