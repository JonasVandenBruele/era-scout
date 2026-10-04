"""Tests of the Supabase database (migrations + API functions) against a real Postgres.

Locally an embedded Postgres (pgserver) is started; in GitHub Actions the DATABASE_URL of a
Postgres service container is used. A minimal stand-in for Supabase's `auth` schema and roles is
created first, then all migrations run, then every call is made as role `authenticated` with a
JWT subject, exactly like supabase.rpc() through PostgREST.

    .venv/bin/python -m unittest discover -s tests -v
"""
import datetime as dt
import glob
import os
import threading
import unittest
import uuid

import psycopg
from psycopg.types.json import Jsonb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

AUTH_STUB = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "supabase_stub.sql")).read()

_server = None


def database_url():
    global _server
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    import pgserver  # local development only
    import tempfile
    _server = pgserver.get_server(tempfile.mkdtemp(), cleanup_mode="stop")
    return _server.get_uri()


class DbError(Exception):
    def __init__(self, message, hint):
        super().__init__(message)
        self.message, self.hint = message, hint


class User:
    """A logged-in app user: every call runs as role authenticated with this JWT subject."""

    def __init__(self, url, uid, email):
        self.url, self.id, self.email = url, uid, email

    def call(self, fn, **args):
        params = ", ".join(f"{k} => %({k})s" for k in args)
        values = {k: Jsonb(v) if isinstance(v, (dict, list)) else v for k, v in args.items()}
        with psycopg.connect(self.url, autocommit=False) as con:
            try:
                con.execute("set local role authenticated")
                con.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(self.id),))
                row = con.execute(f"select public.{fn}({params})", values).fetchone()
                con.commit()
                return row[0]
            except psycopg.errors.RaiseException as e:
                con.rollback()
                raise DbError(e.diag.message_primary, e.diag.message_hint) from None

    def fails(self, fn, **args):
        try:
            self.call(fn, **args)
        except DbError as e:
            return e
        raise AssertionError(f"{fn} should have failed")


def visit(user, result="door", **kw):
    return user.call("visit_register", p_data={"client_id": str(uuid.uuid4()), "result": result, **kw})


class DatabaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.url = database_url()
        with psycopg.connect(cls.url, autocommit=True) as con:
            con.execute("drop schema if exists public cascade; drop schema if exists app cascade; create schema public;")
            con.execute(AUTH_STUB)
            for path in sorted(glob.glob(os.path.join(ROOT, "supabase", "migrations", "*.sql"))):
                with open(path) as f:
                    con.execute(f.read())
        cls.admin = cls.new_user("sofie@test.be")
        cls.admin.call("setup_team", p_team_name="Testteam", p_name="Sofie Peeters")
        cls.lars = cls.invite("lars@test.be", "Lars Janssens")
        cls.tom = cls.invite("tom@test.be", "Tom Maes")

    @classmethod
    def tearDownClass(cls):
        if _server:
            _server.cleanup()

    @classmethod
    def new_user(cls, email):
        uid = uuid.uuid4()
        with psycopg.connect(cls.url, autocommit=True) as con:
            con.execute("insert into auth.users (id, email) values (%s, %s)", (uid, email))
        return User(cls.url, uid, email)

    @classmethod
    def invite(cls, email, name, role="member"):
        code = cls.admin.call("admin_invite", p_email=email, p_role=role)["code"]
        u = cls.new_user(email)
        u.call("accept_invite", p_code=code, p_name=name)
        return u

    def sql(self, query, *args):
        with psycopg.connect(self.url, autocommit=True) as con:
            return con.execute(query, args).fetchall()

    # ---- login & access

    def test_setup_only_once_and_invites(self):
        intruder = self.new_user("x@test.be")
        self.assertEqual(intruder.call("auth_status")["user"], None)
        self.assertIn("al ingesteld", intruder.fails("setup_team", p_team_name="Ander", p_name="X").message)
        self.assertEqual(intruder.fails("dashboard").hint, "auth")
        code = self.admin.call("admin_invite", p_email="nieuw@test.be")["code"]
        self.assertEqual(intruder.fails("accept_invite", p_code=code, p_name="X").message,
                         "Deze uitnodiging is voor een ander e-mailadres.")
        new = self.new_user("NIEUW@test.be")
        status = new.call("accept_invite", p_code=code, p_name="Nieuwe Collega")
        self.assertEqual(status["user"]["role"], "member")
        self.assertEqual(self.new_user("nieuw2@test.be").fails("accept_invite", p_code=code, p_name="Y").hint, "not_found")
        self.assertEqual(self.lars.fails("admin_invite", p_email="a@b.be").hint, "forbidden")

    def test_direct_table_access_is_closed(self):
        with psycopg.connect(self.url) as con:
            con.execute("set local role authenticated")
            con.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(self.lars.id),))
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                con.execute("select * from public.visits")
        with psycopg.connect(self.url) as con:
            con.execute("set local role authenticated")
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                con.execute("select app.user_xp(%s)", (self.lars.id,))
        with psycopg.connect(self.url) as con:
            con.execute("set local role anon")
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                con.execute("select public.dashboard()")

    def test_team_isolation(self):
        with psycopg.connect(self.url, autocommit=True) as con:
            tid = con.execute("insert into public.teams (name) values ('Ander team') returning id").fetchone()[0]
            con.execute("select app.default_team_setup(%s)", (tid,))
            other = self.new_user("buiten@test.be")
            con.execute("insert into public.profiles (id, team_id, email, name) values (%s, %s, %s, 'Buiten')",
                        (other.id, tid, other.email))
        r = visit(self.lars, new_prospect={"address": "Isolatiestraat 1, Vilvoorde"})
        pid, vid = r["visit"]["prospect_id"], r["visit"]["id"]
        self.assertEqual(other.fails("prospect_get", p_id=pid).hint, "not_found")
        self.assertEqual(other.call("prospects_list")["prospects"], [])
        self.assertEqual(other.fails("visit_update", p_id=vid, p_data={"result": "phone"}).hint, "not_found")
        self.assertEqual(other.fails("visit_register", p_data={"client_id": str(uuid.uuid4()), "result": "door",
                                                               "prospect_id": pid}).hint, "not_found")
        self.assertEqual([e["name"] for e in other.call("leaderboard")["entries"]], ["Buiten"])

    # ---- points

    def test_door_points_and_double_tap(self):
        data = {"client_id": str(uuid.uuid4()), "result": "door", "flyer": True,
                "new_prospect": {"address": "Teststraat 1, Vilvoorde"}}
        r1 = self.lars.call("visit_register", p_data=data)
        r2 = self.lars.call("visit_register", p_data=data)
        self.assertEqual((r1["points"], r2["points"], r2["already_saved"]), (5, 0, True))
        self.assertEqual(r1["visit"]["id"], r2["visit"]["id"])
        self.assertTrue(r1["visit"]["flyer"])

    def test_parallel_taps_create_one_visit(self):
        data = {"client_id": str(uuid.uuid4()), "result": "door", "new_prospect": {"address": "Teststraat 3, Vilvoorde"}}
        out, errors = [], []

        def tap(d):
            try:
                out.append(self.lars.call("visit_register", p_data=d))
            except Exception as e:  # noqa: BLE001
                errors.append(e)
        others = [{**data, "client_id": str(uuid.uuid4())} for _ in range(3)]
        threads = [threading.Thread(target=tap, args=(d,)) for d in [data, data, data] + others]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(errors, [])
        self.assertEqual(len({r["visit"]["id"] for r in out}), 1)
        self.assertEqual(sum(r["points"] for r in out), 5)

    def test_same_day_merge_and_upgrade(self):
        r1 = visit(self.lars, new_prospect={"address": "Teststraat 5, Vilvoorde"})
        pid = r1["visit"]["prospect_id"]
        r2 = visit(self.lars, "phone", prospect_id=pid, phone={"number": "0470 11 22 33", "source": "neighbour"})
        self.assertTrue(r2["merged"])
        self.assertEqual((r2["points"], r2["visit_points"]), (10, 15))
        r3 = visit(self.lars, "door", prospect_id=pid)
        self.assertEqual((r3["points"], r3["visit"]["result"]), (0, "phone"))

    def test_upgrade_via_edit(self):
        r = visit(self.lars, new_prospect={"address": "Teststraat 7, Vilvoorde"})
        vid = r["visit"]["id"]
        up = self.lars.call("visit_update", p_id=vid, p_data={"result": "phone", "phone": {"source": "direct"}})
        self.assertEqual((up["points"], up["visit"]["phone_status"]), (10, "not_stored"))
        appt = {"date": (dt.date.today() + dt.timedelta(days=3)).isoformat(), "time": "14:00"}
        up2 = self.lars.call("visit_update", p_id=vid, p_data={"result": "appointment", "appointment": appt})
        self.assertEqual((up2["points"], up2["visit_points"]), (15, 30))
        again = self.lars.call("visit_update", p_id=vid, p_data={"result": "appointment", "appointment": appt})
        self.assertEqual(again["points"], 0)

    def test_conversation_and_known_phone(self):
        r = visit(self.lars, "conversation", new_prospect={"address": "Teststraat 9, Vilvoorde"})
        self.assertEqual(r["points"], 10)
        r = visit(self.lars, "phone", new_prospect={"address": "Teststraat 11, Vilvoorde"},
                  phone={"number": "0471 99 88 77", "source": "direct"})
        self.assertEqual(r["points"], 15)
        r2 = visit(self.tom, "phone", prospect_id=r["visit"]["prospect_id"],
                   phone={"number": "+32 471 99 88 77", "source": "direct"})
        self.assertEqual((r2["visit"]["phone_status"], r2["points"]), ("known", 5))  # gesprek, herbezoek 50 %
        self.assertTrue(r2["notes"])

    def test_revisit_gives_reduced_points(self):
        with psycopg.connect(self.url, autocommit=True) as con:
            prof = "(select p from public.profiles p where email = 'tom@test.be')"
            p = con.execute(f"select (app.find_or_create_prospect({prof}, 'Teststraat 13, Vilvoorde', null)).id").fetchone()[0]
            ago = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=2)).isoformat()
            a = con.execute(f"select app.register_visit({prof}, %s, true)",
                            (Jsonb({"client_id": str(uuid.uuid4()), "prospect_id": p, "result": "door", "visited_at": ago}),)).fetchone()[0]
        b = visit(self.tom, prospect_id=p)
        c = visit(self.tom, "phone", prospect_id=p)
        self.assertEqual((a["points"], b["points"], b["reduced"], c["points"]), (5, 3, True, 12))

    def test_validation(self):
        self.assertIn("telefoonnummer", visit_err(self.lars, "phone", new_prospect={"address": "Teststraat 15"},
                                                   phone={"number": "12ab"}))
        self.assertIn("datum", visit_err(self.lars, "appointment", new_prospect={"address": "Teststraat 15"}))
        self.assertEqual(visit_err(self.lars, "sale", new_prospect={"address": "Teststraat 15"}), "Kies een resultaat.")
        self.assertEqual(visit_err(self.lars, new_prospect={"address": ""}), "Adres is verplicht.")
        self.assertEqual(self.lars.fails("visit_register", p_data={"result": "door"}).message, "Ontbrekende registratiesleutel.")
        r = visit(self.lars, new_prospect={"address": "Teststraat 17, Vilvoorde"}, points=999, awarded_tier=4)
        self.assertEqual(r["points"], 5)

    def test_do_not_contact(self):
        r = visit(self.lars, new_prospect={"address": "Teststraat 19, Vilvoorde"}, do_not_contact=True)
        pid = r["visit"]["prospect_id"]
        e = self.tom.fails("visit_register", p_data={"client_id": str(uuid.uuid4()), "result": "door", "prospect_id": pid})
        self.assertEqual(e.hint, "do_not_contact")

    # ---- corrections & rules

    def test_admin_correction_and_void(self):
        r = visit(self.lars, "phone", new_prospect={"address": "Teststraat 21, Vilvoorde"})
        vid = r["visit"]["id"]
        self.assertEqual(self.lars.fails("admin_void", p_id=vid, p_reason="xyz").hint, "forbidden")
        self.assertEqual(self.tom.fails("visit_update", p_id=vid, p_data={"result": "door"}).hint, "forbidden")
        fix = self.admin.call("visit_update", p_id=vid, p_data={"result": "door", "reason": "Geen nummer gekregen"})
        self.assertEqual(fix["points"], -10)
        gone = self.admin.call("admin_void", p_id=vid, p_reason="Dubbel geregistreerd")
        self.assertEqual(gone["points"], -5)
        kinds = [k for (k,) in self.sql("select kind from public.point_transactions where visit_id = %s order by id", vid)]
        self.assertEqual(kinds, ["visit", "correction", "void"])

    def test_rule_change_keeps_history(self):
        old = visit(self.lars, new_prospect={"address": "Teststraat 23, Vilvoorde"})
        self.admin.call("admin_rules", p_data={"door": 8, "conversation": 12, "phone": 20, "appointment": 40, "revisit_pct": 50})
        try:
            new = visit(self.lars, new_prospect={"address": "Teststraat 25, Vilvoorde"})
            self.assertEqual(new["points"], 8)
            up = self.lars.call("visit_update", p_id=old["visit"]["id"], p_data={"result": "phone"})
            self.assertEqual(up["points"], 10)  # oude regels: 15 - 5
            self.assertIn("evenveel", self.admin.fails("admin_rules", p_data={"door": 30, "conversation": 1, "phone": 10,
                                                                               "appointment": 5}).message)
        finally:
            self.admin.call("admin_rules", p_data={"door": 5, "conversation": 10, "phone": 15, "appointment": 30, "revisit_pct": 50})

    # ---- dashboards, ranking, rounds, follow-ups

    def test_dashboard_profile_leaderboard(self):
        visit(self.tom, new_prospect={"address": "Dashstraat 1, Vilvoorde"})
        d = self.tom.call("dashboard")
        self.assertGreaterEqual(d["today"]["doors"], 1)
        self.assertEqual(d["rule"]["conversation"], 10)
        self.assertIn("follow_ups", d)
        p = self.tom.call("my_profile")
        self.assertTrue(any(b["key"] == "first_door" and b["earned"] for b in p["badges"]))
        self.assertEqual(len(p["weeks"]), 6)
        for period in ("week", "month", "competition"):
            lb = self.tom.call("leaderboard", p_period=period, p_sort="doors")
            self.assertEqual(lb["sort"], "doors")
        lb = self.tom.call("leaderboard")
        ranks = [(e["points"], e["rank"]) for e in lb["entries"]]
        for (pa, ra), (pb, rb) in zip(ranks, ranks[1:]):
            self.assertTrue(rb == ra if pa == pb else rb > ra)
        self.assertTrue(lb["me"]["is_me"])

    def test_rounds(self):
        u = self.invite("ronde@test.be", "Ronde Tester")
        rnd = u.call("round_start", p_goal=3)["round"]
        visit(u, new_prospect={"address": "Rondestraat 1, Vilvoorde"})
        visit(u, "phone", new_prospect={"address": "Rondestraat 3, Vilvoorde"})
        s = u.call("round_end", p_id=rnd["id"])["summary"]
        self.assertEqual((s["doors"], s["phones"], s["points"]), (2, 1, 20))
        self.assertEqual(self.lars.fails("round_end", p_id=rnd["id"]).hint, "not_found")

    def test_follow_ups(self):
        r = visit(self.lars, "conversation", new_prospect={"address": "Opvolgstraat 1, Vilvoorde"},
                  follow_up={"signal": "sell", "horizon": "gt5", "note": "Verkoopt over 5 jaar"})
        f = r["follow_up"]
        self.assertEqual((f["signal"], f["status"], r["points"]), ("sell", "open", 10))
        self.assertEqual(f["due_on"], (dt.date.fromisoformat(r["today"]["date"]) + dt.timedelta(days=365)).isoformat())
        ids = lambda u, scope="mine": [x["id"] for x in u.call("follow_ups_list", p_scope=scope)["follow_ups"]]
        self.assertIn(f["id"], ids(self.lars))
        self.assertNotIn(f["id"], ids(self.admin))
        self.assertIn(f["id"], ids(self.admin, "team"))
        self.assertEqual(self.tom.fails("follow_up_update", p_id=f["id"], p_data={"status": "done"}).hint, "forbidden")
        self.assertEqual(self.lars.call("follow_up_update", p_id=f["id"], p_data={"status": "done"})["follow_up"]["status"], "done")
        pid = r["visit"]["prospect_id"]
        self.assertIn("interessant", self.lars.fails("follow_up_create", p_data={"prospect_id": pid, "signal": "loterij"}).message)
        self.assertIn("6 jaar", self.lars.fails("follow_up_create", p_data={"prospect_id": pid, "signal": "sell",
                                                                             "due_on": "2001-01-01"}).message)
        self.assertEqual(visit_err(self.lars, new_prospect={"address": "Opvolgstraat 3, Vilvoorde"}, follow_up={"signal": "x"}),
                         "Kies wat er interessant is.")
        self.assertEqual(self.sql("select count(*) from public.prospects where address like 'Opvolgstraat 3%%'")[0][0], 0)
        f2 = self.lars.call("follow_up_create", p_data={"prospect_id": pid, "signal": "valuation", "horizon": "now"})
        self.lars.call("prospect_update", p_id=pid, p_data={"do_not_contact": True})
        self.assertNotIn(f2["follow_up"]["id"], ids(self.lars))

    # ---- address register

    def test_region_and_location(self):
        reg = self.admin.call("admin_region_add", p_name="Testgem")["municipality"]
        self.assertEqual(self.lars.fails("admin_region_begin", p_id=reg["id"]).hint, "forbidden")
        self.admin.call("admin_region_begin", p_id=reg["id"])
        rows = [
            {"id": 9001, "street_id": 77, "street": "Testlaan", "number": "10", "postcode": "1800", "lat": 50.9, "lon": 4.40, "boxes": 0},
            {"id": 9002, "street_id": 77, "street": "Testlaan", "number": "12", "postcode": "1800", "lat": 50.9, "lon": 4.40014, "boxes": 3},
            {"id": 9003, "street_id": 77, "street": "Testlaan", "number": "11", "postcode": "1800", "lat": 50.90018, "lon": 4.40007, "boxes": 0},
            {"id": 9004, "street_id": 78, "street": "Verweg", "number": "1", "postcode": "1800", "lat": 50.91, "lon": 4.41, "boxes": 0},
            {"id": 9005, "street_id": 79, "street": "Buitenland", "number": "1", "postcode": "1", "lat": 10.0, "lon": 10.0, "boxes": 0},
        ]
        self.assertEqual(self.admin.call("admin_region_rows", p_id=reg["id"], p_rows=rows)["inserted"], 4)
        st = self.admin.call("admin_region_finish", p_id=reg["id"])
        self.assertEqual(st["addresses"], 4)
        near = self.lars.call("addresses_near", p_lat=50.90001, p_lon=4.40012)["addresses"]
        self.assertEqual([a["id"] for a in near][:2], [9002, 9001])
        self.assertNotIn(9004, [a["id"] for a in near])
        self.assertEqual(near[0]["label"], "Testlaan 12, 1800 Testgem")
        hits = self.lars.call("addresses_search", p_q="testlaan 11")["addresses"]
        self.assertEqual(hits[0]["id"], 9003)
        self.assertEqual(self.lars.call("address_next", p_id=9001)["addresses"][0]["number"], "12")
        r = visit(self.lars, new_prospect={"address": "x", "address_ref": 9002})
        self.assertEqual(r["visit"]["address"], "Testlaan 12, 1800 Testgem")
        again = self.lars.call("addresses_near", p_lat=50.90001, p_lon=4.40012)["addresses"][0]
        self.assertEqual(again["prospect_id"], r["visit"]["prospect_id"])
        r2 = visit(self.admin, new_prospect={"address": "Testlaan 11, Testgem"})
        self.assertEqual(self.lars.call("address_get", p_id=9003)["address"]["prospect_id"], r2["visit"]["prospect_id"])
        r3 = visit(self.tom, new_prospect={"address": "x", "address_ref": 9003})
        self.assertEqual(r3["visit"]["prospect_id"], r2["visit"]["prospect_id"])
        self.admin.call("admin_region_remove", p_id=reg["id"])
        self.assertEqual(self.lars.call("addresses_near", p_lat=50.9, p_lon=4.4)["addresses"], [])

    def test_admin_screens(self):
        o = self.admin.call("admin_overview")
        self.assertEqual(o["team"]["name"], "Testteam")
        self.assertTrue(o["members"])
        self.assertIn("visits", self.admin.call("admin_visits"))
        today = dt.date.today()
        c = self.admin.call("admin_competition_create", p_data={"name": "Sprint", "starts_on": today.isoformat(),
                                                                 "ends_on": (today + dt.timedelta(days=7)).isoformat()})
        self.assertIn("loopt al", self.admin.fails("admin_competition_create", p_data={
            "name": "Dubbel", "starts_on": today.isoformat(), "ends_on": today.isoformat()}).message)
        self.assertEqual(self.lars.call("leaderboard", p_period="competition")["competition"]["name"], "Sprint")
        self.admin.call("admin_competition_end", p_id=c["id"])
        self.assertIn("beheerder", self.admin.fails("admin_user_update", p_id=str(self.admin.id), p_data={"role": "member"}).message)
        self.admin.call("admin_team_update", p_data={"revisit_cooldown_days": 14, "timezone": "Europe/Brussels"})
        self.assertEqual(self.admin.fails("admin_team_update", p_data={"timezone": "Mars/Base"}).message, "Onbekende tijdzone.")
        me = self.lars.call("update_me", p_data={"daily_goal": 8, "work_days": "531", "color": "#00b99b"})
        self.assertEqual((me["user"]["daily_goal"], me["user"]["work_days"]), (8, "135"))


def visit_err(user, result="door", **kw):
    try:
        visit(user, result, **kw)
    except DbError as e:
        return e.message
    raise AssertionError("expected an error")


if __name__ == "__main__":
    unittest.main()
