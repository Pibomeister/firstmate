#!/usr/bin/env python3
"""Disposable GitHub stand-in. The REAL gh binary talks to it over HTTP via
GH_HOST=github.localhost + HTTP_PROXY. Holds labels/issues/comments in memory
and dumps state to a JSON file after each request. Nothing reaches github.com."""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
port, state_path, log_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
S = {"labels": {}, "issues": {}, "next": {}}
def key(o, n): return f"{o}/{n}".lower()
def repo(k):
    S["labels"].setdefault(k, []); S["issues"].setdefault(k, []); S["next"].setdefault(k, 1); return k
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("X-Oauth-Scopes", "repo, read:org"); self.end_headers(); self.wfile.write(b)
        json.dump(S, open(state_path, "w"), indent=1)
    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
    def log(self, m):
        open(log_path, "a").write(m + "\n")
    def do_GET(self):
        self.log("GET " + self.path); self.reply(200, {})
    def do_POST(self):
        p = urlparse(self.path).path; raw = self.body()
        if "/__close/" in p:
            _, o, n, num = p.split("/__close/")[1].rsplit("/", 3)[-4:] if False else ("", *p.split("/__close/")[1].split("/"))
            next(x for x in S["issues"][f"{o}/{n}"] if x["number"] == int(num))["state"] = "CLOSED"; return self.reply(200, {})
        if p.endswith("/__fail_search"):
            S["fail_search"] = not S.get("fail_search"); return self.reply(200, {})
        m = re.search(r"/repos/([^/]+)/([^/]+)/labels$", p)
        if m:
            k = repo(key(m[1], m[2])); d = json.loads(raw); self.log(f"REST create-label {k} {d['name']} #{d.get('color')}")
            if d["name"] in S["labels"][k]:
                return self.reply(422, {"message": "Validation Failed", "errors": [{"code": "already_exists"}]})
            S["labels"][k].append(d["name"]); return self.reply(201, d)
        if p.endswith("/graphql"):
            return self.graphql(json.loads(raw))
        self.log("UNHANDLED POST " + p); self.reply(404, {"message": "Not Found"})
    def do_PATCH(self):
        self.log("PATCH " + self.path); self.body(); self.reply(200, {})
    def graphql(self, q):
        t, v = q["query"], q.get("variables") or {}
        self.log("GQL " + " ".join(t.split())[:700] + " | vars=" + json.dumps(v)[:900])
        if "__type(" in t:
            return self.reply(200, {"data": {a: {"enumValues": [{"name": "ISSUE"}, {"name": "ISSUE_ADVANCED"}, {"name": "REPOSITORY"}]} for a in re.findall(r'(\w+):\s*__type', t)}})
        if "createIssue(" in t:
            i = v["input"]; rid = i["repositoryId"]; k = repo(rid)
            n = S["next"][k]; S["next"][k] += 1
            names = [x.split("|", 1)[1] for x in i.get("labelIds", [])]
            url = f"https://github.localhost/{k}/issues/{n}"
            S["issues"][k].append({"number": n, "title": i["title"], "body": i["body"], "labels": names, "state": "OPEN", "comments": [], "url": url})
            return self.reply(200, {"data": {"createIssue": {"issue": {"id": f"I{k}|{n}", "url": url}}}})
        if "addComment" in t:
            i = v["input"]; k, n = i["subjectId"][1:].rsplit("|", 1)
            iss = next(x for x in S["issues"][k] if x["number"] == int(n)); iss["comments"].append(i["body"])
            return self.reply(200, {"data": {"addComment": {"commentEdge": {"node": {"url": iss["url"] + "#c"}}}}})
        if "search(" in t:
            if S.get("fail_search"): self.log("SEARCH forced failure"); return self.reply(200, {"errors": [{"message": "search unavailable"}]})
            sq = v.get("q") or v.get("query") or ""; self.log("SEARCH " + sq)
            m = re.search(r"repo:(\S+)", sq); k = repo(m[1].lower())
            want = re.findall(r'label:"?([^"\s]+)"?', sq); st = "OPEN" if "state:open" in sq else None
            hits = [x for x in S["issues"][k] if all(w in x["labels"] for w in want) and (not st or x["state"] == st)]
            hits.sort(key=lambda x: -x["number"])
            nodes = [{"__typename": "Issue", "number": x["number"], "title": x["title"], "url": x["url"], "state": x["state"]} for x in hits]
            return self.reply(200, {"data": {"repository": {"hasIssuesEnabled": True}, "search": {"issueCount": len(nodes), "nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": ""}}}})
        if "viewer" in t and "repository(" not in t:
            return self.reply(200, {"data": {"viewer": {"login": "lab"}}})
        if "repository(" in t or "repository" in t:
            k = repo(key(v.get("owner"), v.get("name") or v.get("repo")))
            if "labels(" in t and "query LabelList" not in t:  # gh decodes this one strictly: only requested fields
                return self.reply(200, {"data": {"repository": {"labels": {"nodes": [{"id": f"L{k}|{n}", "name": n} for n in S["labels"][k]], "pageInfo": {"hasNextPage": False, "endCursor": ""}}}}})
            r = {"id": k, "name": k.split("/")[1], "owner": {"login": k.split("/")[0]}, "hasIssuesEnabled": True,
                 "viewerPermission": "ADMIN", "isArchived": False, "defaultBranchRef": {"name": "main"}}
            if "labels(" in t or "labels" in t:
                r["labels"] = {"totalCount": len(S["labels"][k]), "nodes": [{"id": f"L{k}|{n}", "name": n, "color": "000000", "description": "", "createdAt": "2026-10-31T00:00:00Z", "updatedAt": "2026-10-31T00:00:00Z"} for n in S["labels"][k]],
                               "pageInfo": {"hasNextPage": False, "endCursor": ""}}
            for alias, nm in re.findall(r'(\w+):\s*label\(name:\s*"([^"]+)"\)', t):
                r[alias] = {"id": f"L{k}|{nm}", "name": nm} if nm in S["labels"][k] else None
            num = v.get("number")
            if num is not None:
                iss = next((x for x in S["issues"][k] if x["number"] == num), None)
                node = {"id": f"I{k}|{num}", "number": num, "url": iss["url"] if iss else "", "__typename": "Issue", "title": iss["title"] if iss else ""} if iss else None
                r["issue"] = node; r["issueOrPullRequest"] = node
            return self.reply(200, {"data": {"repository": r, "viewer": {"login": "lab"}}})
        self.log("UNHANDLED GQL"); self.reply(200, {"errors": [{"message": "unhandled"}]})
HTTPServer(("127.0.0.1", port), H).serve_forever()
