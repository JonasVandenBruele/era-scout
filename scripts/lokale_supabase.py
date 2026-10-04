#!/usr/bin/env python3
"""Lokale nabootsing van Supabase om de app zonder echt Supabase-project te testen.

Start een ingebouwde Postgres (pgserver), past de migraties toe en serveert:
  /                      de app (map app/), met een config.js die naar deze server wijst
  /auth/v1/...           aanmelden, registreren, wachtwoord (zoals Supabase Auth)
  /rest/v1/rpc/<functie> de database-functies (zoals Supabase/PostgREST), als rol authenticated

ENKEL voor lokaal testen: geen e-mailbevestiging, eenvoudige tokens, alles in ~/.nog-een-deur-lokaal/.

    .venv/bin/python scripts/lokale_supabase.py            # http://localhost:54321
    .venv/bin/python scripts/lokale_supabase.py --reset    # met een lege database beginnen
"""
import base64
import glob
import hashlib
import json
import mimetypes
import os
import secrets
import shutil
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import pgserver
import psycopg
from psycopg.types.json import Jsonb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Kort pad: Postgres-sockets mogen niet in een lange map met spaties staan.
DATA = os.path.expanduser("~/.nog-een-deur-lokaal/postgres")
APP = os.path.join(ROOT, "app")
PORT = int(os.environ.get("PORT", "54321"))
TOKENS = {}   # access token -> user id
REFRESH = {}  # refresh token -> user id
LOCK = threading.Lock()


def setup_database():
    if "--reset" in sys.argv and os.path.exists(DATA):
        shutil.rmtree(DATA)
    os.makedirs(DATA, exist_ok=True)
    srv = pgserver.get_server(DATA, cleanup_mode=None)
    url = srv.get_uri()
    with psycopg.connect(url, autocommit=True) as con:
        fresh = con.execute("select to_regclass('public.teams') is null").fetchone()[0]
        if fresh:
            con.execute(open(os.path.join(ROOT, "tests", "supabase_stub.sql")).read())
            con.execute("""create table if not exists auth.local_login (
                             user_id uuid primary key references auth.users (id), password_hash text not null,
                             metadata jsonb not null default '{}')""")
            for path in sorted(glob.glob(os.path.join(ROOT, "supabase", "migrations", "*.sql"))):
                con.execute(open(path).read())
            print("Database aangemaakt en migraties toegepast.")
    return url


def b64(data):
    return base64.urlsafe_b64encode(json.dumps(data).encode()).rstrip(b"=").decode()


def hash_pw(pw, salt=None):
    salt = salt or secrets.token_hex(8)
    return salt + "$" + hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 100_000).hex()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, status, body=None, ctype="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def uid(self):
        auth = self.headers.get("Authorization", "")
        return TOKENS.get(auth[7:]) if auth.startswith("Bearer ") else None

    def session(self, con, user_id):
        email, meta = con.execute("""select u.email, l.metadata from auth.users u join auth.local_login l on l.user_id = u.id
                                     where u.id = %s""", (user_id,)).fetchone()
        exp = int(time.time()) + 3600
        token = f"{b64({'alg': 'none', 'typ': 'JWT'})}.{b64({'sub': str(user_id), 'email': email, 'role': 'authenticated', 'aud': 'authenticated', 'exp': exp})}.lokaal"
        refresh = secrets.token_urlsafe(24)
        TOKENS[token], REFRESH[refresh] = user_id, user_id
        user = {"id": str(user_id), "aud": "authenticated", "role": "authenticated", "email": email,
                "user_metadata": meta, "app_metadata": {"provider": "email"}, "created_at": "2026-01-01T00:00:00Z"}
        return {"access_token": token, "token_type": "bearer", "expires_in": 3600, "expires_at": exp,
                "refresh_token": refresh, "user": user}

    def do_OPTIONS(self):
        self.send(204)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/auth/v1/user":
            with psycopg.connect(DB) as con:
                uid = self.uid()
                return self.send(200, self.session(con, uid)["user"]) if uid else self.send(401, {"message": "Niet ingelogd"})
        if path == "/config.js":
            js = f'window.NOD_CONFIG = {{ supabaseUrl: "http://localhost:{PORT}", supabaseAnonKey: "lokaal" }};\n'
            return self.send(200, js.encode(), "application/javascript")
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        full = os.path.realpath(os.path.join(APP, rel))
        if not full.startswith(os.path.realpath(APP)) or not os.path.isfile(full):
            return self.send(404, {"message": "Niet gevonden"})
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith(".webmanifest"):
            ctype = "application/manifest+json"
        with open(full, "rb") as f:
            self.send(200, f.read(), ctype)

    def do_PUT(self):
        if urlparse(self.path).path != "/auth/v1/user":
            return self.send(404, {})
        uid, b = self.uid(), self.body()
        if not uid:
            return self.send(401, {"message": "Niet ingelogd"})
        with psycopg.connect(DB, autocommit=True) as con:
            if b.get("password"):
                con.execute("update auth.local_login set password_hash = %s where user_id = %s", (hash_pw(b["password"]), uid))
            return self.send(200, self.session(con, uid)["user"])

    def do_POST(self):
        url = urlparse(self.path)
        path, q = url.path, parse_qs(url.query)
        b = self.body()
        with LOCK, psycopg.connect(DB, autocommit=True) as con:
            if path == "/auth/v1/signup":
                email = (b.get("email") or "").strip().lower()
                if len(b.get("password") or "") < 6:
                    return self.send(422, {"msg": "Password should be at least 6 characters", "code": 422})
                if con.execute("select 1 from auth.users where lower(email) = %s", (email,)).fetchone():
                    return self.send(422, {"msg": "User already registered", "code": 422, "error_code": "user_already_exists"})
                uid = uuid.uuid4()
                con.execute("insert into auth.users (id, email) values (%s, %s)", (uid, email))
                con.execute("insert into auth.local_login values (%s, %s, %s)", (uid, hash_pw(b["password"]), Jsonb(b.get("data") or {})))
                return self.send(200, self.session(con, uid))
            if path == "/auth/v1/token" and q.get("grant_type") == ["password"]:
                row = con.execute("""select u.id, l.password_hash from auth.users u join auth.local_login l on l.user_id = u.id
                                     where lower(u.email) = %s""", ((b.get("email") or "").strip().lower(),)).fetchone()
                if not row or hash_pw(b.get("password") or "", row[1].split("$")[0]) != row[1]:
                    return self.send(400, {"error": "invalid_grant", "error_description": "Invalid login credentials",
                                           "msg": "Invalid login credentials", "code": 400})
                return self.send(200, self.session(con, row[0]))
            if path == "/auth/v1/token" and q.get("grant_type") == ["refresh_token"]:
                uid = REFRESH.pop(b.get("refresh_token"), None)
                return self.send(200, self.session(con, uid)) if uid else self.send(400, {"msg": "Invalid Refresh Token", "code": 400})
            if path == "/auth/v1/logout":
                return self.send(204)
            if path == "/auth/v1/recover":
                return self.send(200, {})
            if path.startswith("/rest/v1/rpc/"):
                return self.rpc(path.rsplit("/", 1)[1], b)
        return self.send(404, {"message": "Niet gevonden"})

    def rpc(self, fn, args):
        if not fn.replace("_", "").isalnum():
            return self.send(404, {"message": "Onbekende functie"})
        uid = self.uid()
        params = ", ".join(f"{k} => %({k})s" for k in args if k.replace("_", "").isalnum())
        values = {k: Jsonb(v) if isinstance(v, (dict, list)) else v for k, v in args.items()}
        with psycopg.connect(DB) as con:
            try:
                con.execute(f"set local role {'authenticated' if uid else 'anon'}")
                if uid:
                    con.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(uid),))
                row = con.execute(f"select public.{fn}({params})", values).fetchone()
                con.commit()
                return self.send(200, row[0])
            except psycopg.errors.RaiseException as e:
                con.rollback()
                return self.send(400, {"code": "P0001", "message": e.diag.message_primary, "hint": e.diag.message_hint or None, "details": None})
            except psycopg.errors.InsufficientPrivilege as e:
                con.rollback()
                return self.send(403 if uid else 401, {"code": "42501", "message": str(e).splitlines()[0], "hint": None, "details": None})
            except psycopg.Error as e:
                con.rollback()
                return self.send(400, {"code": e.sqlstate, "message": str(e).splitlines()[0], "hint": None, "details": None})


if __name__ == "__main__":
    DB = setup_database()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Lokale Supabase + app: http://localhost:{PORT}  (Ctrl+C om te stoppen)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
