#!/usr/bin/env python3
"""
deploy/generate-synthetic-data.py

Generates a synthetic genealogical dataset as NDJSON (one JSON record per line),
matching the linkage-engine RecordIngestRequest schema exactly.

Each record represents a 19th-century individual appearing in a historical document
(census, ship manifest, church register, etc.). Records are intentionally designed
to exercise all ConflictRules and chord colours:
  - Multiple records per individual (same person, different years/locations)
  - Age-consistent pairs (same birth year)
  - Age-conflicting pairs (different birth years for same name)
  - Gender-conflicting pairs (M vs F for same name)
  - Geographically plausible travel (comfortable, moderate, tight margins)
  - Physically impossible travel (too far, too fast)

Usage:
    python3 deploy/generate-synthetic-data.py                    # 200 records → data/synthetic-genealogy.ndjson
    python3 deploy/generate-synthetic-data.py --count 1000       # 1000 records → 5 chunk files of 200
    python3 deploy/generate-synthetic-data.py --out /tmp/out.ndjson
    python3 deploy/generate-synthetic-data.py --count 500 --seed 42

Chunking:
    When --count exceeds CHUNK_SIZE (default 200), output is split into multiple
    files named <stem>-chunk-NNN<ext> so that each file is safe for a single
    Lambda invocation.

    CHUNK_SIZE tuning formula:
        CHUNK_SIZE = floor(safe_budget_seconds / p99_latency_per_record)
    where safe_budget_seconds = 600 (half the 15-min Lambda TTL, leaving headroom
    for manifest writes and S3 I/O). Measure p99_latency_per_record from CloudWatch
    Lambda duration logs under real load. Starting default: 200.
"""

import argparse
import json
import os
import random
import sys
from dataclasses import dataclass, asdict
from datetime import date
from pathlib import Path
from typing import Optional

# Maximum records per output file.
# Sized so that even under worst-case Aurora cold-start retries (~7 s/record)
# a single Lambda invocation completes well within the 15-minute TTL.
# Tune using: CHUNK_SIZE = floor(600 / p99_latency_per_record)
CHUNK_SIZE = 200

# ── CLI ───────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="Generate synthetic genealogy NDJSON")
parser.add_argument("--count", type=int, default=200, help="Number of records to generate (default: 200)")
parser.add_argument("--out", type=str, default="data/synthetic-genealogy.ndjson", help="Output file path")
parser.add_argument("--seed", type=int, default=0, help="Random seed for reproducibility (default: 0)")
args = parser.parse_args()

random.seed(args.seed)

# ── Name pools ────────────────────────────────────────────────────────────────
GIVEN_MALE   = ["John", "William", "James", "George", "Charles", "Thomas", "Henry",
                "Edward", "Robert", "Joseph", "Samuel", "Walter", "Frederick", "Albert",
                "Arthur", "Frank", "Harry", "Ernest", "Alfred", "Herbert"]
GIVEN_FEMALE = ["Mary", "Elizabeth", "Sarah", "Margaret", "Ann", "Emma", "Alice",
                "Hannah", "Martha", "Jane", "Ellen", "Catherine", "Susan", "Frances",
                "Clara", "Harriet", "Louisa", "Caroline", "Eliza", "Agnes"]
FAMILY_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Miller", "Davis",
                "Wilson", "Moore", "Taylor", "Anderson", "Thomas", "Jackson", "White",
                "Harris", "Martin", "Thompson", "Garcia", "Martinez", "Robinson",
                "Clark", "Rodriguez", "Lewis", "Lee", "Walker", "Hall", "Allen",
                "Young", "Hernandez", "King", "Wright", "Lopez", "Hill", "Scott",
                "Green", "Adams", "Baker", "Nelson", "Carter", "Mitchell"]

# ── Locations (19th-century US cities with approximate coordinates) ───────────
LOCATIONS = [
    ("Boston",        42.36, -71.06),
    ("New York",      40.71, -74.01),
    ("Philadelphia",  39.95, -75.17),
    ("Baltimore",     39.29, -76.61),
    ("Washington",    38.91, -77.04),
    ("Richmond",      37.54, -77.43),
    ("Charleston",    32.78, -79.93),
    ("Savannah",      32.08, -81.10),
    ("New Orleans",   29.95, -90.07),
    ("Cincinnati",    39.10, -84.51),
    ("Louisville",    38.25, -85.76),
    ("St. Louis",     38.63, -90.20),
    ("Chicago",       41.85, -87.65),
    ("Detroit",       42.33, -83.05),
    ("Pittsburgh",    40.44, -79.99),
    ("Albany",        42.65, -73.75),
    ("Buffalo",       42.89, -78.86),
    ("Cleveland",     41.50, -81.69),
    ("Columbus",      39.96, -82.99),
    ("Indianapolis",  39.77, -86.16),
    ("San Francisco", 37.77, -122.42),
    ("Sacramento",    38.58, -121.49),
    ("Portland",      45.52, -122.68),
    ("Seattle",       47.61, -122.33),
    ("Denver",        39.74, -104.98),
    ("Salt Lake City",40.76, -111.89),
    ("Memphis",       35.15, -90.05),
    ("Nashville",     36.17, -86.78),
    ("Atlanta",       33.75, -84.39),
    ("Mobile",        30.69, -88.04),
]

# ── Sources ───────────────────────────────────────────────────────────────────
SOURCES = [
    "1850 US Federal Census",
    "1860 US Federal Census",
    "1870 US Federal Census",
    "1880 US Federal Census",
    "Ship manifest — Ellis Island",
    "Ship manifest — Port of New York",
    "Ship manifest — Port of Boston",
    "Church baptism register",
    "Church marriage register",
    "Church burial register",
    "County birth record",
    "County death record",
    "County marriage record",
    "Naturalization petition",
    "Passport application",
    "City directory",
    "Newspaper obituary",
    "Military enrollment record",
    "Freedmen's Bureau record",
    "State prison record",
]

# ── Raw content templates ─────────────────────────────────────────────────────
RAW_TEMPLATES = [
    "{given} {family}, age {age}, {occupation}, born {birth_state}, residing {location}",
    "Name: {given} {family}  Year of birth: {birth_year}  Residence: {location}",
    "{family}, {given} — {location} — {year} — age {age}",
    "Arrived {location} aboard {vessel}. Name: {given} {family}. Age: {age}. Occupation: {occupation}.",
    "{given} {family} of {location}, {occupation}, born circa {birth_year}",
]

OCCUPATIONS = ["farmer", "laborer", "merchant", "carpenter", "blacksmith", "clerk",
                "teacher", "physician", "lawyer", "sailor", "weaver", "tailor",
                "shoemaker", "miller", "innkeeper", "seamstress", "domestic servant",
                "washerwoman", "midwife", "schoolmistress"]

VESSELS = ["SS Atlantic", "SS Pacific", "SS Baltic", "SS Arctic", "SS Persia",
           "SS Arabia", "SS Scotia", "SS China", "SS Java", "SS Russia"]

BIRTH_STATES = ["Massachusetts", "New York", "Pennsylvania", "Virginia", "Ohio",
                "Kentucky", "Tennessee", "Georgia", "Ireland", "Germany",
                "England", "Scotland", "France", "Sweden", "Norway"]

# ── Record dataclass ──────────────────────────────────────────────────────────
@dataclass
class Record:
    recordId: str
    givenName: str
    familyName: str
    eventYear: int
    birthYear: Optional[int]
    location: str
    source: str
    rawContent: str
    computeEmbedding: bool = True

    def to_dict(self):
        d = asdict(self)
        # Remove None values so the API uses its defaults
        return {k: v for k, v in d.items() if v is not None}

# ── Helpers ───────────────────────────────────────────────────────────────────
def rand_location():
    return random.choice(LOCATIONS)

def rand_year(lo=1840, hi=1885):
    return random.randint(lo, hi)

def rand_birth_year(event_year, age_lo=18, age_hi=75):
    age = random.randint(age_lo, age_hi)
    return event_year - age

def raw_content(given, family, birth_year, event_year, location):
    age = event_year - birth_year if birth_year else random.randint(20, 60)
    tpl = random.choice(RAW_TEMPLATES)
    return tpl.format(
        given=given, family=family, age=age, birth_year=birth_year or "unknown",
        birth_state=random.choice(BIRTH_STATES), location=location,
        year=event_year, occupation=random.choice(OCCUPATIONS),
        vessel=random.choice(VESSELS),
    )

# ── Generation ────────────────────────────────────────────────────────────────
records = []
counter = 1
_BATCH_DATE = date.today().strftime("%Y%m%d")
_BATCH_SEED = args.seed

def next_id():
    """Return a globally-unique record ID: SYN-YYYYMMDD-sNNN-NNNNN.

    Embedding the batch date and seed ensures two runs (on different days or
    with different seeds) never produce colliding IDs.
    """
    global counter
    rid = f"SYN-{_BATCH_DATE}-s{_BATCH_SEED}-{counter:05d}"
    counter += 1
    return rid

# ── 1. Ordinary individuals (varied names, locations, years) ──────────────────
ordinary_count = max(0, args.count - 80)  # reserve 80 slots for designed pairs
for _ in range(ordinary_count):
    gender = random.choice(["M", "F"])
    given  = random.choice(GIVEN_MALE if gender == "M" else GIVEN_FEMALE)
    family = random.choice(FAMILY_NAMES)
    loc, _, _ = rand_location()
    year   = rand_year()
    birth  = rand_birth_year(year) if random.random() > 0.15 else None
    records.append(Record(
        recordId     = next_id(),
        givenName    = given,
        familyName   = family,
        eventYear    = year,
        birthYear    = birth,
        location     = loc,
        source       = random.choice(SOURCES),
        rawContent   = raw_content(given, family, birth, year, loc),
    ))

# ── 2. Designed pairs — exercise every ConflictRule and chord colour ──────────

def pair(given, family, birth_year, year_a, loc_a, year_b, loc_b,
         source_a=None, source_b=None, given_b=None, birth_b=None):
    """Add two records for the same (or similar) individual."""
    given_b   = given_b or given
    birth_b   = birth_b if birth_b is not None else birth_year
    source_a  = source_a or random.choice(SOURCES)
    source_b  = source_b or random.choice(SOURCES)
    records.append(Record(
        recordId  = next_id(), givenName=given,   familyName=family,
        eventYear = year_a,    birthYear=birth_year, location=loc_a,
        source    = source_a,  rawContent=raw_content(given, family, birth_year, year_a, loc_a),
    ))
    records.append(Record(
        recordId  = next_id(), givenName=given_b, familyName=family,
        eventYear = year_b,    birthYear=birth_b, location=loc_b,
        source    = source_b,  rawContent=raw_content(given_b, family, birth_b, year_b, loc_b),
    ))

# Green — plausible, comfortable margin (Boston → New York, 2 yrs apart)
pair("William", "Harper",  1820, 1850, "Boston",       1852, "New York")
pair("James",   "Fletcher", 1835, 1860, "Philadelphia", 1862, "Baltimore")
pair("Thomas",  "Garrett",  1828, 1855, "Albany",       1857, "Buffalo")
pair("Henry",   "Lawson",   1840, 1865, "Cincinnati",   1867, "Louisville")

# Blue — plausible, moderate margin (Philadelphia → Boston, 1 yr apart)
pair("Charles", "Whitmore", 1825, 1850, "Philadelphia", 1851, "Boston",
     source_a="1850 US Federal Census", source_b="Ship manifest — Port of Boston")
pair("George",  "Ashford",  1830, 1858, "Baltimore",    1859, "New York")
pair("Edward",  "Thornton", 1845, 1870, "Pittsburgh",   1871, "Cleveland")

# Amber — plausible, tight margin (New York → Chicago, same year)
pair("Robert",  "Caldwell", 1832, 1855, "New York",     1855, "Chicago")
pair("Samuel",  "Prescott", 1838, 1862, "Boston",       1862, "Detroit")

# Red — physically impossible (Boston → San Francisco, 30 days apart, pre-railroad)
pair("Joseph",  "Merritt",  1822, 1850, "Boston",       1850, "San Francisco",
     source_a="1850 US Federal Census", source_b="Ship manifest — Port of Boston")
pair("Walter",  "Dunmore",  1840, 1860, "New York",     1860, "San Francisco")

# Cherry — age conflict (same name, very different birth years)
pair("John",    "Morrison", 1820, 1850, "Boston",       1852, "Boston",
     birth_b=1845)   # 25-yr birth year gap
pair("Mary",    "Sullivan", 1810, 1848, "New York",     1850, "New York",
     birth_b=1838)

# Magenta — gender conflict (M name vs F name, same family)
pair("William", "Crawford", 1830, 1855, "Philadelphia", 1857, "Philadelphia",
     given_b="Mary")
pair("James",   "Donovan",  1825, 1852, "Boston",       1854, "Boston",
     given_b="Ellen")

# Mixed — age-consistent multi-city journey (comfortable → moderate → tight)
pair("Frederick","Holloway", 1818, 1848, "New York",    1850, "Cincinnati")
pair("Albert",   "Stanton",  1842, 1868, "Chicago",     1870, "St. Louis")

# Transcription variants (given name spelling differs)
pair("Jonathan", "Pierce",  1833, 1858, "Richmond",    1860, "Washington",
     given_b="Jon")
pair("Catherine","Brennan", 1836, 1862, "New York",    1864, "Boston",
     given_b="Katherine")

# ── Shuffle and write ─────────────────────────────────────────────────────────
random.shuffle(records)

out_path = Path(args.out)
os.makedirs(out_path.parent if str(out_path.parent) != "." else ".", exist_ok=True)

total = len(records)
chunks = [records[i:i + CHUNK_SIZE] for i in range(0, total, CHUNK_SIZE)]

if len(chunks) == 1:
    # Single chunk — write to the requested path directly
    output_paths = [out_path]
    with open(out_path, "w") as f:
        for rec in chunks[0]:
            f.write(json.dumps(rec.to_dict()) + "\n")
else:
    # Multiple chunks — write <stem>-chunk-NNN<suffix> alongside the base path
    stem   = out_path.stem
    suffix = out_path.suffix
    parent = out_path.parent
    output_paths = []
    for idx, chunk in enumerate(chunks, 1):
        chunk_path = parent / f"{stem}-chunk-{idx:03d}{suffix}"
        with open(chunk_path, "w") as f:
            for rec in chunk:
                f.write(json.dumps(rec.to_dict()) + "\n")
        output_paths.append(chunk_path)

print(f"✓ Generated {total} records  ({len(chunks)} chunk(s) of ≤{CHUNK_SIZE} lines each)")
print(f"  Ordinary records:  {ordinary_count}")
print(f"  Designed pairs:    {total - ordinary_count} ({(total - ordinary_count) // 2} pairs)")
for p in output_paths:
    print(f"  → {p}  ({os.path.getsize(p):,} bytes)")
