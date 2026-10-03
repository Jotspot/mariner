"""ISO 3166-1 alpha-2 country names and flag emoji (no images, works offline)."""

NAMES = dict(line.split(" ", 1) for line in """\
AD Andorra
AE United Arab Emirates
AF Afghanistan
AG Antigua and Barbuda
AL Albania
AM Armenia
AO Angola
AR Argentina
AT Austria
AU Australia
AZ Azerbaijan
BM Bermuda
BA Bosnia and Herzegovina
BB Barbados
BD Bangladesh
BE Belgium
BF Burkina Faso
BG Bulgaria
BH Bahrain
BJ Benin
BN Brunei
BO Bolivia
BR Brazil
BS Bahamas
BT Bhutan
BW Botswana
BY Belarus
BZ Belize
CA Canada
CD DR Congo
CH Switzerland
CI Côte d'Ivoire
CL Chile
CM Cameroon
CN China
CO Colombia
CR Costa Rica
CU Cuba
CY Cyprus
CZ Czechia
DE Germany
DK Denmark
DO Dominican Republic
DZ Algeria
EC Ecuador
EE Estonia
EG Egypt
ES Spain
ET Ethiopia
FI Finland
FJ Fiji
FR France
GB United Kingdom
GE Georgia
GH Ghana
GL Greenland
GR Greece
GT Guatemala
GU Guam
HK Hong Kong
HN Honduras
HR Croatia
HU Hungary
ID Indonesia
IE Ireland
IL Israel
IM Isle of Man
IN India
IQ Iraq
IR Iran
IS Iceland
IT Italy
JE Jersey
JM Jamaica
JO Jordan
JP Japan
KE Kenya
KG Kyrgyzstan
KH Cambodia
KR South Korea
KW Kuwait
KY Cayman Islands
KZ Kazakhstan
LA Laos
LB Lebanon
LI Liechtenstein
LK Sri Lanka
LT Lithuania
LU Luxembourg
LV Latvia
LY Libya
MA Morocco
MC Monaco
MD Moldova
ME Montenegro
MG Madagascar
MK North Macedonia
MM Myanmar
MN Mongolia
MO Macao
MT Malta
MU Mauritius
MV Maldives
MX Mexico
MY Malaysia
MZ Mozambique
NA Namibia
NG Nigeria
NI Nicaragua
NL Netherlands
NO Norway
NP Nepal
NZ New Zealand
OM Oman
PA Panama
PE Peru
PG Papua New Guinea
PH Philippines
PK Pakistan
PL Poland
PR Puerto Rico
PS Palestine
PT Portugal
PY Paraguay
QA Qatar
RO Romania
RS Serbia
RU Russia
RW Rwanda
SA Saudi Arabia
SC Seychelles
SD Sudan
SE Sweden
SG Singapore
SI Slovenia
SK Slovakia
SN Senegal
SO Somalia
SV El Salvador
SY Syria
TH Thailand
TJ Tajikistan
TM Turkmenistan
TN Tunisia
TR Türkiye
TT Trinidad and Tobago
TW Taiwan
TZ Tanzania
UA Ukraine
UG Uganda
US United States
UY Uruguay
UZ Uzbekistan
VE Venezuela
VN Vietnam
YE Yemen
ZA South Africa
ZM Zambia
ZW Zimbabwe""".splitlines())


def flag(code):
    """'LT' -> regional-indicator flag emoji. Empty string for anything else."""
    if not isinstance(code, str) or len(code) != 2 or not code.isalpha():
        return ""
    return "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in code.upper())


def name(code):
    if not isinstance(code, str):
        return ""
    return NAMES.get(code.upper(), code.upper())


# ExpressVPN location slugs, e.g. "usa-new-york-2", "hong-kong-1", "uk-london".
_ALIASES = {"usa": "US", "united-states": "US", "uk": "GB", "united-kingdom": "GB", "turkey": "TR",
            "czech-republic": "CZ", "czech": "CZ", "bosnia-and-herzegovina": "BA", "bosnia": "BA",
            "macau": "MO", "korea": "KR", "south-korea": "KR", "cote-divoire": "CI", "ivory-coast": "CI"}


def _slug(text):
    return "".join(c if c.isalnum() else "-" for c in text.lower()).strip("-").replace("--", "-")


_SLUGS = {**{_slug(n): c for c, n in NAMES.items()}, **_ALIASES}


_ACRONYMS = {"cbd", "uk", "usa", "us", "uae", "dc", "nyc", "la", "sf"}


def _word(p):
    return p.upper() if p in _ACRONYMS else (p if p.isdigit() else p.capitalize())


def region(slug):
    """'usa-new-york-2' -> ('US', 'New York 2'); unknown -> (None, 'Pretty Name')."""
    parts = (slug or "").split("-")
    for n in range(min(4, len(parts)), 0, -1):
        code = _SLUGS.get("-".join(parts[:n]))
        if code:
            rest = " ".join(_word(p) for p in parts[n:])
            return code, rest
    return None, " ".join(p.capitalize() for p in parts)


def region_label(slug):
    if slug == "smart":
        return "Smart location"
    code, rest = region(slug)
    if not code:
        return rest
    return f"{name(code)} · {rest}" if rest else name(code)
