#!/usr/bin/env python3
"""Regenerate the bundled Devin pricing table from Devin's published model rates."""
import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "notchi/notchi/Resources/devin-pricing-fallback.json"
# The .md export only has the empty table shell; the rows live in the HTML page's compiled MDX.
SOURCE_URL = "https://docs.devin.ai/desktop/models"
COST_DATA = re.compile(r"const modelCostData=(\[.*?\]);", re.S)
# Backtick strings come first so a number-like run inside a string is left alone.
JS_STRING_OR_BARE_DECIMAL = re.compile(r"`([^`]*)`|(?<=[:\[,])(-?)\.(\d)")
REQUIRED_PREFIX = "swe-"
PER_MILLION = 1_000_000
# The table shows promo rates while an offer runs. These are the list prices the page's notes give
# for those models as of 2026-11-26 (input, output, cache read, cache write per 1M tokens), so a
# temporary discount isn't baked into the history. Drop an entry once its promo has ended.
PROMO_LIST_PRICES = [
    (re.compile(r"swe-2-flash-.+"), (0.10, 0.50, 0.01, 0.125)),
    (re.compile(r"swe-2-1(-(low|medium|high|xhigh|max))?"), (2.00, 10.00, 0.20, 0.0)),
    (re.compile(r"swe-2-(low|medium|high|xhigh|max)"), (3.00, 15.00, 0.30, 0.0)),
    # The notes don't give Argon's list cache-write price; its promo one equals the input price.
    (re.compile(r"gemini-4-argon-.+"), (4.00, 20.00, 0.20, 4.00)),
    (re.compile(r"gemini-3-[78]-flash-.+"), (1.50, 7.50, 0.15, 1.50)),
]


def fetch_page():
    with urllib.request.urlopen(SOURCE_URL, timeout=30) as response:
        return response.read().decode("utf-8")


def js_literal_to_json(match):
    if match.group(1) is not None:
        return json.dumps(match.group(1))
    return f"{match.group(2)}0.{match.group(3)}"


def model_rows(page):
    # The array is a JavaScript literal inside an escaped JSON string: \"key\" names,
    # backtick-quoted values and numbers without a leading zero (.15).
    match = COST_DATA.search(page)
    if match is None:
        sys.exit(f"No modelCostData array found at {SOURCE_URL}; leaving {OUTPUT.name} unchanged.")
    literal = JS_STRING_OR_BARE_DECIMAL.sub(js_literal_to_json, match.group(1).replace('\\"', '"'))
    try:
        return json.loads(literal)
    except json.JSONDecodeError as error:
        sys.exit(f"Could not parse modelCostData at {SOURCE_URL} ({error}); leaving {OUTPUT.name} unchanged.")


def list_prices(rows):
    prices = {}
    for row in rows:
        price = (
            row["input_cost_per_million_usd"],
            row["output_cost_per_million_usd"],
            row["cache_read_cost_per_million_usd"],
            row["cache_write_cost_per_million_usd"],
        )
        current = prices.get(row["model_uid"])
        if current is None or sum(price) > sum(current):
            prices[row["model_uid"]] = price
    for uid in prices:
        for pattern, list_price in PROMO_LIST_PRICES:
            if pattern.fullmatch(uid):
                prices[uid] = list_price
                break
    return prices


def per_token(value):
    return round(value / PER_MILLION, 15)


def pricing_table(prices):
    return {
        uid: {
            "inputPerToken": per_token(input_cost),
            "outputPerToken": per_token(output_cost),
            "cacheCreationPerToken": per_token(cache_write),
            "cacheReadPerToken": per_token(cache_read),
        }
        for uid, (input_cost, output_cost, cache_read, cache_write) in sorted(prices.items())
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="print the table and its differences instead of writing it")
    parser.add_argument(
        "--merge",
        action="store_true",
        help="only add models the bundled table lacks, keeping every bundled model and price as is",
    )
    arguments = parser.parse_args()
    dry_run = arguments.dry_run

    prices = list_prices(model_rows(fetch_page()))
    if not any(uid.startswith(REQUIRED_PREFIX) for uid in prices):
        sys.exit(f"No {REQUIRED_PREFIX}* models found at {SOURCE_URL}; leaving {OUTPUT.name} unchanged.")

    models = pricing_table(prices)
    previous = json.loads(OUTPUT.read_text())["models"] if OUTPUT.exists() else {}
    if arguments.merge:
        # Older logs still name retired models, and an existing price may predate a promo.
        models = dict(sorted({**models, **previous}.items()))
    table = json.dumps({"version": 1, "models": models}, indent=2) + "\n"
    if dry_run:
        print(table, end="")
    else:
        OUTPUT.write_text(table)

    added = sorted(models.keys() - previous.keys())
    removed = sorted(previous.keys() - models.keys())
    changed = sorted(uid for uid in models.keys() & previous.keys() if models[uid] != previous[uid])
    verb = "would be written" if dry_run else "written"
    # Goes to stderr in a dry run so stdout stays exactly the file contents.
    summary = sys.stderr if dry_run else sys.stdout
    print(f"{len(models)} models {verb} to {OUTPUT.relative_to(ROOT)}", file=summary)
    for label, uids in (("added", added), ("removed", removed), ("changed", changed)):
        if uids:
            print(f"{label}: {', '.join(uids)}", file=summary)


if __name__ == "__main__":
    main()
