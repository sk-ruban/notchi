#!/usr/bin/env python3
"""Regenerate the bundled Devin pricing table from Devin's published model rates."""
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "notchi/notchi/Resources/devin-pricing-fallback.json"
SOURCE_URL = "https://docs.devin.ai/desktop/models.md"
REQUIRED_PREFIX = "swe-1"
PER_MILLION = 1_000_000


def fetch_model_rows():
    with urllib.request.urlopen(SOURCE_URL, timeout=30) as response:
        page = response.read().decode("utf-8")
    rows = []
    for candidate in re.findall(r'\{\s*"tier":.*?\}', page, re.S):
        try:
            rows.append(json.loads(candidate))
        except json.JSONDecodeError:
            continue
    return rows


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
    prices = list_prices(fetch_model_rows())
    if not any(uid.startswith(REQUIRED_PREFIX) for uid in prices):
        sys.exit(f"No {REQUIRED_PREFIX}* models found at {SOURCE_URL}; leaving {OUTPUT.name} unchanged.")

    models = pricing_table(prices)
    previous = json.loads(OUTPUT.read_text())["models"] if OUTPUT.exists() else {}
    OUTPUT.write_text(json.dumps({"version": 1, "models": models}, indent=2) + "\n")

    added = sorted(models.keys() - previous.keys())
    removed = sorted(previous.keys() - models.keys())
    changed = sorted(uid for uid in models.keys() & previous.keys() if models[uid] != previous[uid])
    print(f"{len(models)} models written to {OUTPUT.relative_to(ROOT)}")
    for label, uids in (("added", added), ("removed", removed), ("changed", changed)):
        if uids:
            print(f"{label}: {', '.join(uids)}")


if __name__ == "__main__":
    main()
