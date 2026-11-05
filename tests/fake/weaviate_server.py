#!/usr/bin/env python3
"""Fake Weaviate HTTP API for the offline end-to-end test.

Serves fixture responses for the GET endpoints the tool reads, requires the
API key on API calls, and records any non-GET request as a violation.
Usage: weaviate_server.py <port> <violations-file> [schema-down]
With "schema-down", schema and user endpoints return HTTP 500, like a
cluster that lost Raft quorum.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
VIOLATIONS = sys.argv[2]
SCHEMA_DOWN = len(sys.argv) > 3 and sys.argv[3] == "schema-down"
API_KEY = "e2e-fixture-apikey-9001"

def shard(cls, name, n, status="READY", queue=0):
    return {"class": cls, "name": name, "objectCount": n, "vectorIndexingStatus": status,
            "vectorQueueLength": queue, "compressed": False, "loaded": True}

NODES = {"nodes": [
    {"name": f"weaviate-{i}", "status": "HEALTHY" if i != 2 else "UNAVAILABLE", "version": "1.40.3" if i != 2 else "", "gitHash": "abc",
     "operationalMode": "ReadWrite",
     "stats": {"objectCount": 1000, "shardCount": 3},
     "shards": [shard("Article", f"s{i}", 1000, "READONLY" if i == 2 else "READY", 150000 if i == 1 else 0),
                shard("Tenanted", "TenantAlpha", 10), shard("Tenanted", "TenantBeta", 10)]}
    for i in range(3)]}

SCHEMA = {"classes": [
    {"class": "Article", "vectorizer": "text2vec-transformers", "vectorIndexType": "hnsw",
     "vectorIndexConfig": {"distance": "cosine", "pq": {"enabled": False}, "bq": {"enabled": False}, "sq": {"enabled": False}, "rq": {"enabled": True, "bits": 8}},
     "replicationConfig": {"factor": 3}, "multiTenancyConfig": {"enabled": False}, "shardingConfig": {"desiredCount": 3},
     "invertedIndexConfig": {"bm25": {"b": 0.75, "k1": 1.2}},
     "moduleConfig": {"text2vec-transformers": {"vectorizeClassName": False}},
     "properties": [{"name": "title", "dataType": ["text"], "tokenization": "word"}]},
    {"class": "Tenanted", "vectorConfig": {
        "main": {"vectorizer": {"none": {}}, "vectorIndexType": "dynamic",
                 "vectorIndexConfig": {"distance": "dot", "threshold": 10000, "hnsw": {"pq": {"enabled": True}}, "flat": {"bq": {"enabled": True}}}},
        "summary": {"vectorizer": {"text2vec-transformers": {}}, "vectorIndexType": "flat", "vectorIndexConfig": {"distance": "cosine", "bq": {"enabled": True}}}},
     "replicationConfig": {"factor": 5}, "multiTenancyConfig": {"enabled": True, "autoTenantActivation": True},
     "properties": []},
]}

ROUTES = {
    "/v1/meta": {"hostname": "http://[::]:8080", "version": "1.40.3",
                 "modules": {"text2vec-transformers": {"name": "x"}, "backup-filesystem": {"backupsPath": "/var/lib/backups"}}},
    "/v1/nodes?output=verbose": NODES,
    "/v1/cluster/statistics": {"synchronized": False, "statistics": [
        {"name": f"weaviate-{i}", "status": "HEALTHY", "ready": True, "isVoter": True, "dbLoaded": True,
         "leaderId": "weaviate-0", "raft": {"state": "Leader" if i == 0 else "Follower", "term": 3, "appliedIndex": 100 + i}} for i in range(2)]},
    "/v1/schema": SCHEMA,
    "/v1/schema/Article/shards": [{"name": f"s{i}", "status": "READY", "vectorQueueSize": 0} for i in range(3)],
    "/v1/schema/Tenanted/tenants": [{"name": "TenantAlpha", "activityStatus": "ACTIVE"}, {"name": "TenantBeta", "activityStatus": "INACTIVE"},
                                    {"name": "TenantGamma", "activityStatus": "OFFLOADING"}],
    "/v1/aliases": {"aliases": [{"alias": "News", "class": "Article"}]},
    "/v1/replication/replicate/list": [{"id": "op1", "collection": "Article", "shard": "s1", "sourceNode": "weaviate-0", "targetNode": "weaviate-2",
                                        "type": "COPY", "status": {"state": "HYDRATING", "errors": [{"message": "target unreachable"}]}}],
    "/v1/backups/filesystem": [{"id": "nightly-1", "classes": ["Article"], "status": "SUCCESS"}, {"id": "nightly-2", "classes": ["Article"], "status": "FAILED"}],
    "/v1/tasks": {},
    "/v1/users/own-info": {"username": "alice@example.com", "roles": [{"name": "viewer"}]},
}

METRICS = """# HELP go_goroutines Number of goroutines
go_goroutines 512
go_memstats_heap_inuse_bytes 2.5e+09
process_resident_memory_bytes 2.9e+09
object_count{class_name="Article",shard_name="s0"} 1000
queue_size{class_name="Article",shard_name="s0"} 42
queries_durations_ms_sum{class_name="Article",query_type="vector"} %d
queries_durations_ms_count{class_name="Article",query_type="vector"} %d
queries_durations_ms{class_name="Article",quantile="0.5"} 3
some_other_metric_we_drop 1
"""

class H(BaseHTTPRequestHandler):
    calls = 0
    def log_message(self, *a): pass
    def _bad(self):
        with open(VIOLATIONS, "a") as f:
            f.write(f"{self.command} {self.path}\n")
        self.send_response(405); self.end_headers()
    do_POST = do_PUT = do_PATCH = do_DELETE = _bad
    def do_GET(self):
        p = self.path
        if p == "/metrics":
            H.calls += 1
            body = (METRICS % (1000 * H.calls, 100 * H.calls)).encode()
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers(); self.wfile.write(body); return
        if p in ("/v1/.well-known/live", "/v1/.well-known/ready"):
            self.send_response(200); self.end_headers(); return
        if self.headers.get("Authorization") != f"Bearer {API_KEY}":
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error":"unauthorized"}'); return
        if SCHEMA_DOWN and (p.startswith("/v1/schema") or p == "/v1/users/own-info"):
            self.send_response(500); self.end_headers(); self.wfile.write(b'{"error":"leader not found"}'); return
        if p == "/v1/authz/roles":
            self.send_response(403); self.end_headers(); return
        if p not in ROUTES:
            self.send_response(404); self.end_headers(); return
        body = json.dumps(ROUTES[p]).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
