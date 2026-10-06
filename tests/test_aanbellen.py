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


class AanbellenTest(unittest.TestCase):
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
