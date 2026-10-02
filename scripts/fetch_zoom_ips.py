#!/usr/bin/env python3
"""
fetch_zoom_ips.py

Fetches Zoom IP ranges from ARIN's public RDAP API using Zoom's ASN (AS30103).
This is authoritative, always current, and has no access restrictions.

Usage:
    python3 fetch_zoom_ips.py --output docs/zoom-edl.txt
"""

import argparse
import json
import sys
import datetime
import subprocess

ZOOM_ASN = "30103"
ARIN_RDAP_URL = f"https://rdap.arin.net/registry/autnum/{ZOOM_ASN}"
MIN_EXPECTED_ENTRIES = 10

def fetch_via_curl(url):
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "30", "--retry", "3",
         "-H", "Accept: application/json",
         url],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)

def fetch_zoom_cidrs():
    """Fetch all IPv4/IPv6 prefixes announced by Zoom's ASN via ARIN RDAP."""
    # Get the ASN record first to find related network links
    asn_data = fetch_via_curl(ARIN_RDAP_URL)

    cidrs = set()

    # ARIN RDAP returns network links in the 'links' array
    # We also query the route search endpoint
    route_url = f"https://rdap.arin.net/registry/arin_originas0_networksbyasn/{ZOOM_ASN}"
    try:
        route_data = fetch_via_curl(route_url)
        for network in route_data.get("arin_originas0_networkSearchResults", []):
            handle = network.get("handle", "")
            cidr = network.get("cidr0_cidrs", [])
            for c in cidr:
                v4 = c.get("v4prefix")
                v6 = c.get("v6prefix")
                length = c.get("length")
                if v4 and length is not None:
                    cidrs.add(f"{v4}/{length}")
                if v6 and length is not None:
                    cidrs.add(f"{v6}/{length}")
            # Also try startAddress/endAddress/cidr
            start = network.get("startAddress")
            cidr_str = network.get("cidr")
            if cidr_str:
                cidrs.add(cidr_str.strip())
    except Exception as e:
        print(f"Warning: ARIN route search failed ({e}), falling back to ASN links", file=sys.stderr)

    # Fallback: try BGPView which is also public and reliable
    if len(cidrs) < MIN_EXPECTED_ENTRIES:
        try:
            bgp_data = fetch_via_curl(f"https://api.bgpview.io/asn/{ZOOM_ASN}/prefixes")
            for prefix in bgp_data.get("data", {}).get("ipv4_prefixes", []):
                p = prefix.get("prefix")
                if p:
                    cidrs.add(p.strip())
            for prefix in bgp_data.get("data", {}).get("ipv6_prefixes", []):
                p = prefix.get("prefix")
                if p:
                    cidrs.add(p.strip())
        except Exception as e:
            print(f"Warning: BGPView fallback failed: {e}", file=sys.stderr)

    return sorted(cidrs)

def write_edl(ips, output_path):
    with open(output_path, "w") as f:
        for ip in ips:
            f.write(ip + "\n")
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{timestamp}] Wrote {len(ips)} entries to {output_path}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        ips = fetch_zoom_cidrs()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    if len(ips) < MIN_EXPECTED_ENTRIES:
        print(f"ERROR: Only {len(ips)} entries found — something went wrong", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(ips)} Zoom IP prefixes")
    write_edl(ips, args.output)

if __name__ == "__main__":
    main()
