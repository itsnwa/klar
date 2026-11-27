#!/usr/bin/env python3
"""Regenerates the popular sites the command palette suggests before they're
in history (Klar/Assets.xcassets/PopularSites.dataset/popular-sites.txt).

Sites are the origins of the Chrome UX Report's global top 50,000 (the sites
people actually browse, not CDNs or trackers), ranked by Tranco, which orders
domains far more finely than CrUX's buckets. Adult sites are left out.
Writes one host per line, without "www.", best first.

Usage: scripts/update_popular_sites.py
"""

import csv
import gzip
import io
import os
import re
import urllib.request
import zipfile

CRUX_URL = "https://raw.githubusercontent.com/zakird/crux-top-lists/main/data/global/current.csv.gz"
TRANCO_URL = "https://tranco-list.eu/top-1m.csv.zip"
ADULT_HOSTS_URL = "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts"
ADULT_DOMAINS_URL = "https://blocklistproject.github.io/Lists/alt-version/porn-nl.txt"

OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Klar", "Assets.xcassets",
                      "PopularSites.dataset", "popular-sites.txt")

# CrUX's buckets are 1k, 5k, 10k, 50k, ...; 50k still has e.g. wired.com.
MAX_CRUX_BUCKET = 50_000
# Tranco ranks are capped at this many times a site's CrUX bucket, so a site
# Tranco barely knows but people visit a lot (finn.no) still ranks well.
CRUX_BUCKET_WEIGHT = 20

ADULT_KEYWORDS = re.compile(
    r"porn|xxx|sex|xvideo|xhamster|hentai|escort|nude|naked|milf|fuck|camgirl|onlyfans|"
    r"redtube|youporn|brazzers|chaturbate|stripchat|livejasmin|bongacams|xnxx|spankbang|"
    r"erotic|fetish|nsfw|adult|lewd|boob|pussy|dick|cock|tits|jav|rule34|hanime"
)
# Subdomains nobody types to get to a site: mobile versions, sign-in pages, ...
SKIPPED_SUBDOMAINS = {
    "m", "mobile", "mob", "web", "amp", "wap", "touch", "w", "ww", "www1", "www2",
    "accounts", "account", "login", "auth", "signin", "sso", "id", "secure", "myaccount",
    "api", "cdn", "static", "consent", "policies", "adssettings", "myactivity",
}


def download(url):
    print(f"Downloading {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "Klar popular sites updater"})
    with urllib.request.urlopen(request) as response:
        return response.read()


def tranco_ranks():
    with zipfile.ZipFile(io.BytesIO(download(TRANCO_URL))) as archive:
        text = archive.read(archive.namelist()[0]).decode()
    return {domain: int(rank) for rank, domain in csv.reader(text.splitlines())}


def adult_domains():
    domains = set()
    for line in download(ADULT_HOSTS_URL).decode(errors="ignore").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "0.0.0.0":
            domains.add(parts[1].lower())
    for line in download(ADULT_DOMAINS_URL).decode(errors="ignore").splitlines():
        line = line.strip().lower()
        if line and not line.startswith("#"):
            domains.add(line)
    return domains


def suffixes(host):
    """The host and each domain it's under, longest first (not the TLD)."""
    labels = host.split(".")
    return [".".join(labels[i:]) for i in range(len(labels) - 1)]


def main():
    ranks = tranco_ranks()
    adult = adult_domains()
    crux = gzip.decompress(download(CRUX_URL)).decode()

    sites = {}
    for row in csv.DictReader(crux.splitlines()):
        bucket = int(row["rank"])
        origin = row["origin"]
        if bucket > MAX_CRUX_BUCKET or not origin.startswith("https://"):
            continue
        host = origin[len("https://"):].lower()
        if not re.fullmatch(r"[a-z0-9.-]+", host):
            continue  # ports, punycode-less IDNs
        if host.startswith("www."):
            host = host[len("www."):]
        if host in sites:
            continue
        if ADULT_KEYWORDS.search(host) or any(domain in adult for domain in suffixes(host)):
            continue

        # The registrable domain is taken to be the longest one Tranco ranks.
        domain = next((d for d in suffixes(host) if d in ranks), host)
        depth = host.count(".") - domain.count(".")
        if depth > 1 or (depth == 1 and host.split(".")[0] in SKIPPED_SUBDOMAINS):
            continue

        # A domain's Tranco rank says nothing about its subdomains, which go
        # by their CrUX bucket alone.
        bucket_rank = bucket * CRUX_BUCKET_WEIGHT
        rank = bucket_rank if depth else min(ranks.get(domain, bucket_rank), bucket_rank)
        sites[host] = (rank, bucket, host)

    hosts = [host for _, _, host in sorted(sites.values())]
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w") as output:
        output.write("\n".join(hosts) + "\n")
    print(f"Wrote {len(hosts)} sites to {os.path.normpath(OUTPUT)}")


if __name__ == "__main__":
    main()
