#!/usr/bin/env python3
"""ERA Scout — Aanbellen: bronkoppeling en websitecontroles. Draait op de Mac van Jonas.

    .venv/bin/python scripts/scout_worker.py import [pad/naar/mirror.sqlite]   # Marketpulse-leads → ERA Scout
    .venv/bin/python scripts/scout_worker.py controleer [--max 400]              # Immoweb + makelaarswebsite
    .venv/bin/python scripts/scout_worker.py status

Waarom op de Mac: de bron (ERAForce-mirror) staat enkel in de versleutelde kluis op de SSD, en Immoweb
beantwoordt aanvragen vanaf hier zonder captcha. Er gaan geen geheimen naar de browser of naar GitHub Pages.

- Leest de mirror ALLEEN-LEZEN; stuurt enkel pand- en advertentiegegevens door, geen namen of nummers van
  personen. De mirror blijft de volledige, originele bron.
- Schrijft als rol scout_import (wachtwoord in de macOS-sleutelhanger, item "ERA Scout import (Supabase)"),
  die enkel de functies in schema worker mag gebruiken.
- Controles: één ronde tegelijk (database-lease + lokaal slot), max. 2 gelijktijdige aanvragen, minstens
  3 s tussen aanvragen naar dezelfde site, 2 herpogingen bij tijdelijke fouten, eerlijke user-agent,
  robots.txt wordt gerespecteerd. Captcha's of blokkades worden NIET omzeild: status 'failed'.
- Logt enkel aantallen en foutcodes (~/Library/Logs/era-scout-worker.log).
"""
import argparse
import datetime as dt
import fcntl
import json
import logging
import os
import re
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIRROR = os.environ.get("SCOUT_MIRROR", "/Volumes/ERAForce-mirror/mirror.sqlite")
DB_HOST = os.environ.get("SUPABASE_DB_HOST", "aws-0-eu-west-1.pooler.supabase.com")
PROJECT = os.environ.get("SUPABASE_PROJECT_ID", "okmzvzclfwhrodncjsgn")
KEYCHAIN = "ERA Scout import (Supabase)"
SOURCE = "eraforce_marketpulse"
USER_AGENT = "ERAScout-controle/1.0 (+https://jonasvandenbruele.github.io/era-scout/)"
STATE = os.path.expanduser("~/.era-scout")
LOG = os.path.expanduser("~/Library/Logs/era-scout-worker.log")

log = logging.getLogger("scout")

# ERAforce-statussen → levensloop in ERA Scout (zie README, "Aanbellen").
EXCLUDED_REASONS = {"Reeds verkocht", "Reeds verhuurd", "Dubbele prospect", "No lead", "Niet gekwalificeerd",
                    "Vrijblijvende schatting"}
# Bronvelden die we als origineel bewaren (geen persoonsgegevens).
RAW_FIELDS = ("Status", "ERA_Reden__c", "ERA_Object_Status__c", "LeadSource", "ERA_Bron_Bemiddelaar__c", "ERA_Makelaar__c",
              "ERA_Datum_op_de_markt__c", "ERA_Aantal_dagen_op_de_markt__c", "ERA_Totaal_dagen_op_de_markt__c",
              "CreatedDate", "LastModifiedDate", "ERA_Datum_Verkocht_Be_indigd__c", "ERA_Object_Type__c",
              "ERA_Actuele_Vraagprijs__c", "ERA_Initiele_Vraagprijs__c", "ERA_URL_2__c", "ERA_Explorer_URL__c")


# ============================================================ adapter: ERAforce ==

def lifecycle(status, reason):
    if status == "Geconverteerd":
        return "converted"
    if status == "Beëindigd":
        return "ended_excluded" if (reason or "").strip("​ ") in EXCLUDED_REASONS else "ended_usable"
    return "open"


def immoweb_id(url):
    m = re.search(r"/(\d{6,})(?:[/?#]|$)", url or "")
    return m.group(1) if m else None


def realo_ids(url):
    m = re.search(r"/explorer/(\d+)(?:\?l=(\d+))?", url or "")
    return (m.group(1), m.group(2)) if m else (None, None)


def iso_date(v):
    return v[:10] if v else None


def lead_to_record(lead, users, groups):
    """Eén ERAforce-Lead (rij uit de mirror) → bronrecord voor ERA Scout. Geen persoonsgegevens."""
    owner = lead.get("OwnerId") or ""
    is_queue = owner.startswith("00G")
    user = users.get(owner) or {}
    realo_p, realo_l = realo_ids(lead.get("ERA_Explorer_URL__c"))
    reason = (lead.get("ERA_Reden__c") or "").strip("​ ") or None
    return {
        "external_id": lead["Id"],
        "owner_key": owner or None,
        "owner_email": None if is_queue else (user.get("Email") or None),
        "owner_label": groups.get(owner) if is_queue else user.get("Name"),
        "owner_is_queue": is_queue,
        "lifecycle": lifecycle(lead.get("Status"), reason),
        "status_label": lead.get("Status"),
        "end_reason": reason,
        "market_date": iso_date(lead.get("ERA_Datum_op_de_markt__c")),
        "created_in_source": lead.get("CreatedDate"),
        "ended_on": iso_date(lead.get("ERA_Datum_Verkocht_Be_indigd__c")),
        "source_modified_at": lead.get("LastModifiedDate"),
        "street": lead.get("ERA_Straat__c"),
        "number": lead.get("ERA_Huisnummer__c"),
        "box": lead.get("ERA_Bus__c"),
        "postcode": lead.get("ERA_Postcode__c"),
        "city": lead.get("ERA_Gemeente__c"),
        "lat": lead.get("ERA_Geolocation__Latitude__s"),
        "lon": lead.get("ERA_Geolocation__Longitude__s"),
        "object_type": lead.get("ERA_Object_Type__c"),
        "price_current": lead.get("ERA_Actuele_Vraagprijs__c"),
        "price_initial": lead.get("ERA_Initiele_Vraagprijs__c"),
        "agency_label": lead.get("ERA_Bron_Bemiddelaar__c"),
        "immoweb_url": lead.get("ERA_URL_2__c"),
        "immoweb_id": immoweb_id(lead.get("ERA_URL_2__c")),
        "realo_url": lead.get("ERA_Explorer_URL__c"),
        "realo_property_id": realo_p,
        "realo_listing_id": realo_l,
        "raw": {k: lead.get(k) for k in RAW_FIELDS if lead.get(k) is not None},
    }


def opportunity_to_mandate(opp, obj, users, rt_names):
    """Eén ERAforce-opdracht (Opportunity) + het gekoppelde pand (ERA_Object__c) → opdracht voor de inkoopbonus.
    Datum: ondertekening van de opdracht; anders de start van de opdracht. De aanmaakdatum gebruiken we niet."""
    for field in ("ERA_Datum_Ondertekening_Mandaat__c", "ERA_Start_opdracht__c"):
        if opp.get(field):
            signed, basis = iso_date(opp[field]), field
            break
    else:
        return None
    obj = obj or {}
    return {
        "external_id": opp["Id"], "kind": rt_names.get(opp.get("RecordTypeId")), "stage": opp.get("StageName"),
        "signed_on": signed, "date_basis": basis, "owner_label": (users.get(opp.get("OwnerId")) or {}).get("Name"),
        "street": obj.get("ERA_Straat__c"), "number": obj.get("ERA_Huisnummer__c"), "box": obj.get("ERA_Bus__c"),
        "postcode": obj.get("ERA_Postcode__c"), "city": obj.get("ERA_Gemeente__c"),
        "lat": obj.get("ERA_GEO_Code__Latitude__s"), "lon": obj.get("ERA_GEO_Code__Longitude__s"),
    }


MANDATE_SQL = """
select o."Id", o."OwnerId", o."RecordTypeId", o."StageName", o."ERA_Datum_Ondertekening_Mandaat__c",
       o."ERA_Start_opdracht__c", o."ERA_Object__c",
       b."ERA_Straat__c", b."ERA_Huisnummer__c", b."ERA_Bus__c", b."ERA_Postcode__c", b."ERA_Gemeente__c",
       b."ERA_GEO_Code__Latitude__s", b."ERA_GEO_Code__Longitude__s"
from "Opportunity" o left join "ERA_Object__c" b on b."Id" = o."ERA_Object__c" and b."_verwijderd" = 0
where o."_verwijderd" = 0 and coalesce(o."ERA_Datum_Ondertekening_Mandaat__c", o."ERA_Start_opdracht__c") >= ?
"""


def read_mandates(path, years=3):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    since = (dt.date.today() - dt.timedelta(days=365 * years)).isoformat()
    users = {r["Id"]: dict(r) for r in con.execute('select "Id", "Name" from "User"')}
    rts = {r["Id"]: r["Name"] for r in con.execute('select "Id", "Name" from "RecordType"')}
    rows = [dict(r) for r in con.execute(MANDATE_SQL, (since,))]
    con.close()
    out = [opportunity_to_mandate(r, r, users, rts) for r in rows]
    return [m for m in out if m and m["street"] and m["number"]]


def read_mirror(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    users = {r["Id"]: dict(r) for r in con.execute('select "Id", "Name", "Email" from "User"')}
    groups = {r["Id"]: r["Name"] for r in con.execute('select "Id", "Name" from "Group"')}
    leads = [dict(r) for r in con.execute(
        '''select * from "Lead" where "_verwijderd" = 0 and "LeadSource" = 'Marketpulse' ''')]
    con.close()
    return [lead_to_record(l, users, groups) for l in leads]


# ============================================================== Supabase ==

def password():
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN, "-w"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def connect():
    import psycopg  # in .venv
    pw = password()
    if not pw:
        raise SystemExit("Nog geen importwachtwoord in de sleutelhanger (voer scripts/scout-sleutel-maken.sh uit).")
    return psycopg.connect(host=DB_HOST, port=5432, dbname="postgres", user=f"scout_import.{PROJECT}", password=pw,
                           sslmode="require", connect_timeout=20, autocommit=True)


def call(con, sql, *args):
    from psycopg.types.json import Jsonb
    args = tuple(Jsonb(a) if isinstance(a, (dict, list)) and not (isinstance(a, list) and a and isinstance(a[0], str)) else a
                 for a in args)
    row = con.execute(sql, args).fetchone()
    return row[0] if row else None


# ================================================================= web ==

_ssl = None


def ssl_context():
    """Gecontroleerde https. De python.org-build op macOS heeft geen eigen CA-bundel: gebruik die van macOS."""
    global _ssl
    if _ssl:
        return _ssl
    ctx = ssl.create_default_context()
    if not ctx.get_ca_certs() and sys.platform == "darwin":
        os.makedirs(STATE, exist_ok=True)
        bundle = os.path.join(STATE, "ca.pem")
        pem = subprocess.run(["/usr/bin/security", "find-certificate", "-a", "-p",
                              "/System/Library/Keychains/SystemRootCertificates.keychain"], capture_output=True).stdout
        with open(bundle, "wb") as f:
            f.write(pem)
        ctx = ssl.create_default_context(cafile=bundle)
    _ssl = ctx
    return ctx


class Fetcher:
    """Beleefd ophalen: minstens `gap` seconden tussen aanvragen naar dezelfde site, herpogingen, robots.txt."""

    def __init__(self, gap=3.0):
        self.gap, self.last, self.lock, self.robots = gap, {}, threading.Lock(), {}

    def allowed(self, url):
        host = urllib.parse.urlsplit(url)
        base = f"{host.scheme}://{host.netloc}"
        if base not in self.robots:
            rp = urllib.robotparser.RobotFileParser()
            try:
                body = self.get(base + "/robots.txt", check_robots=False, retries=0)[2]
                rp.parse(body.splitlines())
            except Exception:  # noqa: BLE001 — geen robots.txt: alles toegestaan
                rp.parse([])
            self.robots[base] = rp
        return self.robots[base].can_fetch(USER_AGENT, url)

    def wait(self, host):
        while True:
            with self.lock:
                now = time.monotonic()
                if now - self.last.get(host, 0) >= self.gap:
                    self.last[host] = now
                    return
            time.sleep(0.3)

    def get(self, url, check_robots=True, retries=2, timeout=25):
        """→ (http_status, effective_url, text). Gooit een fout bij netwerkproblemen na de herpogingen."""
        if check_robots and not self.allowed(url):
            raise PermissionError("robots.txt staat deze pagina niet toe")
        host = urllib.parse.urlsplit(url).netloc
        for attempt in range(retries + 1):
            self.wait(host)
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "nl-BE,nl;q=0.9,en;q=0.5",
                                                       "Accept": "text/html,application/xhtml+xml,application/xml"})
            try:
                with urllib.request.urlopen(req, timeout=timeout, context=ssl_context()) as r:
                    return r.status, r.geturl(), r.read(3_000_000).decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                if e.code in (404, 410) or e.code < 500 and e.code != 429:
                    return e.code, e.geturl() or url, e.read(500_000).decode("utf-8", "replace") if e.fp else ""
                if attempt == retries:
                    return e.code, url, ""
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
                if attempt == retries:
                    raise
            time.sleep(4 * (attempt + 1))
        raise RuntimeError("onbereikbaar")


# ============================================================ Immoweb ==

def parse_classified(html):
    i = html.find("window.classified")
    if i < 0:
        return None
    j = html.find("{", i)
    try:
        obj, _ = json.JSONDecoder().raw_decode(html[j:])
        return obj
    except ValueError:
        return None


def looks_blocked(status, html):
    low = (html or "")[:20000].lower()
    return status in (403, 429) or "captcha-delivery" in low or ("captcha" in low and "window.classified" not in low)


def norm(s):
    s = (s or "").lower()
    s = re.sub(r"[àáâä]", "a", s); s = re.sub(r"[èéêë]", "e", s); s = re.sub(r"[ìíîï]", "i", s)
    s = re.sub(r"[òóôö]", "o", s); s = re.sub(r"[ùúûü]", "u", s)
    s = re.sub(r"str\b\.?", "straat", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def same_property(item, location):
    """Hoort de advertentie bij het pand van de prospect? Straat, huisnummer en postcode moeten kloppen."""
    if not location:
        return None
    if location.get("street") and item.get("street"):
        if norm(location["street"]) != norm(item["street"]):
            return False
    if location.get("number") and item.get("number"):
        if norm(str(location["number"])) != norm(item["number"]):
            return False
    if location.get("postalCode") and item.get("postcode") and str(location["postalCode"]) != str(item["postcode"]):
        return False
    return True


def check_immoweb(fetch, item):
    url = item.get("immoweb_url")
    if not url:
        return {"status": "unknown", "reason": "Geen Immoweb-link in de bron", "url": None}
    wanted = immoweb_id(url)
    try:
        code, eff, html = fetch.get(url)
    except PermissionError as e:
        return {"status": "failed", "reason": "Niet toegestaan door robots.txt", "error": str(e), "url": url}
    except Exception as e:  # noqa: BLE001
        return {"status": "failed", "reason": "Immoweb niet bereikbaar (time-out of storing)", "error": type(e).__name__, "url": url}
    if looks_blocked(code, html):
        return {"status": "failed", "reason": "Immoweb blokkeert de controle tijdelijk", "error": f"HTTP {code}", "url": url, "http": code}
    if code in (404, 410) or (wanted and wanted not in eff):
        return {"status": "not_found", "reason": f"Advertentie niet meer gevonden (HTTP {code}{', doorverwezen' if wanted and wanted not in eff else ''})",
                "url": url, "http": code}
    c = parse_classified(html)
    if not c:
        return {"status": "unknown", "reason": "Pagina bevat geen herkenbare advertentiegegevens", "url": url, "http": code}
    if wanted and str(c.get("id")) != wanted:
        return {"status": "unknown", "reason": "Pagina toont een andere advertentie", "url": url, "http": code}
    loc = (c.get("property") or {}).get("location") or {}
    match = same_property(item, loc)
    cust = (c.get("customers") or [{}])[0] or {}
    flags = c.get("flags") or {}
    pub = c.get("publication") or {}
    details = {
        "immoweb_id": c.get("id"), "agency_name": cust.get("name"), "agency_type": cust.get("type"),
        "agency_website": cust.get("website"), "external_reference": c.get("externalReference"),
        "price": ((c.get("transaction") or {}).get("sale") or {}).get("price"),
        "published": pub.get("creationDate"), "modified": pub.get("lastModificationDate"),
        "lat": None if loc.get("approximated") else loc.get("latitude"),
        "lon": None if loc.get("approximated") else loc.get("longitude"),
    }
    if match is False:
        return {"status": "unknown", "reason": "Advertentie hoort bij een ander adres", "url": eff, "http": code, "details": details}
    if flags.get("isSoldOrRented"):
        return {"status": "sold", "reason": "Immoweb: verkocht", "evidence": "flags.isSoldOrRented", "url": eff, "http": code, "details": details}
    if flags.get("isUnderOption"):
        return {"status": "under_option", "reason": "Immoweb: onder optie", "evidence": "flags.isUnderOption", "url": eff, "http": code, "details": details}
    if str((c.get("transaction") or {}).get("type", "")).startswith("FOR_SALE"):
        return {"status": "active", "reason": "Immoweb: te koop", "evidence": "transaction.type=FOR_SALE", "url": eff, "http": code, "details": details}
    return {"status": "unknown", "reason": "Verkoopstatus niet duidelijk", "url": eff, "http": code, "details": details}


# =================================================== makelaarswebsite ==

SOLD = re.compile(r"\b(verkocht|vendu|sold)\b", re.I)
OPTION = re.compile(r"\b(onder optie|in optie|sous option|under option)\b", re.I)
FOR_SALE = re.compile(r"\b(te koop|à vendre|a vendre|for sale)\b", re.I)


def page_text(html):
    html = re.sub(r"(?is)<(script|style|noscript|nav|footer|header)[^>]*>.*?</\1>", " ", html)
    return re.sub(r"\s+", " ", re.sub(r"(?s)<[^>]+>", " ", html))


def agency_status(text, item, reference, title=""):
    """Status van één pand op een makelaarspagina, enkel als de pagina aantoonbaar over dit pand gaat.
    'Verkocht', 'onder optie' en 'te koop' tellen enkel in de titel of vlak bij de referentie of het adres,
    zodat een menu-item als "Verkochte panden" geen vals resultaat geeft."""
    low = text.lower()
    marks = []
    if reference:
        marks += [m.start() for m in re.finditer(re.escape(reference.lower()), low)]
    street = (item.get("street") or "").lower()
    nr = (item.get("number") or "").lower()
    if street and nr:
        marks += [m.start() for m in re.finditer(re.escape(street) + r"\.?\s*,?\s*" + re.escape(nr) + r"\b", low)]
    if not marks:
        return None
    windows = " ".join(text[max(0, i - 400): i + 400] for i in marks[:5])
    scope = f"{title} {windows}"
    if SOLD.search(scope):
        return "sold", "Makelaarswebsite: verkocht"
    if OPTION.search(scope):
        return "under_option", "Makelaarswebsite: onder optie"
    if FOR_SALE.search(scope):
        return "active", "Makelaarswebsite: te koop" + (" (referentie gevonden)" if reference and reference.lower() in low else " (adres gevonden)")
    return "unknown", "Pand gevonden, verkoopstatus niet duidelijk"


def sitemap_urls(fetch, base, cache):
    if base in cache:
        return cache[base]
    urls, todo, seen = [], [], set()
    try:
        robots = fetch.get(base + "/robots.txt", check_robots=False, retries=0)[2]
        todo += re.findall(r"(?im)^sitemap:\s*(\S+)", robots)
    except Exception:  # noqa: BLE001
        pass
    todo = todo or [base + "/sitemap.xml"]
    while todo and len(seen) < 6 and len(urls) < 20000:
        sm = todo.pop(0)
        if sm in seen:
            continue
        seen.add(sm)
        try:
            code, _, xml = fetch.get(sm, retries=0)
        except Exception:  # noqa: BLE001
            continue
        if code != 200:
            continue
        locs = re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", xml)
        if "<sitemapindex" in xml:
            todo += [l for l in locs if re.search(r"(propert|pand|estate|immo|te-koop|for-sale|biens|aanbod|offer)", l, re.I)] or locs[:4]
        else:
            urls += locs
    cache[base] = urls
    return urls


def check_agency(fetch, item, iw, cache):
    det = (iw or {}).get("details") or {}
    label = (item.get("agency_label") or "").lower()
    website = det.get("agency_website") or item.get("agency_website")
    if det.get("agency_type") and det["agency_type"] != "AGENCY" or "particulier" in label or "notaris" in label:
        return {"status": "not_applicable", "reason": "Geen makelaar (particulier of notaris)", "url": None,
                "details": {"agency_website": website}}
    if not website:
        return {"status": "unknown", "reason": "Website van de makelaar onbekend", "url": None}
    if not website.startswith("http"):
        website = "https://" + website
    base = "{0.scheme}://{0.netloc}".format(urllib.parse.urlsplit(website))
    ref = det.get("external_reference")
    try:
        urls = sitemap_urls(fetch, base, cache)
    except Exception as e:  # noqa: BLE001
        return {"status": "failed", "reason": "Makelaarswebsite niet bereikbaar", "error": type(e).__name__, "url": base,
                "details": {"agency_website": base}}
    keys = []
    if ref:
        keys.append(re.sub(r"[^a-z0-9]", "", ref.lower()))
    if item.get("street") and item.get("number"):
        keys.append(re.sub(r"[^a-z0-9]+", "-", norm(item["street"])) + "-" + norm(item["number"]))
    if det.get("immoweb_id"):
        keys.append(str(det["immoweb_id"]))
    cands = []
    for u in urls:
        flat = re.sub(r"[^a-z0-9-]", "", u.lower())
        if any(k and (k in flat or k.replace("-", "") in flat.replace("-", "")) for k in keys):
            cands.append(u)
    if not urls:
        return {"status": "unknown", "reason": "Makelaarswebsite heeft geen bruikbare sitemap; pand niet automatisch te vinden",
                "url": base, "details": {"agency_website": base}}
    for u in cands[:3]:
        try:
            code, eff, html = fetch.get(u)
        except Exception:  # noqa: BLE001
            continue
        if code in (404, 410):
            continue
        if looks_blocked(code, html):
            return {"status": "failed", "reason": "Makelaarswebsite blokkeert de controle", "url": u, "http": code,
                    "details": {"agency_website": base}}
        title = re.sub(r"\s+", " ", (re.search(r"(?is)<title>(.*?)</title>", html) or [None, ""])[1])
        res = agency_status(page_text(html), item, ref, title)
        if res:
            return {"status": res[0], "reason": res[1], "url": eff, "http": code, "evidence": "referentie" if ref else "adres",
                    "details": {"agency_website": base}}
    return {"status": "unknown" if not cands else "not_found",
            "reason": "Pand niet teruggevonden op de makelaarswebsite" if not cands else "Pagina van dit pand niet meer gevonden",
            "url": base, "details": {"agency_website": base}}


# ============================================================ geocoderen ==

def geocode(fetch, item):
    q = f"{item.get('street')} {item.get('number')}, {item.get('postcode') or ''} {item.get('city') or ''}"
    try:
        code, _, body = fetch.get("https://geo.api.vlaanderen.be/geolocation/v4/Location?c=1&q=" + urllib.parse.quote(q),
                                  check_robots=False, retries=1)
        res = (json.loads(body).get("LocationResult") or [None])[0]
    except Exception:  # noqa: BLE001
        return None
    if not res or norm(res.get("Thoroughfarename")) != norm(item.get("street")) \
            or norm(str(res.get("Housenumber") or "")).split(" ")[0] != norm(item.get("number") or ""):
        return None
    return res["Location"]["Lat_WGS84"], res["Location"]["Lon_WGS84"]


# ================================================================ commando's ==

def cmd_import(path):
    if not os.path.exists(path):
        raise SystemExit(f"Mirror niet gevonden ({path}); is de kluis gekoppeld?")
    records = read_mirror(path)
    con = connect()
    team = call(con, "select worker.team_id()")
    n = 0
    for i in range(0, len(records), 1000):
        n += call(con, "select worker.import_records(%s, %s, %s)", team, SOURCE, records[i:i + 1000])["records"]
    res = call(con, "select worker.finish_import(%s, %s, %s)", team, SOURCE, [r["external_id"] for r in records])
    mandates = read_mandates(path)
    m = {"mandates": 0, "awarded": 0}
    for i in range(0, len(mandates), 2000):
        r = call(con, "select worker.import_mandates(%s, %s)", team, mandates[i:i + 2000])
        m["mandates"] += r["mandates"]
        m["awarded"] += r["awarded"]
    log.info("import: %d records, %s niet meer in de bron, %s panden; %d opdrachten, %d inkoopbonussen",
             n, res["gone"], res["properties"], m["mandates"], m["awarded"])
    print(f"Import: {n} records · {res['properties']} unieke panden · {res['gone']} niet meer in de bron · "
          f"{m['mandates']} opdrachten · {m['awarded']} nieuwe inkoopbonussen")


def check_one(fetch, con, run, item, cache):
    iw = check_immoweb(fetch, item)
    ag = check_agency(fetch, item, iw, cache)
    for site, r in (("immoweb", iw), ("agency", ag)):
        call(con, "select worker.save_check(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)", run, item["property_id"], site,
             r.get("url"), r["status"], r.get("reason"), r.get("evidence"), r.get("error"), r.get("http"), r.get("details") or {})
    det = iw.get("details") or {}
    if item.get("geo_quality") != "exact":
        if det.get("lat") and det.get("lon"):
            call(con, "select worker.save_geo(%s, %s, %s, 'immoweb', 'exact')", item["property_id"], det["lat"], det["lon"])
        else:
            g = geocode(fetch, item)
            if g:
                call(con, "select worker.save_geo(%s, %s, %s, 'geopunt', 'exact')", item["property_id"], g[0], g[1])
    return iw["status"], ag["status"]


def cmd_check(maximum):
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, "controle.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Er loopt al een controle op deze Mac.")
        return
    con = connect()
    team = call(con, "select worker.team_id()")
    kind = "daily" if not call(con, "select worker.daily_done(%s)", team) and dt.datetime.now().hour >= 6 else "request"
    claim = call(con, "select worker.claim_checks(%s, %s, %s, %s)", team, kind, maximum if kind == "daily" else 200,
                 os.uname().nodename)
    if not claim["run_id"]:
        print("Niets te controleren." if claim.get("nothing_to_do") else "Er loopt al een controleronde (elders of eerder gestart).")
        return
    items = claim["items"]
    fetch, cache, stats = Fetcher(gap=3.0), {}, {}
    local = threading.local()

    def work(it):
        if not hasattr(local, "con"):
            local.con = connect()  # één verbinding per thread
        try:
            return check_one(fetch, local.con, claim["run_id"], it, cache)
        except Exception as e:  # noqa: BLE001 — één pand mag de ronde niet stoppen
            log.warning("pand %s: %s", it.get("property_id"), type(e).__name__)
            return "failed", "failed"
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            for iw, ag in pool.map(work, items):
                stats[iw] = stats.get(iw, 0) + 1
    finally:
        note = f"{len(items)} panden · Immoweb: " + ", ".join(f"{k} {v}" for k, v in sorted(stats.items()))
        call(con, "select worker.finish_run(%s, %s)", claim["run_id"], note)
    log.info("controle %s: %s", kind, note)
    print(f"Controle ({kind}): {note}")


def cmd_status():
    con = connect()
    team = call(con, "select worker.team_id()")
    print("Team:", team, "· dagelijkse controle vandaag gedaan:", call(con, "select worker.daily_done(%s)", team))


def main():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    logging.basicConfig(filename=LOG, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    pi = sub.add_parser("import")
    pi.add_argument("mirror", nargs="?", default=MIRROR)
    pc = sub.add_parser("controleer")
    pc.add_argument("--max", type=int, default=1500)
    sub.add_parser("status")
    a = ap.parse_args()
    try:
        if a.cmd == "import":
            cmd_import(a.mirror)
        elif a.cmd == "controleer":
            cmd_check(a.max)
        else:
            cmd_status()
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001
        log.error("%s mislukt: %s", a.cmd, type(e).__name__)
        print(f"Mislukt: {type(e).__name__}: {str(e)[:200]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
