"""Tests of the Mac worker logic (no network, no database): ERAforce adapter and website status checks."""
import json
import os
import sys
import tempfile
import unittest

os.environ["SCOUT_SITES_CACHE"] = tempfile.mkdtemp()  # nooit de echte dagcache van de Mac gebruiken

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import scout_worker as w  # noqa: E402
import makelaarsites as ms  # noqa: E402

ITEM = {"property_id": 1, "street": "Kerkstraat", "number": "12", "box": None, "postcode": "1800", "city": "Vilvoorde",
        "immoweb_url": "https://www.immoweb.be/nl/zoekertje/huis/te-koop/vilvoorde/1800/12345678", "agency_label": "Marketpulse / Concurrent Makelaar"}


def classified(**over):
    c = {"id": 12345678, "flags": {"isSoldOrRented": False, "isUnderOption": False},
         "transaction": {"type": "FOR_SALE", "sale": {"price": 350000}},
         "publication": {"creationDate": "2026-05-01T10:00:00Z"},
         "customers": [{"type": "AGENCY", "name": "Immo Test", "website": "https://www.immotest.be"}],
         "externalReference": "IT-4711",
         "property": {"location": {"street": "Kerkstraat", "number": "12", "postalCode": "1800", "latitude": 50.9, "longitude": 4.4,
                                   "approximated": False}}}
    for k, v in over.items():
        c[k] = v
    return f"<html><script>window.classified = {json.dumps(c)};\n</script></html>"


class FakeFetch:
    def __init__(self, pages):
        self.pages = pages

    def get(self, url, check_robots=True, retries=2, timeout=25):
        if url not in self.pages:
            return 404, url, ""
        return self.pages[url]


class WorkerTest(unittest.TestCase):
    def test_lifecycle_and_ids(self):
        self.assertEqual(w.lifecycle("In Opvolging", None), "open")
        self.assertEqual(w.lifecycle("Beëindigd", "Automatically ended"), "ended_usable")
        self.assertEqual(w.lifecycle("Beëindigd", "Reeds verkocht"), "ended_excluded")
        self.assertEqual(w.lifecycle("Beëindigd", "Andere makelaar gekozen​​"), "ended_usable")
        self.assertEqual(w.lifecycle("Geconverteerd", None), "converted")
        self.assertEqual(w.realo_ids("https://www.realo.be/en/explorer/123?l=456"), ("123", "456"))
        self.assertEqual(w.immoweb_id(ITEM["immoweb_url"]), "12345678")

    def test_no_personal_data(self):
        lead = {"Id": "00Q1", "OwnerId": "005A", "FirstName": "Jan", "LastName": "Peeters", "Phone": "0470",
                "Email": "jan@x.be", "MobilePhone": "0470", "Status": "In Opvolging", "ERA_Straat__c": "Kerkstraat",
                "ERA_Datum_op_de_markt__c": "2026-05-01", "CreatedDate": "2026-06-01T10:00:00.000Z"}
        r = w.lead_to_record(lead, {"005A": {"Name": "Collega", "Email": "c@eraleustoye.be"}}, {})
        blob = json.dumps(r)
        for secret in ("Jan", "Peeters", "jan@x.be", "0470"):
            self.assertNotIn(secret, blob)
        self.assertEqual((r["market_date"], r["created_in_source"][:10]), ("2026-05-01", "2026-06-01"))  # niet verward
        q = w.lead_to_record({**lead, "OwnerId": "00GQ"}, {}, {"00GQ": "Wachtrij"})
        self.assertTrue(q["owner_is_queue"])
        self.assertIsNone(q["owner_email"])

    def test_other_portals(self):
        z = {**ITEM, "immoweb_url": "https://www.zimmo.be/nl/vilvoorde-1800/te-koop/huis/ABC12/"}
        r = w.check_listing(FakeFetch({}), z)                                     # Zimmo weert bots: niet proberen
        self.assertEqual((r["status"], r["details"]["portal"]), ("unknown", "Zimmo"))
        u = "https://www.immoscoop.be/te-koop/1800-vilvoorde/1165292"
        self.assertEqual(w.check_listing(FakeFetch({}), {**ITEM, "immoweb_url": u})["status"], "not_found")
        page = "<title>Huis te koop</title><body>Kerkstraat 12, 1800 Vilvoorde. Te koop. Vraagprijs 350.000</body>"
        self.assertEqual(w.check_listing(FakeFetch({u: (200, u, page)}), {**ITEM, "immoweb_url": u})["status"], "active")

    def test_website_guess_rules(self):
        self.assertEqual(ms.domain_guesses("Immo Nuvo")[:2], ["immonuvo.be", "immonuvo.com"])
        self.assertIn("kasper-kent.be", ms.domain_guesses("Kasper & Kent"))
        self.assertTrue(ms.name_on_page("Immo Willems BV", "Welkom bij Immo Willems", ""))
        self.assertFalse(ms.name_on_page("Clavis", "Clavis software solutions", "") and
                         ms.REAL_ESTATE.search(ms.norm("Clavis software solutions")))

    def test_site_crawl(self):
        base = "https://www.kantoortest.be"           # eigen site: de dagcache wordt gedeeld tussen tests
        home = f'<a href="/nl/te-koop">Te koop</a><a href="/nl/verkopen">Verkopen</a>'
        over = '<a href="/nl/huis-te-koop-in-vilvoorde/7881762">1</a><a href="/nl/te-koop?page=2">2</a>'
        over2 = '<a href="/nl/appartement-te-koop-in-zaventem/7881999">3</a>'
        det = "<title>Huis te koop in Vilvoorde</title>Kerkstraat 12 1800 Vilvoorde Onder optie"
        fetch = FakeFetch({base + "/": (200, base + "/", home), base + "/nl/te-koop": (200, base + "/nl/te-koop", over),
                           base + "/nl/te-koop?page=2": (200, base + "/nl/te-koop?page=2", over2),
                           base + "/nl/huis-te-koop-in-vilvoorde/7881762": (200, base + "/nl/huis-te-koop-in-vilvoorde/7881762", det)})
        r = ms.find_on_site(fetch, base, ITEM, None, lambda: [])
        self.assertEqual((r["status"], r["evidence"]), ("under_option", "adres"))
        other = ms.find_on_site(fetch, base, {**ITEM, "street": "Molenstraat", "number": "4"}, None, lambda: [])
        self.assertEqual(other["status"], "not_found")                             # kleine site volledig gelezen

    def test_street_abbreviations(self):
        item = {**ITEM, "street": "Lod. van Veltemstraat", "number": "51A", "postcode": "3020", "city": "Herent"}
        page = {"title": "Kangoeroewoning", "text": "Huis Lodewijk van Veltemstraat 51/A/B, 3020 Veltem-Beisem. Te koop", "url": "x"}
        self.assertEqual(ms.match_page(page, item, None)[::2], ("active", "adres"))
        other = {**page, "text": "Huis Lodewijk van Veltemstraat 7, 3020 Veltem-Beisem. Te koop"}
        self.assertIsNone(ms.match_page(other, item, None))                       # ander huisnummer: geen match

    def test_agency_name(self):
        base = {"ERA_Bron_Bemiddelaar__c": "Marketpulse / Concurrent Makelaar", "FirstName": None,
                "LastName": "Kerkstraat 12, 1800 Vilvoorde, Immo Nuvo"}
        self.assertEqual(w.agency_name(base), "Immo Nuvo")
        self.assertEqual(w.agency_name({**base, "ERA_Bron_Bemiddelaar__c": "Marketpulse / Concurrent Makelaar (Dewaele)"}), "Dewaele")
        self.assertIsNone(w.agency_name({**base, "FirstName": "Jan", "LastName": "Peeters"}))       # persoon: nooit
        self.assertIsNone(w.agency_name({**base, "LastName": "Peeters"}))                           # geen adresvorm
        self.assertIsNone(w.agency_name({**base, "ERA_Bron_Bemiddelaar__c": "Marketpulse / Particulier"}))
        self.assertEqual(w.lead_to_record({"Id": "00Q1", **base}, {}, {})["agency_name"], "Immo Nuvo")

    def test_opportunity_mapping(self):
        opp = {"Id": "006A", "OwnerId": "005A", "RecordTypeId": "012V", "StageName": "Actief - In Verkoop",
               "ERA_Datum_Ondertekening_Mandaat__c": "2026-09-01", "ERA_Start_opdracht__c": "2026-09-03", "CreatedDate": "2026-08-01T10:00:00Z",
               "ERA_Straat__c": "Molenstraat", "ERA_Huisnummer__c": "4", "ERA_Postcode__c": "1800", "ERA_Gemeente__c": "Vilvoorde"}
        m = w.opportunity_to_mandate(opp, opp, {"005A": {"Name": "Collega"}}, {"012V": "Verkoop"})
        self.assertEqual((m["signed_on"], m["date_basis"], m["kind"]), ("2026-09-01", "ERA_Datum_Ondertekening_Mandaat__c", "Verkoop"))
        no_sign = {**opp, "ERA_Datum_Ondertekening_Mandaat__c": None}
        self.assertEqual(w.opportunity_to_mandate(no_sign, no_sign, {}, {})["date_basis"], "ERA_Start_opdracht__c")
        none = {**no_sign, "ERA_Start_opdracht__c": None}
        self.assertIsNone(w.opportunity_to_mandate(none, none, {}, {}))   # aanmaakdatum telt niet als inkoopdatum

    def test_immoweb_statuses(self):
        u = ITEM["immoweb_url"]
        f = lambda html, code=200, eff=u: FakeFetch({u: (code, eff, html)})
        self.assertEqual(w.check_immoweb(f(classified()), ITEM)["status"], "active")
        self.assertEqual(w.check_immoweb(f(classified(flags={"isSoldOrRented": True})), ITEM)["status"], "sold")
        self.assertEqual(w.check_immoweb(f(classified(flags={"isUnderOption": True})), ITEM)["status"], "under_option")
        self.assertEqual(w.check_immoweb(f("", 404), ITEM)["status"], "not_found")
        # 200 maar doorverwezen naar de startpagina: niet meer gevonden (geen bewijs van 'te koop')
        self.assertEqual(w.check_immoweb(f("<html>home</html>", 200, "https://www.immoweb.be/nl"), ITEM)["status"], "not_found")
        blocked = w.check_immoweb(f("<html>captcha-delivery</html>", 403), ITEM)
        self.assertEqual(blocked["status"], "failed")                               # blokkade ≠ offline
        other = classified(property={"location": {"street": "Andere straat", "number": "3", "postalCode": "1800"}})
        self.assertEqual(w.check_immoweb(f(other), ITEM)["status"], "unknown")      # andere woning ≠ match

    def test_immoweb_details(self):
        u = ITEM["immoweb_url"]
        r = w.check_immoweb(FakeFetch({u: (200, u, classified())}), ITEM)
        self.assertEqual(r["details"]["agency_website"], "https://www.immotest.be")
        self.assertEqual(r["details"]["external_reference"], "IT-4711")
        self.assertEqual(r["details"]["lat"], 50.9)

    def test_agency_page_status(self):
        nav = "Home Te koop Verkochte panden Contact " * 3
        body = lambda s: f"{nav} {'x ' * 600} Woning Kerkstraat 12, 1800 Vilvoorde. {s} Ref IT-4711 {'y ' * 600}"
        self.assertEqual(w.agency_status(body("Te koop: ruime woning"), ITEM, "IT-4711")[0], "active")
        self.assertEqual(w.agency_status(body("VERKOCHT"), ITEM, "IT-4711")[0], "sold")
        self.assertEqual(w.agency_status(body("Onder optie"), ITEM, "IT-4711")[0], "under_option")
        # Menu-item "Verkochte panden" ver weg van het pand: geen vals 'verkocht'
        self.assertEqual(w.agency_status(body("Beschikbaar"), ITEM, "IT-4711")[0], "unknown")
        # Andere woning op de pagina: geen match
        self.assertIsNone(w.agency_status("Te koop Molenstraat 4 Vilvoorde", ITEM, "XX-1"))

    def test_agency_lookup_via_sitemap(self):
        site = "https://www.immotest.be"
        page = f"<html><title>Te koop - Kerkstraat 12</title><body>Woning Kerkstraat 12 Vilvoorde Ref IT-4711 Te koop</body></html>"
        fetch = FakeFetch({
            site + "/robots.txt": (200, site + "/robots.txt", f"User-agent: *\nSitemap: {site}/sitemap.xml"),
            site + "/sitemap.xml": (200, site + "/sitemap.xml", f"<urlset><url><loc>{site}/nl/te-koop/kerkstraat-12-it-4711</loc></url>"
                                                               f"<url><loc>{site}/nl/te-koop/molenstraat-4</loc></url></urlset>"),
            site + "/nl/te-koop/kerkstraat-12-it-4711": (200, site + "/nl/te-koop/kerkstraat-12-it-4711", page),
        })
        iw = {"details": {"agency_type": "AGENCY", "agency_website": site, "external_reference": "IT-4711"}}
        r = w.check_agency(fetch, ITEM, iw, {})
        self.assertEqual((r["status"], r["url"]), ("active", site + "/nl/te-koop/kerkstraat-12-it-4711"))
        private = w.check_agency(fetch, {**ITEM, "agency_label": "Marketpulse / Particulier"}, {"details": {}}, {})
        self.assertEqual(private["status"], "not_applicable")
        none = w.check_agency(FakeFetch({}), ITEM, {"details": {"agency_type": "AGENCY"}}, {})
        self.assertEqual(none["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
