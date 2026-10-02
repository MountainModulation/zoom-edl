#!/usr/bin/env python3
import argparse
import json
import sys
import datetime
import subprocess

ZOOM_IP_URL = "https://assets.zoom.us/docs/ipranges/Zoom.json"
MIN_EXPECTED_ENTRIES = 20

def fetch_zoom_ips(url):
    result = subprocess.run(
        [
            "curl", "-fsSL", "--max-time", "30", "--retry", "3", "--retry-delay", "5",
            "-H", "Accept: application/json, text/plain, */*",
            "-H", "Accept-Language: en-US,en;q=0.9",
            "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            url,
        ],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(result.stdout)
    ips = set()
    for entry in data.get("ipRanges", []):
        for cidr in entry.get("ip_ranges", []):
            cidr = cidr.strip()
            if cidr:
                ips.add(cidr)
    for key in ("ipv4", "ipv6"):
        for cidr in data.get(key, []):
            cidr = cidr.strip()
            if cidr:
                ips.add(cidr)
    return sorted(ips)

def write_edl(ips, output_path):
    with open(output_path, "w") as f:
        for ip in ips:
            f.write(ip + "\n")
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{timestamp}] Wrote {len(ips)} entries to {output_path}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--url", default=ZOOM_IP_URL)
    args = parser.parse_args()
    try:
        ips = fetch_zoom_ips(args.url)
    except Exception as e:
        print(f"ERROR fetching Zoom IPs: {e}", file=sys.stderr)
        sys.exit(1)
    if len(ips) < MIN_EXPECTED_ENTRIES:
        print(f"ERROR: Only {len(ips)} entries — expected at least {MIN_EXPECTED_ENTRIES}", file=sys.stderr)
        sys.exit(1)
    write_edl(ips, args.output)

if __name__ == "__main__":
    main()
