# ERA Scout

*Scouts zoeken prospects.* In de sport speuren scouts naar jonge talenten met potentieel; met deze app
scouten makelaars hun wijk naar de verkopers van morgen.

Mobiele prospectiegame voor deur-aan-deurprospectie: bel aan, tik je resultaat in een paar
seconden, zie meteen je punten, voortgang en positie tegenover je collega's. Het hoogste
resultaat is een **afspraak**; er is geen CRM en er worden geen verkopen bijgehouden.

> Deze repository bevat **geen echte gegevens**. Gegevens staan enkel in Supabase.

## Opbouw (zelfde aanpak als ERA Inkoop Assist)

- **App**: statische web-app (`app/`, gewone JavaScript, geen build-stap), installeerbaar op de
  gsm (PWA), gepubliceerd via **GitHub Pages**.
- **Supabase**: login (e-mail + wachtwoord), database en alle spelregels als databasefuncties
  (`supabase/migrations`). De app kan niets rechtstreeks in de tabellen lezen of schrijven:
  alles gaat via functies die gebruiker, team en rol controleren en de punten zelf berekenen.
- **GitHub Actions** (`.github/workflows/publiceer.yml`): bij elke push naar `main` → tests
  tegen een echte Postgres → databasemigraties naar Supabase → publiceren.
- **Adressen**: Adressenregister van Digitaal Vlaanderen (Geopunt), open data. De beheerder laadt
  per gemeente alle adressen met positie vanuit de app; buiten de regio valt de app terug op de
  Geopunt-geolocatiedienst.

## Eenmalig instellen

### 1. Supabase-project
1. Maak op [supabase.com](https://supabase.com) een **nieuw project** (regio *West EU*). Noteer het
   databasewachtwoord.
2. **Authentication → Sign In / Providers → Email**: zet *Confirm email* **uit** (aangeraden:
   uitnodigingscodes bepalen al wie toegang krijgt, en de gratis e-maildienst van Supabase verstuurt
   maar enkele mails per uur). Laat je het aan, dan werkt de app ook: collega's bevestigen eerst
   hun e-mail en loggen daarna in.
3. **Authentication → URL Configuration**: *Site URL* = het adres van de app
   (`https://jonasvandenbruele.github.io/era-scout/`), en voeg dat ook toe bij *Redirect URLs*.

### 2. GitHub-repository → Settings → Secrets and variables → Actions
| Soort | Naam | Waarde (Supabase → Project Settings) |
|---|---|---|
| Variable | `VITE_SUPABASE_URL` | Data API → Project URL |
| Variable | `VITE_SUPABASE_ANON_KEY` | API Keys → `anon` / publishable key (publiek) |
| Variable | `SUPABASE_PROJECT_ID` | Project ID (bv. `abcdefghijklmnop`) |
| Variable | `SUPABASE_DB_HOST` | Connect → Session pooler → host (bv. `aws-0-eu-west-1.pooler.supabase.com`) |
| **Secret** | `SUPABASE_DB_PASSWORD` | het databasewachtwoord |

Start daarna **Actions → Test en publiceer → Run workflow**. De database wordt ingericht en de
app gepubliceerd op `https://jonasvandenbruele.github.io/era-scout/`.

### 3. Eerste gebruik
1. Open de app → **Eerste keer? Start een nieuw team** → jij wordt beheerder. (Dit kan maar één
   keer; daarna enkel via uitnodiging.)
2. **Profiel → Beheer → Regio & adressen**: laad de gemeenten (± 40 s per gemeente, laat de app
   open): Meise, Wemmel, Grimbergen, Vilvoorde, Machelen, Zaventem, Steenokkerzeel, Kortenberg,
   Kraainem, Wezembeek-Oppem.
3. **Beheer → Collega's**: maak per collega een uitnodigingslink en stuur die door. Elke link is
   14 dagen geldig, werkt één keer en enkel voor het opgegeven e-mailadres.
4. Op de gsm: open de link in Safari/Chrome → *Deel* → *Zet op beginscherm*.

## Spelregels

| Hoogste resultaat van het bezoek | Punten |
|---|---:|
| Aangebeld (eventueel flyer) | 5 |
| Gesprek gehad | 10 |
| Telefoonnummer gekregen | 15 |
| Afspraak vastgelegd | 30 |

- Bedragen zijn het totaal per bezoek. Verbeteren van 5 naar 15 geeft +10.
- Max. één bezoek per adres, per verkoper, per dag; dubbel tikken of offline opnieuw versturen
  levert nooit een tweede bezoek op.
- **Herbezoek** binnen 14 dagen (teambreed): aanbellen of gesprek telt voor 50 %. Een nieuw
  nummer of een nieuwe afspraak krijgt altijd de volle punten. Beide waarden zijn instelbaar.
- Een al bekend nummer of een nog geplande afspraak levert geen nieuwe bonus op.
- Nieuwe puntwaarden gelden enkel voor nieuwe bezoeken. Correcties (eigen bezoek ≤ 7 dagen, of
  beheerder met reden) en geschrapte registraties zijn aparte, zichtbare transacties.
- **Opvolgingen** (verkoop-, koop-, verhuis-, verhuurplannen, schatting): leveren geen punten op,
  wel de badge *Kansenspotter*. "Niet meer contacteren" annuleert open opvolgingen.
- Levels op totale XP; ranking per week, maand en competitie, gelijke posities bij gelijke score.
  Standaard dagdoel: 10 deuren, per persoon instelbaar met werkdagen en verlof (geen streaks).

## Aanbellen (eigen prospecten die lang te koop staan)

Elke prospecteur ziet **enkel zijn eigen prospecten** uit ERAforce met bron *Marketpulse*: panden die meer dan een
zelf gekozen aantal dagen te koop staan (standaard 90, dus vanaf dag 91) en die bij een actuele controle nog te koop
blijken. Hij kiest zelf welke panden hij bezoekt; de app stelt een volgorde voor en opent Waze per stop.

### Bron en koppeling

| Wat | Waar |
|---|---|
| Bron | ERAForce-mirror op de Mac (`mirror.sqlite` in de versleutelde kluis), object **Lead** met `LeadSource = 'Marketpulse'` |
| Doorsturen | `scripts/scout_worker.py import`, automatisch na elke mirror-run (07:00 en 19:00) via `eraforce-mirror/mirror.py` |
| Schrijven in Supabase | rol `scout_import`, enkel via de functies in schema `worker`; wachtwoord in de sleutelhanger (“ERA Scout import (Supabase)”) en als GitHub-geheim `SCOUT_IMPORT_PASSWORD` |
| Controles | `scripts/scout_worker.py controleer`, elke 15 minuten via launchd (`mac/…era-scout-controle.plist`): aangevraagde panden, en één volledige controle per dag vanaf 06:00 |

Gebruikte ERAforce-velden: `ERA_Straat__c`, `ERA_Huisnummer__c`, `ERA_Bus__c`, `ERA_Postcode__c`, `ERA_Gemeente__c`,
`ERA_Geolocation__*`, `ERA_Datum_op_de_markt__c` (start van de aanbieding volgens Marketpulse), `CreatedDate` (enkel als
importdatum, **nooit** als verkoopstart), `ERA_Datum_Verkocht_Be_indigd__c`, `Status`, `ERA_Reden__c`, `OwnerId`
(gebruiker → e-mailadres → ERA Scout-profiel; wachtrijen worden niet gekoppeld), `ERA_URL_2__c` (Immoweb),
`ERA_Explorer_URL__c` (Realo, met een stabiel pand-ID), prijs, type en bron/bemiddelaar. Namen, telefoonnummers en
e-mailadressen van personen worden **niet** doorgestuurd. Let op: `ERA_Aantal_dagen_op_de_markt__c` in ERAforce is de
ouderdom op het moment van de import en wordt niet bijgewerkt; ERA Scout rekent zelf vanaf de marktdatum.

### Dubbels en nieuwe aanbiedingen

Bronrecords worden gekoppeld aan een **fysiek pand**: eerst via het Realo-pand-ID, dan via het genormaliseerde adres
(straat zonder accenten en met afkortingen voluit, huisnummer, bus, postcode). Appartementen zonder bus in een gebouw
met andere units, of een Realo-ID met een ander adres, worden **niet** samengevoegd maar gemarkeerd (Beheer →
Aanbellen: koppelingen). Verkoopperiodes volgen uit de marktdatums (binnen 30 dagen = dezelfde aanbieding). Een nieuwe
periode is *bevestigd* als een eerder record vóór de nieuwe datum beëindigd was, anders *mogelijk opnieuw aangeboden*.

Bruikbare records: open prospects en beëindigde met een reden zoals *Automatically ended* of *Mogelijk uit verkoop*.
Niet bruikbaar: *Reeds verkocht/verhuurd*, *Dubbele prospect*, *No lead*, *Niet gekwalificeerd*, *Vrijblijvende
schatting* en geconverteerde prospects.

### Controles en beslissing

Per pand: **Immoweb** (gestructureerde advertentiegegevens: verkocht, onder optie, te koop; 404 of doorverwijzing =
niet meer gevonden) en de **makelaarswebsite** (website en referentie uit Immoweb, pand zoeken via de sitemap, enkel
een pagina die de referentie of het adres van dit pand bevat telt). Geldt: actief op minstens één bron → geschikt;
op alle toepasselijke bronnen aantoonbaar niet meer actief → niet meer te koop; anders → *controle nodig*. Een
time-out, blokkade of captcha telt nooit als offline; een oudere geslaagde controle blijft zichtbaar maar telt niet
als nieuwe bevestiging (een controle is 36 uur “vers”). Een gebruiker kan handmatig bevestigen (datum + herkomst).
Captcha's worden niet omzeild; de controle identificeert zich eerlijk als `ERAScout-controle/1.0` en volgt robots.txt.
**Realo** toont een captcha en wordt daarom niet automatisch gecontroleerd (enkel als link).

### Volgorde en Waze

Rijtijden en -afstanden over de weg via OSRM (OpenStreetMap, zonder verkeer); volgorde: dichtstbijzijnde eerst,
verbeterd met 2-opt. Panden zonder betrouwbare locatie komen niet in de route. Waze: `https://waze.com/ul?ll=…&navigate=yes`
(officieel formaat; opent de app of de website). Waze kan geen route met meerdere stops ontvangen: navigeer per stop.

### Eenmalig op de Mac

```bash
scripts/scout-sleutel-maken.sh
```

```bash
scripts/mac-installeren.sh
```

## Locatie en privacy

De app vraagt de locatie enkel bij een tik op het vizier (of automatisch bij "Registreer bezoek"
als je eerder toestemming gaf). Eén meting, geen tracking; de positie wordt niet bewaard. GPS werkt
enkel via https (GitHub Pages) of op `localhost`.

## Lokaal testen (zonder Supabase-project)

Vereist Python 3.10+. Eenmalig:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
```

```bash
.venv/bin/python -m unittest discover -s tests -v
```

```bash
.venv/bin/python scripts/lokale_supabase.py
```

Het laatste commando start een lokale nabootsing van Supabase (login + databasefuncties op een
ingebouwde Postgres) en de app op http://localhost:54321. Enkel voor testen.

## Mappen

| Map | Inhoud |
|---|---|
| `app/` | de web-app (schermen, stijl, service worker, iconen, `vendor/supabase.js` 2.117.2) |
| `supabase/migrations/` | schema, spelregels (`app.*`) en API-functies (`public.*`) |
| `tests/` | tests van spelregels, rechten en adresfuncties tegen Postgres |
| `scripts/` | lokale nabootsing van Supabase, `scout_worker.py` (bronkoppeling en controles op de Mac) |
| `mac/` | achtergrondtaak (launchd) voor de controles |
