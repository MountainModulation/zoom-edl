#!/usr/bin/env python3
"""
fetch_zoom_ips.py

Fetches Zoom's public IP range JSON and writes a Palo Alto-compatible
External Dynamic List (EDL) file — one CIDR per line, no comments.

Zoom JSON source: https://assets.zoom.us/docs/ipranges/Zoom.json

Usage:
    python3 fetch_zoom_ips.py --output docs/zoom-edl.txt
"""

import argparse
import json
import sys
import urllib.request
import datetime

ZOOM_IP_URL = "https://assets.zoom.us/docs/ipranges/Zoom.json"
MIN_EXPECTED_ENTRIES = 20   # sanity check — alert if Zoom's feed shrinks drastically


def fetch_zoom_ips(url: str) -> list[str]:
    req = urllib.request.Request(url, headers={"User-Agent": "zoom-edl/1.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())

    ips: set[str] = set()

    # Primary structure: list of region objects each with an ip_ranges list
    for entry in data.get("ipRanges", []):
        for cidr in entry.get("ip_ranges", []):
            cidr = cidr.strip()
            if cidr:
                ips.add(cidr)

    # Fallback: some versions use top-level ipv4 / ipv6 keys
    for key in ("ipv4", "ipv6"):
        for cidr in data.get(key, []):
            cidr = cidr.strip()
            if cidr:
                ips.add(cidr)

    return sorted(ips)


def write_edl(ips: list[str], output_path: str) -> None:
    """
    Writes a plain list of CIDRs — one per line.
    Palo Alto IP-type EDLs must contain only addresses, no comment lines.
    """
    with open(output_path, "w") as f:
        for ip in ips:
            f.write(ip + "\n")

    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{timestamp}] Wrote {len(ips)} entries to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch Zoom IPs and write EDL.")
    parser.add_argument("--output", required=True, help="Output file path")
    parser.add_argument("--url", default=ZOOM_IP_URL, help="Zoom IP JSON URL")
    args = parser.parse_args()

    try:
        ips = fetch_zoom_ips(args.url)
    except Exception as e:
        print(f"ERROR fetching Zoom IPs: {e}", file=sys.stderr)
        sys.exit(1)

    if len(ips) < MIN_EXPECTED_ENTRIES:
        print(
            f"ERROR: Only {len(ips)} entries found — expected at least "
            f"{MIN_EXPECTED_ENTRIES}. Zoom's feed may have changed format.",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        write_edl(ips, args.output)
    except Exception as e:
        print(f"ERROR writing EDL: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
