"""Tests of the 'Aanbellen' extension (source records, matching, periods, checks, selection, access).

Uses the same Postgres setup as test_database.py: all migrations, a stand-in for Supabase auth,
calls as role authenticated (app) or scout_import (the Mac worker).
"""
import datetime as dt
import glob
import os
import unittest

import psycopg
from psycopg.types.json import Jsonb

from test_database import AUTH_STUB, DbError, ROOT, User, database_url

TODAY = dt.date.today()


def d(days_ago):
    return (TODAY - dt.timedelta(days=days_ago)).isoformat()


def rec(ext, owner, street, number, *, box=None, market=None, realo=None, lifecycle="open", ended=None, typ="Huis",
        reason=None, url=None):
    return {"external_id": ext, "owner_key": owner, "owner_email": {"U1": "sofie@test.be", "U2": "lars@test.be"}.get(owner),
            "owner_label": owner, "owner_is_queue": owner.startswith("Q"), "lifecycle": lifecycle, "status_label": "In Opvolging",
            "end_reason": reason, "market_date": market, "created_in_source": f"{market or d(1)}T10:00:00Z", "ended_on": ended,
            "street": street, "number": number, "box": box, "postcode": "1800", "city": "Vilvoorde", "object_type": typ,
            "price_current": 300000, "agency_label": "Marketpulse / Concurrent Makelaar",
            "immoweb_url": url or f"https://www.immoweb.be/nl/zoekertje/huis/te-koop/vilvoorde/1800/{ext[-6:]}",
            "realo_property_id": realo, "raw": {"Status": "In Opvolging"}}


class AanbellenBase(unittest.TestCase):
    """Gedeelde opbouw: alle migraties, een team, twee collega's en een set bronrecords."""
    @classmethod
    def setUpClass(cls):
        cls.url = database_url()
        with psycopg.connect(cls.url, autocommit=True) as con:
            con.execute("drop schema if exists public cascade; drop schema if exists app cascade; "
                        "drop schema if exists worker cascade; create schema public;")
            con.execute(AUTH_STUB)
            for path in sorted(glob.glob(os.path.join(ROOT, "supabase", "migrations", "*.sql"))):
                with open(path) as f:
                    con.execute(f.read())
        cls.sofie = cls.user("sofie@test.be")
        cls.sofie.call("setup_team", p_team_name="Testteam", p_name="Sofie")
        cls.lars = cls.invite("lars@test.be", "Lars")
        cls.team = cls.worker("select worker.team_id()")
        rows = [
            rec("00Q000000000A1", "U1", "Teststraat", "1", market=d(300), realo="100", ended=d(140), lifecycle="ended_usable",
                reason="Automatically ended"),
            rec("00Q000000000A2", "U1", "Teststraat", "1", market=d(120), realo="100"),          # opnieuw aangeboden
            rec("00Q000000000B1", "U1", "Teststraat", "3", box="bus 1", market=d(200), realo="200", typ="Appartement"),
            rec("00Q000000000B2", "U2", "Teststraat", "3", box="0.2", market=d(200), realo="201", typ="Appartement"),
            rec("00Q000000000B3", "U1", "Teststraat", "3", market=d(150), typ="Appartement"),      # zonder bus
            rec("00Q000000000C1", "U1", "Teststr.", "5", market=d(95)),
            rec("00Q000000000C2", "U2", "teststraat ", "5", market=d(95)),                       # zelfde pand, andere schrijfwijze
            rec("00Q000000000D1", "U1", "Teststraat", "7", market=d(400), lifecycle="ended_excluded", reason="Reeds verkocht"),
            rec("00Q000000000E1", "Q1", "Teststraat", "9", market=d(200)),                        # wachtrij
            rec("00Q000000000F1", "U1", "Teststraat", "11", market=None),                         # geen marktdatum
            rec("00Q000000000G1", "U1", "Teststraat", "13", market=d(90)),                        # precies 90 dagen
        ]
        cls.worker("select worker.import_records(%s, 'eraforce_marketpulse', %s)", cls.team, Jsonb(rows))
        cls.worker("select worker.finish_import(%s, 'eraforce_marketpulse', %s)", cls.team, [r["external_id"] for r in rows])

    @classmethod
    def user(cls, email):
        import uuid
        uid = uuid.uuid4()
        with psycopg.connect(cls.url, autocommit=True) as con:
            con.execute("insert into auth.users (id, email) values (%s, %s)", (uid, email))
        return User(cls.url, uid, email)

    @classmethod
    def invite(cls, email, name):
        code = cls.sofie.call("admin_invite", p_email=email)["code"]
        u = cls.user(email)
        u.call("accept_invite", p_code=code, p_name=name)
        return u

    @classmethod
    def worker(cls, sql, *args):
        with psycopg.connect(cls.url) as con:
            con.execute("set local role scout_import")
            row = con.execute(sql, args).fetchone()
            con.commit()
            return row[0] if row else None

    def sql(self, query, *args):
        with psycopg.connect(self.url, autocommit=True) as con:
            cur = con.execute(query, args)
            return cur.fetchall() if cur.description else []

    def prop(self, ext):
        return self.sql("select property_id from public.source_records where external_id = %s", ext)[0][0]

    def cards(self, user=None, **kw):
        return {c["id"]: c for c in (user or self.sofie).call("scout_overview", **kw)["cards"]}

    def check(self, ext, site, status, hours_ago=0):
        pid = self.prop(ext)
        run = self.sql("insert into public.check_runs (team_id, kind, worker, finished_at) values (%s, 'daily', 'test', now()) returning id", self.team)[0][0]
        self.worker("select worker.save_check(%s, %s, %s, 'https://x', %s, 'test', null, null, 200, '{}'::jsonb)", run, pid, site, status)
        if hours_ago:
            self.sql("update public.listing_checks set checked_at = now() - make_interval(hours => %s) where property_id = %s and site = %s "
                     "and id = (select max(id) from public.listing_checks where property_id = %s and site = %s)", hours_ago, pid, site, pid, site)
        return pid

class AanbellenTest(AanbellenBase):
    # ---- matching & periods

    def test_matching(self):
        self.assertEqual(self.prop("00Q000000000A1"), self.prop("00Q000000000A2"))       # zelfde Realo-pand
        self.assertNotEqual(self.prop("00Q000000000B1"), self.prop("00Q000000000B2"))    # verschillende units
        self.assertEqual(self.prop("00Q000000000C1"), self.prop("00Q000000000C2"))       # schrijfwijze genormaliseerd
        b3 = self.prop("00Q000000000B3")
        self.assertNotIn(b3, (self.prop("00Q000000000B1"), self.prop("00Q000000000B2")))  # niet blind samengevoegd
        kinds = [k for (k,) in self.sql("select kind from public.match_reviews")]
        self.assertIn("apartment_without_box", kinds)
        box = self.sql("select app.norm_box('bus 0.2'), app.norm_box('B1'), app.norm_box(''), app.norm_box('B'), app.norm_street('Kerkstr.'), "
                       "app.norm_street('Brusselsestwg'), app.norm_street('St.-Pietersstraat'), app.norm_street('Straatje')")[0]
        self.assertEqual(box, ("2", "1", "", "b", "kerkstraat", "brusselsesteenweg", "sint pietersstraat", "straatje"))

    def test_periods_and_days(self):
        c = self.cards()[self.prop("00Q000000000A1")]
        self.assertEqual((c["current_start"], c["first_start"]), (d(120), d(300)))
        self.assertEqual((c["days_current"], c["days_first"]), (120, 300))
        self.assertTrue(c["relisted"])
        self.assertTrue(c["relist_certain"])          # vorig record beëindigd vóór de nieuwe marktdatum
        self.assertEqual(c["records"], 2)

    # ---- ownership

    def test_own_properties_only(self):
        mine = self.cards(p_min_days=0)
        lars = self.cards(self.lars, p_min_days=0)
        c = self.prop("00Q000000000C1")
        self.assertIn(c, mine)
        self.assertIn(c, lars)                                           # gedeeld pand blijft voor beiden zichtbaar
        self.assertIn("Lars", mine[c]["shared_with"])
        self.assertNotIn(self.prop("00Q000000000B2"), mine)              # unit van Lars
        self.assertNotIn(self.prop("00Q000000000A1"), lars)
        self.assertNotIn(self.prop("00Q000000000D1"), mine)              # verkocht volgens ERAforce
        self.assertNotIn(self.prop("00Q000000000E1"), mine)              # wachtrij
        self.assertEqual(len(set(mine)), len(mine))                      # elk pand maximaal één keer

    def test_threshold_is_strict(self):
        g = self.prop("00Q000000000G1")
        self.assertNotIn(g, self.cards(p_min_days=90))
        self.assertIn(g, self.cards(p_min_days=89))
        self.assertIn(self.prop("00Q000000000F1"), self.cards(p_min_days=90))   # zonder datum: zichtbaar, geen verzonnen ouderdom
        self.assertIsNone(self.cards()[self.prop("00Q000000000F1")]["days_current"])
        prefs = self.sofie.call("scout_overview", p_min_days=120, p_basis="first")["prefs"]
        self.assertEqual(prefs, {"min_days": 120, "basis": "first"})
        self.assertEqual(self.sofie.call("scout_overview")["prefs"]["min_days"], 120)   # bewaard
        self.sofie.call("scout_overview", p_min_days=90, p_basis="current")

    # ---- check decisions

    def test_decisions(self):
        a = self.check("00Q000000000A2", "immoweb", "active")
        self.check("00Q000000000A2", "agency", "not_found")
        c = self.cards()[a]
        self.assertEqual(c["decision"], "eligible")
        self.assertTrue(c["conflict"])
        cc = self.check("00Q000000000C1", "immoweb", "not_found")
        self.check("00Q000000000C1", "agency", "sold")
        self.assertEqual(self.cards()[cc]["decision"], "not_for_sale")
        b = self.check("00Q000000000B1", "immoweb", "active", hours_ago=72)          # oude geslaagde controle
        self.check("00Q000000000B1", "immoweb", "failed")
        cb = self.cards()[b]
        self.assertEqual(cb["decision"], "needs_check")                             # geen nieuwe bevestiging
        self.assertEqual(cb["immoweb"]["last_success"]["status"], "active")
        self.sofie.call("scout_confirm", p_property=b, p_status="active", p_observed_on=TODAY.isoformat(), p_origin="Gezien ter plaatse")
        self.assertEqual(self.cards()[b]["decision"], "eligible")
        self.assertEqual(self.cards()[self.prop("00Q000000000B3")]["decision"], "needs_check")   # nooit gecontroleerd

    # ---- selection, requests, worker

    def test_selection_and_requests(self):
        a = self.prop("00Q000000000A2")
        self.assertEqual(self.sofie.call("scout_select", p_property=a, p_selected=True)["selected"], 1)
        self.assertEqual(self.lars.fails("scout_select", p_property=a, p_selected=True).hint, "forbidden")
        self.assertTrue(self.cards()[a]["selected"])
        self.assertTrue(self.cards(p_min_days=3000)[a]["selected"])                  # selectie blijft zichtbaar bij andere filter
        self.sofie.call("scout_request_check", p_property=a)
        self.assertTrue(self.cards()[a]["request_pending"])
        claim = self.worker("select worker.claim_checks(%s, 'request', 50, 'test')", self.team)
        self.assertIn(a, [i["property_id"] for i in claim["items"]])
        again = self.worker("select worker.claim_checks(%s, 'request', 50, 'test')", self.team)
        self.assertIsNone(again["run_id"])                                          # geen dubbele taak
        self.worker("select worker.save_check(%s, %s, 'immoweb', 'https://x', 'active', 'ok', null, null, 200, '{}'::jsonb)", claim["run_id"], a)
        self.worker("select worker.finish_run(%s, 'klaar')", claim["run_id"])
        self.assertFalse(self.cards()[a]["request_pending"])
        self.sofie.call("scout_save_route", p_plan={"stops": [a]})
        self.assertEqual(self.sofie.call("scout_route")["plan"]["stops"], [a])
        self.sofie.call("scout_select", p_property=a, p_selected=False)

    def test_partial_daily_run(self):
        self.sql("delete from public.check_runs where kind = 'daily'")
        self.assertFalse(self.worker("select worker.daily_done(%s)", self.team))
        add = "insert into public.check_runs (team_id, kind, worker, finished_at, note) values (%s, 'daily', 'test', now(), %s)"
        self.sql(add, self.team, "gedeeltelijk · 1 panden")
        self.assertFalse(self.worker("select worker.daily_done(%s)", self.team))     # afgekapt: nog niet klaar
        self.sql(add, self.team, "12 panden")
        self.assertTrue(self.worker("select worker.daily_done(%s)", self.team))
        self.sql("delete from public.check_runs where kind = 'daily'")

    def test_agency_website_learned(self):
        a, c = self.prop("00Q000000000A2"), self.prop("00Q000000000C1")
        self.sql("update public.source_records set agency_name = 'Immo Test' where external_id in ('00Q000000000A2', '00Q000000000C1')")
        self.sql("update public.source_records set agency_name = 'IMMO TEST' where external_id = '00Q000000000A1'")  # andere schrijfwijze
        self.assertIsNone(self.cards()[c]["agency_url"])
        self.assertEqual(self.cards()[c]["agency_name"], "Immo Test")
        run = self.sql("insert into public.check_runs (team_id, kind, worker) values (%s, 'request', 'test') returning id", self.team)[0][0]
        details = Jsonb({"agency_type": "AGENCY", "agency_website": "https://www.immotest.be"})
        self.worker("select worker.save_check(%s, %s, 'immoweb', 'https://x', 'active', 'ok', null, null, 200, %s)", run, a, details)
        self.assertEqual(self.cards()[c]["agency_url"], "https://www.immotest.be")       # geleerd via ander pand
        guess = Jsonb({"agency_website": "https://geraden.be", "website_source": "guess"})
        self.worker("select worker.save_check(%s, %s, 'agency', 'https://x', 'unknown', 'x', null, null, 200, %s)", run, a, guess)
        self.assertEqual(self.cards()[c]["agency_url"], "https://www.immotest.be")       # afgeleid overschrijft Immoweb niet
        self.sofie.call("admin_set_agency_site", p_name="IMMO test", p_website="https://immo-test.be")
        self.worker("select worker.save_check(%s, %s, 'immoweb', 'https://x', 'active', 'ok', null, null, 200, %s)", run, a, details)
        self.assertEqual(self.cards()[c]["agency_url"], "https://immo-test.be")          # handmatig wint
        names = {x["name"].lower(): x for x in self.sofie.call("admin_agency_sites")["agencies"]}
        self.assertEqual(names["immo test"]["source"], "manual")
        self.assertEqual(self.lars.fails("admin_agency_sites").hint, "forbidden")
        self.sql("update public.source_records set agency_name = null")
        self.sql("delete from public.agency_sites")
        self.sql("delete from public.listing_checks where run_id = %s", run)
        self.sql("delete from public.check_runs where id = %s", run)

    def test_contacts_on_address(self):
        a, b = self.prop("00Q000000000A2"), self.prop("00Q000000000B1")   # Teststraat 1 ; Teststraat 3 bus 1
        rows = [
            {"external_id": "00QX1", "address_type": "main", "kind": "Verkoper", "name": "Eigenaar Een", "mobile": "0470 11 22 33",
             "street": "Teststr.", "number": "1", "postcode": "1800"},                                  # zelfde adres (afkorting)
            {"external_id": "00QX2", "address_type": "other", "kind": "Koper", "name": "Bewoner Twee", "phone": "02 123 45 67",
             "do_not_call": True, "street": "Teststraat", "number": "3", "box": "2", "postcode": "1800"},  # zelfde gebouw, niet bellen
            {"external_id": "00QX3", "address_type": "main", "kind": "Verkoper", "name": "Derde", "phone": "015 00 00 00",
             "street": "T. Teststraat", "number": "3A", "postcode": "1800"},                            # vermoedelijk (losse sleutel)
            {"external_id": "00QX4", "address_type": "main", "kind": "Verkoper", "name": "Ander Pand", "phone": "1",
             "street": "Teststraat", "number": "4", "postcode": "1800"},                                # ander huisnummer
        ]
        self.assertEqual(self.worker("select worker.import_contacts(%s, %s)", self.team, Jsonb(rows)), 4)
        ca = self.cards()[a]["contacts"]
        self.assertEqual([(x["name"], x["match"]) for x in ca], [("Eigenaar Een", "adres")])
        cb = {x["name"]: x for x in self.cards()[b]["contacts"]}
        self.assertEqual(cb["Bewoner Twee"]["match"], "gebouw")
        self.assertEqual(cb["Bewoner Twee"]["phone"], "02 123 45 67")                              # nummer wel tonen (keuze kantoor)
        self.assertTrue(cb["Bewoner Twee"]["do_not_call"])
        self.assertEqual(cb["Derde"]["match"], "vermoedelijk")
        self.assertNotIn("Ander Pand", cb)
        self.assertNotIn(a, self.cards(self.lars))                                                  # andermans pand: niets
        started = self.worker("select now() + interval '1 second'")
        self.assertEqual(self.worker("select worker.finish_contacts(%s, %s)", self.team, started), 4)  # niet meer in de bron: weg
        self.assertEqual(self.cards()[a]["contacts"], [])

    def test_access(self):
        with psycopg.connect(self.url) as con:
            con.execute("set local role authenticated")
            con.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(self.sofie.id),))
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                con.execute("select worker.team_id()")
        with psycopg.connect(self.url) as con:
            con.execute("set local role scout_import")
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                con.execute("select * from public.source_records")
        self.assertEqual(self.lars.fails("scout_admin_reviews").hint, "forbidden")

    def test_admin_reviews(self):
        r = self.sofie.call("scout_admin_reviews")
        rev = next(x for x in r["reviews"] if x["kind"] == "apartment_without_box")
        self.assertTrue(any(o["owner_key"] == "U1" and o["profile_id"] for o in r["owners"]))
        self.sofie.call("scout_admin_review_decide", p_id=rev["id"], p_decision="separate")
        self.assertFalse(any(x["id"] == rev["id"] for x in self.sofie.call("scout_admin_reviews")["reviews"]))


if __name__ == "__main__":
    unittest.main()


class InkoopbonusTest(AanbellenBase):
    """Extra punten als een bezochte deur een opdracht wordt."""

    def mandate(self, ext, street, number, postcode, signed_days_ago, kind="Verkoop"):
        return self.worker("select worker.import_mandates(%s, %s)", self.team, Jsonb([{
            "external_id": ext, "kind": kind, "stage": "Actief - In Verkoop", "signed_on": d(signed_days_ago),
            "date_basis": "ERA_Datum_Ondertekening_Mandaat__c", "street": street, "number": number, "postcode": postcode, "city": "Vilvoorde"}]))

    def backdated_visit(self, user, address, days_ago, result="door"):
        with psycopg.connect(self.url, autocommit=True) as con:
            prof = f"(select p from public.profiles p where id = '{user.id}')"
            ts = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days_ago)).isoformat()
            return con.execute(f"select app.register_visit({prof}, %s, true)",
                               (Jsonb({"client_id": __import__("uuid").uuid4().hex, "result": result,
                                       "new_prospect": {"address": address}, "visited_at": ts}),)).fetchone()[0]

    def test_bonus_for_visitors_before_signing(self):
        v1 = self.backdated_visit(self.sofie, "Molenstraat 4, 1800 Vilvoorde", 40)
        self.backdated_visit(self.lars, "Molenstraat 4, 1800 Vilvoorde", 20, "conversation")
        self.backdated_visit(self.lars, "molenstr. 4, 1800 Vilvoorde", 15)          # tweede bezoek: geen tweede bonus
        self.backdated_visit(self.sofie, "Molenstraat 6, 1800 Vilvoorde", 40)         # andere deur
        r = self.mandate("006M0000000001", "Molenstraat", "4", "1800", 10)
        self.assertEqual((r["mandates"], r["awarded"]), (1, 2))
        again = self.mandate("006M0000000001", "Molenstraat", "4", "1800", 10)
        self.assertEqual(again["awarded"], 0)                                          # niet dubbel
        # Bezoek na de ondertekening of buiten het venster: geen bonus
        self.backdated_visit(self.sofie, "Veldstraat 1, 1800 Vilvoorde", 5)
        self.assertEqual(self.mandate("006M0000000002", "Veldstraat", "1", "1800", 10)["awarded"], 0)
        self.backdated_visit(self.sofie, "Veldstraat 3, 1800 Vilvoorde", 500)
        self.assertEqual(self.mandate("006M0000000003", "Veldstraat", "3", "1800", 10)["awarded"], 0)
        # Bonus in de week van de ondertekening, niet in die van het bezoek; bezoekpunten blijven 5
        week = self.sofie.call("leaderboard", p_period="week")
        self.assertEqual(self.sql("select app.visit_points(%s)", v1["visit"]["id"])[0][0], 5)
        tx = self.sql("select amount, effective_date from public.point_transactions where kind = 'mandate' and user_id = %s", self.sofie.id)
        self.assertEqual(tx, [(100, (TODAY - dt.timedelta(days=10)))])
        # Een correctie van het bezoek raakt de bonus niet
        fix = self.sofie.call("visit_update", p_id=v1["visit"]["id"], p_data={"result": "conversation", "reason": "Toch gesprek"})
        self.assertEqual(fix["points"], 5)
        self.assertEqual(self.sql("select coalesce(sum(amount),0) from public.point_transactions where visit_id = %s and kind = 'mandate'", v1["visit"]["id"])[0][0], 100)
        # Beheerder kan intrekken met reden
        mid = self.sql("select id from public.mandates where external_id = '006M0000000001'")[0][0]
        self.assertEqual(self.lars.fails("admin_revoke_bonus", p_mandate=mid, p_user=str(self.sofie.id), p_reason="xx").hint, "forbidden")
        self.sofie.call("admin_revoke_bonus", p_mandate=mid, p_user=str(self.sofie.id), p_reason="Opdracht kwam via notaris")
        self.assertEqual(self.sql("select sum(amount) from public.point_transactions where kind = 'mandate' and user_id = %s", self.sofie.id)[0][0], 0)
        self.assertEqual(len(self.lars.call("my_recent_bonuses")["bonuses"]), 1)
        self.assertTrue(week["entries"])

    def test_rules_keep_bonus_settings(self):
        self.sofie.call("admin_rules", p_data={"door": 5, "conversation": 10, "phone": 15, "appointment": 30, "revisit_pct": 50,
                                               "mandate_bonus": 150, "mandate_window_days": 180})
        self.sofie.call("admin_rules", p_data={"door": 5, "conversation": 10, "phone": 15, "appointment": 30, "revisit_pct": 50})
        self.assertEqual(self.sql("select mandate_bonus, mandate_window_days from public.point_rules order by id desc limit 1")[0], (150, 180))
        self.assertIn("10000", self.sofie.fails("admin_rules", p_data={"door": 5, "conversation": 10, "phone": 15, "appointment": 30,
                                                                     "mandate_bonus": 99999}).message)
