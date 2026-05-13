#!/usr/bin/env python3
"""check-clean-ip — проверяет попадает ли IP в RU mobile whitelist."""
import ipaddress, os, sys, time, urllib.request

CACHE_DIR = os.path.expanduser('~/.cache/swiftrun-clean-ip')
CACHE_TTL = 86400
SOURCES = {
    'cidrwhitelist.txt': 'https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/cidrwhitelist.txt',
    'ipwhitelist.txt': 'https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/ipwhitelist.txt',
}


def fetch(name, url):
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, name)
    if os.path.exists(path) and (time.time() - os.path.getmtime(path)) < CACHE_TTL:
        return open(path).read()
    print(f'Fetching {name}...', file=sys.stderr)
    data = urllib.request.urlopen(url, timeout=30).read().decode()
    with open(path, 'w') as f:
        f.write(data)
    return data


def check_ip(ip):
    ip_obj = ipaddress.ip_address(ip)

    for line in fetch('ipwhitelist.txt', SOURCES['ipwhitelist.txt']).splitlines():
        line = line.strip()
        if line and not line.startswith('#') and line == str(ip_obj):
            return ('IP', line)

    for line in fetch('cidrwhitelist.txt', SOURCES['cidrwhitelist.txt']).splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            if ip_obj in ipaddress.ip_network(line, strict=False):
                return ('CIDR', line)
        except ValueError:
            continue

    return (None, None)


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ['-h', '--help']:
        print(__doc__)
        sys.exit(0)
    if sys.argv[1] == '--update':
        for name in SOURCES:
            p = os.path.join(CACHE_DIR, name)
            if os.path.exists(p):
                os.remove(p)
        for name, url in SOURCES.items():
            fetch(name, url)
        print('Updated.')
        sys.exit(0)

    ip = sys.argv[1]
    try:
        kind, match = check_ip(ip)
    except ValueError as e:
        print(f'Invalid IP: {e}', file=sys.stderr)
        sys.exit(2)

    if match:
        print(f'\033[32m✓ WHITELISTED\033[0m  {ip}  matches {kind}: {match}')
        sys.exit(0)
    print(f'\033[31m✗ NOT IN WHITELIST\033[0m  {ip}  — will be blocked during operator restriction mode')
    sys.exit(1)


if __name__ == '__main__':
    main()
