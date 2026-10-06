"""Panden terugvinden op de website van een makelaar.

Werkwijze per website (één keer per dag, gedeeld door alle panden van dat kantoor):
1. Overzichtspagina's zoeken: links "te koop", "aanbod", "kopen", "à vendre" op de startpagina, plus de sitemap.
2. Die overzichten doorlopen (met paginering) en de links naar afzonderlijke panden verzamelen.
3. Per pand uit Scout de kandidaat-pagina's kiezen (referentie, straat, postcode of gemeente in het webadres; bij
   kleine sites gewoon alle panden) en die pagina's lezen. De status telt enkel als de pagina aantoonbaar over dit
   pand gaat (adres of referentie), nooit op basis van een menu-item.

Alles via gewone, publieke pagina's: robots.txt wordt gevolgd, met pauzes per site, geen captcha's of logins.
Pagina's worden een dag lokaal bewaard (~/.era-scout/sites), zodat een kantoor met 40 panden niet 40 keer bezocht wordt.
"""
import hashlib
import json
import os
import re
import threading
import time
import urllib.parse

CACHE_DIR = os.environ.get("SCOUT_SITES_CACHE") or os.path.expanduser("~/.era-scout/sites")
TTL = 20 * 3600
MAX_OVERVIEW = 25          # overzichtspagina's per site
MAX_PAGES_ALL = 200        # sites met hoogstens zoveel panden: alle pandpagina's lezen
MAX_FETCH_PER_ITEM = 8     # anders: hoogstens zoveel kandidaat-pagina's per pand

BUY = re.compile(r"te-?koop|/kopen|aanbod|a-vendre|à-vendre|for-sale|chercher-bien|acheter|/buy|zoeken|panden|woningen|properties|biens|vastgoed", re.I)
NOT_BUY = re.compile(r"verkopen|verhuren|te-?huur|a-louer|for-rent|/rent|location|contact|blog|nieuws|news|schatting|estimat|waarde|"
                     r"vacature|jobs|team|over-ons|about|privacy|cookie|login|mijn-|wp-|feed|\.(?:jpg|png|pdf|css|js)(?:\?|$)", re.I)
DETAIL_HINT = re.compile(r"huis|woning|appartement|villa|grond|bouwgrond|maison|terrain|house|apartment|flat|studio|"
                         r"bien|pand|property|detail|te-koop|a-vendre|for-sale|\d{4,}", re.I)
PAGINATION = re.compile(r"[?&](page|p|pagina|pg|paged|pageindex)=\d+|/page/\d+|/pagina/\d+", re.I)

SOLD = re.compile(r"\b(verkocht|vendu|sold)\b", re.I)
OPTION = re.compile(r"\b(onder optie|in optie|optie genomen|sous option|under option|onder compromis|sous compromis|compromis)\b", re.I)
FOR_SALE = re.compile(r"\b(te koop|à vendre|a vendre|for sale|vraagprijs|prix demande)\b", re.I)


def norm(s):
    s = str(s if s is not None else "").lower()
    for a, b in (("àáâä", "a"), ("èéêë", "e"), ("ìíîï", "i"), ("òóôö", "o"), ("ùúûü", "u")):
        s = re.sub(f"[{a}]", b, s)
    s = re.sub(r"\bstr\b\.?", "straat", s)
    s = re.sub(r"\bstwg\b\.?", "steenweg", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def slug(s):
    return norm(s).replace(" ", "-")


def page_text(html):
    html = re.sub(r"(?is)<(script|style|noscript|svg)\b.*?</\1>", " ", html)
    html = re.sub(r"(?s)<[^>]+>", " ", html)
    html = re.sub(r"&nbsp;|&#160;", " ", html)
    html = re.sub(r"&amp;", "&", html)
    return re.sub(r"\s+", " ", html).strip()


def title_of(html):
    m = re.search(r"(?is)<title>(.*?)</title>", html)
    return re.sub(r"\s+", " ", m.group(1)).strip() if m else ""


def links_of(html, page_url, host):
    out = []
    for href in re.findall(r"""href\s*=\s*["']([^"'#]+)["']""", html):
        href = href.strip().replace("&amp;", "&")
        if href.startswith(("mailto:", "tel:", "javascript:")):
            continue
        u = urllib.parse.urljoin(page_url, href)
        p = urllib.parse.urlsplit(u)
        if p.scheme not in ("http", "https") or p.netloc.replace("www.", "") != host.replace("www.", ""):
            continue
        out.append(urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, p.query, "")))
    return out


class SiteCache:
    """Lokale dagcache per website: lijst met pandpagina's en de gelezen pagina's (tekst, geen afbeeldingen)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.mem = {}
        self.site_locks = {}
        os.makedirs(CACHE_DIR, exist_ok=True)

    def _path(self, host):
        return os.path.join(CACHE_DIR, re.sub(r"[^a-z0-9.-]", "_", host.lower()) + ".json")

    def site_lock(self, host):
        with self.lock:
            return self.site_locks.setdefault(host, threading.Lock())

    def load(self, host):
        with self.lock:
            if host in self.mem:
                return self.mem[host]
        data = {"built": 0, "details": [], "pages": {}}
        try:
            with open(self._path(host)) as f:
                data = json.load(f)
        except (OSError, ValueError):
            pass
        now = time.time()
        data["pages"] = {u: p for u, p in data.get("pages", {}).items() if now - p.get("at", 0) < TTL}
        with self.lock:
            self.mem[host] = data
        return data

    def save(self, host):
        with self.lock:
            data = self.mem.get(host)
            if data is None:
                return
            blob = json.dumps(data)
        tmp = self._path(host) + ".tmp"
        with open(tmp, "w") as f:
            f.write(blob)
        os.replace(tmp, self._path(host))


CACHE = None


def cache():
    global CACHE
    if CACHE is None:
        CACHE = SiteCache()
    return CACHE


def build_index(fetch, base, sitemap_urls):
    """→ lijst met webadressen van afzonderlijke pandpagina's (te koop) op deze site."""
    host = urllib.parse.urlsplit(base).netloc
    seeds, details, seen = [], set(), set()
    try:
        code, eff, html = fetch.get(base + "/")
        if code == 200:
            for u in links_of(html, eff, host):
                if BUY.search(u) and not NOT_BUY.search(u):
                    if looks_detail(u, base):
                        details.add(u)
                    else:
                        seeds.append(u)
    except Exception:  # noqa: BLE001 — startpagina onbereikbaar: alleen de sitemap
        pass
    for u in sitemap_urls:
        if looks_detail(u, base) and not NOT_BUY.search(u):
            details.add(u)
        elif BUY.search(u) and not NOT_BUY.search(u) and len(seeds) < 40:
            seeds.append(u)
    # overzichten "te koop" eerst, dan de rest
    seeds = sorted(dict.fromkeys(seeds), key=lambda u: (not re.search(r"te-?koop|a-vendre|for-sale|kopen|aanbod", u, re.I), len(u)))
    todo, n = list(seeds), 0
    while todo and n < MAX_OVERVIEW:
        u = todo.pop(0)
        if u in seen:
            continue
        seen.add(u)
        try:
            code, eff, html = fetch.get(u, retries=0)
        except Exception:  # noqa: BLE001
            continue
        n += 1
        if code != 200:
            continue
        for l in links_of(html, eff, host):
            if l in seen:
                continue
            if PAGINATION.search(l) and BUY.search(l) and not NOT_BUY.search(l):
                todo.insert(0, l)       # volgende pagina van hetzelfde overzicht eerst
            elif looks_detail(l, base) and not NOT_BUY.search(l):
                details.add(l)
    return dedupe(details)


PROJECT = re.compile(r"/(projecten|projects|projets|nieuwbouw|new-build|neufs?)/", re.I)


def dedupe(urls):
    """Zelfde pand in meerdere talen of met een ander webadres maar hetzelfde nummer: één keer. Projecten achteraan."""
    urls = sorted(set(urls))
    if any("/nl/" in u for u in urls):
        urls = [u for u in urls if not re.search(r"/(fr|en|de)/", u)]
    seen, out = set(), []
    for u in sorted(urls, key=lambda u: ("/nl/" not in u, len(u))):
        m = re.search(r"(\d{5,})/?$", urllib.parse.urlsplit(u).path)
        key = m.group(1) if m else u
        if key in seen:
            continue
        seen.add(key)
        out.append(u)
    return sorted(out, key=lambda u: (bool(PROJECT.search(u)), u))


def looks_detail(u, base):
    path = urllib.parse.urlsplit(u).path.rstrip("/")
    if not path or path.count("/") < 1 or PAGINATION.search(u):
        return False
    last = path.rsplit("/", 1)[-1]
    # een pandpagina heeft een id of een lange omschrijving als laatste deel
    return bool(DETAIL_HINT.search(path)) and (re.search(r"\d{3,}", last) or last.count("-") >= 3)


def listings(fetch, base, sitemap_urls_fn):
    c = cache()
    host = urllib.parse.urlsplit(base).netloc
    with c.site_lock(host):
        data = c.load(host)
        if time.time() - data.get("built", 0) > TTL or not data.get("details"):
            try:
                sm = sitemap_urls_fn()
            except Exception:  # noqa: BLE001
                sm = []
            data["details"] = build_index(fetch, base, sm)
            data["built"] = time.time()
            c.save(host)
        return data


def read_page(fetch, host, url):
    c = cache()
    data = c.load(host)
    p = data["pages"].get(url)
    if p:
        return p
    code, eff, html = fetch.get(url)
    p = {"at": time.time(), "code": code, "url": eff, "title": title_of(html)[:300],
         "text": page_text(html)[:60000] if code == 200 else "", "blocked": code in (401, 403, 429, 503)}
    with c.lock:
        data["pages"][url] = p
    return p


def url_tokens(u):
    return " " + norm(urllib.parse.unquote(urllib.parse.urlsplit(u).path + " " + urllib.parse.urlsplit(u).query)) + " "


def candidates(details, item, reference, extra_ids=()):
    """Kandidaat-pagina's voor dit pand, sterkste eerst. → (lijst, alle_lezen)"""
    street, nr = norm(item.get("street")), norm(item.get("number"))
    pc, city = norm(item.get("postcode")), norm(item.get("city"))
    ids = [norm(x) for x in (reference, *extra_ids) if x]
    strong, medium = [], []
    for u in details:
        t = url_tokens(u)
        flat = t.replace(" ", "")
        if any(i and len(i) >= 4 and i.replace(" ", "") in flat for i in ids):
            strong.append(u)
        elif street and f" {street} " in t and (not nr or f" {nr} " in t or pc in t or city in t):
            strong.append(u)
        elif (pc and f" {pc} " in t) or (city and f" {city} " in t):
            medium.append(u)
    if len(details) <= MAX_PAGES_ALL:
        rest = [u for u in details if u not in strong and u not in medium]
        return strong + medium + rest, True          # kleine site: alles lezen (sterkste kandidaten eerst)
    return strong + medium, False


def street_patterns(raw):
    """Regex voor een straatnaam die afkortingen verdraagt ("Lod. van Veltemstraat" = "Lodewijk van Veltemstraat"),
    plus een korte vorm met enkel het laatste woord als dat specifiek genoeg is (alleen samen met het huisnummer)."""
    words = norm(raw).split()
    if not words:
        return None, None
    parts = [re.escape(w) + r"[a-z]*" for w in words[:-1]] + [re.escape(words[-1])]
    full = r"\b" + r" ".join(parts)
    short = r"\b" + re.escape(words[-1]) if len(words) > 1 and len(words[-1]) >= 8 else None
    return full, short


def match_page(page, item, reference):
    """→ (status, reden, bewijs) als deze pagina aantoonbaar over het pand gaat, anders None."""
    text, title = page.get("text") or "", page.get("title") or ""
    low = norm(text)
    marks, evidence = [], None
    if reference and len(norm(reference)) >= 4:
        r = norm(reference)
        marks += [m.start() for m in re.finditer(r"\b" + re.escape(r) + r"\b", low)]
        evidence = "referentie" if marks else None
    street, nr = norm(item.get("street")), norm(item.get("number"))
    full, short = street_patterns(item.get("street"))
    if street and nr and not marks:
        nrp = re.sub(r"^(\d+)([a-z]+)$", r"\1 ?\2", nr) if re.fullmatch(r"\d+[a-z]+", nr) else re.escape(nr)
        for pat in filter(None, (full, short)):
            marks += [m.start() for m in re.finditer(pat + r" " + nrp + r"\b", low)]
            marks += [m.start() for m in re.finditer(r"\b" + nrp + r" " + pat, low)]
        evidence = "adres" if marks else None
    if not marks and full:
        # Veel makelaars tonen geen huisnummer. Straat + gemeente/postcode, zonder ander huisnummer in die straat.
        hits = list(re.finditer(full + r"\b", low))
        place = norm(item.get("postcode")) in low or norm(item.get("city")) in low
        other_nr = False
        for h in hits:
            m = re.match(r" (\d+[a-z]?)\b", low[h.end(): h.end() + 10])
            if m and m.group(1) != nr:
                other_nr = True
        if hits and place and not other_nr:
            marks, evidence = [h.start() for h in hits], "straat"
    if not marks:
        return None
    window = " ".join(low[max(0, i - 300): i + 300] for i in marks[:5])
    scope = f"{norm(title)} {window}"
    if SOLD.search(scope):
        return "sold", "Makelaarswebsite: verkocht", evidence
    if OPTION.search(scope):
        return "under_option", "Makelaarswebsite: onder optie", evidence
    if FOR_SALE.search(scope) or re.search(r"\b(te koop|a vendre|for sale)\b", norm(page.get("url", ""))):
        return "active", "Makelaarswebsite: te koop", evidence
    return "unknown", "Pand gevonden, verkoopstatus niet duidelijk", evidence


def find_on_site(fetch, base, item, reference, sitemap_urls_fn, extra_ids=()):
    """→ dict met status/reden/url/bewijs, of None als het pand niet gevonden werd (met uitleg in 'reason')."""
    host = urllib.parse.urlsplit(base).netloc
    data = listings(fetch, base, sitemap_urls_fn)
    details = data["details"]
    if not details:
        return {"status": "unknown", "reason": "Geen overzicht van panden gevonden op de makelaarswebsite", "url": base}
    cands, read_all = candidates(details, item, reference, extra_ids)
    limit = len(cands) if read_all else MAX_FETCH_PER_ITEM
    found, blocked = [], False
    for u in cands[:limit]:
        try:
            p = read_page(fetch, host, u)
        except Exception:  # noqa: BLE001
            continue
        if p.get("blocked"):
            blocked = True
            continue
        if p.get("code") in (404, 410):
            continue
        r = match_page(p, item, reference)
        if r:
            found.append((r, p["url"]))
            if r[2] in ("referentie", "adres"):
                break
    cache().save(host)
    if found:
        strong = [f for f in found if f[0][2] in ("referentie", "adres")]
        if not strong and len({f[1] for f in found}) > 1:
            return {"status": "unknown", "reason": "Meerdere panden in dezelfde straat op de makelaarswebsite", "url": found[0][1]}
        (status, reason, evidence), url = (strong or found)[0]
        if evidence == "straat":
            reason += " (straat en gemeente, geen huisnummer op de site)"
        return {"status": status, "reason": reason, "url": url, "evidence": evidence}
    if blocked:
        return {"status": "failed", "reason": "Makelaarswebsite blokkeert de controle", "url": base}
    if read_all:
        return {"status": "not_found", "reason": f"Niet bij de {len(details)} panden op de makelaarswebsite", "url": base}
    return {"status": "unknown", "reason": "Pand niet teruggevonden op de makelaarswebsite (grote site, enkel kandidaten gelezen)",
            "url": base}


# ------------------------------------------------------------ website zoeken ---

LEGAL = {"bv", "bvba", "nv", "srl", "sprl", "sa", "cvba", "vof", "commv"}
GENERIC = {"immo", "immobilien", "vastgoed", "real", "estate", "makelaars", "makelaar", "immobilier", "immobiliere", "group",
           "groep", "kantoor", "agence", "de", "het", "en", "et", "the", "&"}


def domain_guesses(name):
    words = [w for w in norm(name).split() if w not in LEGAL]
    if not words:
        return []
    cores = [words]
    if len(words) > 2:
        cores.append(words[:2])          # "Immolution Zemst Vilvoorde" → immolution
        cores.append(words[:1]) if len(words[0]) >= 6 else None
    out = []
    for ws in cores:
        for joined in ("".join(ws), "-".join(ws)):
            for tld in (".be", ".com"):
                d = joined + tld
                if d not in out and len(joined) >= 4:
                    out.append(d)
    return out[:8]


REAL_ESTATE = re.compile(r"\b(te koop|a vendre|for sale|vastgoed|immobilier|makelaar|vraagprijs|aanbod|biv)\b")


def name_on_page(name, text, title):
    low = norm(title + " " + text[:20000])
    words = [w for w in norm(name).split() if w not in LEGAL]
    specific = [w for w in words if w not in GENERIC and len(w) >= 3] or words
    return bool(specific) and all(re.search(r"\b" + re.escape(w) + r"\b", low) or w in low.replace(" ", "") for w in specific)


def guess_website(fetch, name):
    """Website van een kantoor afleiden uit de naam. Enkel aanvaard als de startpagina de naam van het kantoor draagt."""
    c = cache()
    key = "_websites"
    data = c.load(key)
    hit = data.setdefault("guesses", {}).get(norm(name))
    if hit and time.time() - hit.get("at", 0) < 30 * 86400:
        return hit.get("website")
    found = None
    for d in domain_guesses(name):
        for base in (f"https://www.{d}", f"https://{d}"):
            try:
                code, eff, html = fetch.get(base + "/", retries=0, timeout=12)
            except Exception:  # noqa: BLE001 — domein bestaat niet of is onbereikbaar
                continue
            txt = page_text(html)
            if code == 200 and name_on_page(name, txt, title_of(html)) and REAL_ESTATE.search(norm(txt[:30000])):
                p = urllib.parse.urlsplit(eff)
                found = f"{p.scheme}://{p.netloc}"
                break
            if code == 200:
                break               # bestaat, maar is niet van dit kantoor
        if found:
            break
    with c.lock:
        data["guesses"][norm(name)] = {"at": time.time(), "website": found}
    c.save(key)
    return found
