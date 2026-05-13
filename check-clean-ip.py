#!/usr/bin/env python3
"""check-clean-ip — комплексная проверка IP на пригодность к RU VPN.

Tests:
1. RU mobile whitelist membership (hxehex/russia-mobile-internet-whitelist)
2. TCP reachability на :443 с RU-операторов (check-host.net)

Exit codes:
    0 — все проверки прошли
    1 — частично прошли / полный провал
    2 — невалидный IP

Usage:
    check-clean-ip <IP>                   # all checks
    check-clean-ip --no-reach <IP>        # skip operator pings (fast)
    check-clean-ip --port 8080 <IP>       # custom port
    check-clean-ip --update               # force refresh whitelist cache
"""
import argparse, ipaddress, json, os, sys, time
import urllib.request, urllib.parse, urllib.error

WHITELIST_BASE = 'https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main'
CHECK_HOST_API = 'https://check-host.net'
CACHE_DIR = os.path.expanduser('~/.cache/swiftrun-clean-ip')
CACHE_TTL = 86400

UA = 'swiftrun-clean-ip/1.0 (+https://github.com/Kirill-kkr/swiftrun-scripts)'


def http_get(url, accept_json=False, timeout=30):
    headers = {'User-Agent': UA}
    if accept_json:
        headers['Accept'] = 'application/json'
    req = urllib.request.Request(url, headers=headers)
    return urllib.request.urlopen(req, timeout=timeout).read().decode()


def color(text, c):
    codes = {'g': '\033[32m', 'r': '\033[31m', 'y': '\033[33m', 'b': '\033[34m', 'd': '\033[2m'}
    return f'{codes.get(c, "")}{text}\033[0m'


def cache_path(name):
    os.makedirs(CACHE_DIR, exist_ok=True)
    return os.path.join(CACHE_DIR, name)


def get_whitelist(name):
    path = cache_path(name)
    if os.path.exists(path) and (time.time() - os.path.getmtime(path)) < CACHE_TTL:
        return open(path).read()
    print(color(f'  fetching {name}…', 'd'), file=sys.stderr)
    data = http_get(f'{WHITELIST_BASE}/{name}')
    with open(path, 'w') as f:
        f.write(data)
    return data


def whitelist_check(ip):
    ip_obj = ipaddress.ip_address(ip)

    for line in get_whitelist('ipwhitelist.txt').splitlines():
        line = line.strip()
        if line and not line.startswith('#') and line == str(ip_obj):
            return (True, f'IP: {line}')

    for line in get_whitelist('cidrwhitelist.txt').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            if ip_obj in ipaddress.ip_network(line, strict=False):
                return (True, f'CIDR: {line}')
        except ValueError:
            continue
    return (False, None)


def ru_reachability(ip, port=443, max_wait=25):
    nodes = ['ru1.node.check-host.net', 'ru2.node.check-host.net',
             'ru3.node.check-host.net', 'ru4.node.check-host.net']

    params = [('host', f'{ip}:{port}'), ('max_nodes', str(len(nodes)))]
    for n in nodes:
        params.append(('node', n))
    query = urllib.parse.urlencode(params)

    try:
        init = json.loads(http_get(f'{CHECK_HOST_API}/check-tcp?{query}', accept_json=True))
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        return ('error', str(e), {})

    if not init.get('ok') or 'request_id' not in init:
        return ('error', f'init failed: {init}', {})

    request_id = init['request_id']
    actual_nodes = sorted(init['nodes'].keys())
    node_info = init['nodes']  # {node_name: [country, region, city, ip, asn]}

    deadline = time.time() + max_wait
    last = None
    while time.time() < deadline:
        time.sleep(3)
        try:
            last = json.loads(http_get(f'{CHECK_HOST_API}/check-result/{request_id}', accept_json=True))
        except (urllib.error.URLError, json.JSONDecodeError):
            continue
        if all(last.get(n) is not None for n in actual_nodes):
            break

    out = {}
    for node in actual_nodes:
        label = node.replace('.node.check-host.net', '')
        info = node_info.get(node, ['', '', '', '', ''])
        city = info[2] if len(info) > 2 else '?'
        results = (last or {}).get(node)
        if results and isinstance(results, list) and results[0]:
            entry = results[0]
            if isinstance(entry, dict) and entry.get('time') is not None:
                out[label] = {'ok': True, 'ms': int(entry['time'] * 1000), 'city': city}
                continue
            err = entry.get('error') if isinstance(entry, dict) else str(entry)
            out[label] = {'ok': False, 'error': err, 'city': city}
        else:
            out[label] = {'ok': False, 'error': 'no data (timeout)', 'city': city}
    return ('ok', None, out)


def main():
    p = argparse.ArgumentParser(description='Check IP for RU VPN suitability', formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument('ip', nargs='?', help='IP to check')
    p.add_argument('--port', type=int, default=443, help='TCP port (default 443)')
    p.add_argument('--no-reach', action='store_true', help='Skip RU reachability check')
    p.add_argument('--update', action='store_true', help='Force refresh whitelist cache')
    args = p.parse_args()

    if args.update:
        for f in ['ipwhitelist.txt', 'cidrwhitelist.txt']:
            path = cache_path(f)
            if os.path.exists(path):
                os.remove(path)
        get_whitelist('ipwhitelist.txt')
        get_whitelist('cidrwhitelist.txt')
        print(color('✓ whitelist cache refreshed', 'g'))
        return 0

    if not args.ip:
        p.print_help()
        return 2

    try:
        ipaddress.ip_address(args.ip)
    except ValueError as e:
        print(color(f'invalid IP: {e}', 'r'), file=sys.stderr)
        return 2

    print(f'\nChecking {color(args.ip, "b")}\n')
    score_pass = score_total = 0

    # 1. Whitelist
    print(f'1. {color("RU mobile whitelist", "b")} (hxehex)')
    in_wl, info = whitelist_check(args.ip)
    score_total += 1
    if in_wl:
        print(f'   {color("✓ in whitelist", "g")}  {info}')
        score_pass += 1
    else:
        print(f'   {color("✗ not in whitelist", "r")}  (blocked during operator restriction mode)')

    # 2. Reachability
    if not args.no_reach:
        print(f'\n2. {color("RU operator reachability", "b")} (TCP :{args.port} via check-host.net)')
        status, err, results = ru_reachability(args.ip, args.port)
        if status == 'error':
            print(f'   {color(f"? check-host.net error: {err}", "y")}')
        else:
            for label, data in results.items():
                score_total += 1
                city = data.get('city', '?')
                if data['ok']:
                    ms = data['ms']
                    c = 'g' if ms < 100 else 'y' if ms < 300 else 'r'
                    print(f'   {color("✓", "g")} {label:4} {city:15} {color(f"{ms}ms", c)}')
                    score_pass += 1
                else:
                    print(f'   {color("✗", "r")} {label:4} {city:15} {data.get("error", "?")}')

    # Verdict
    print()
    if score_pass == score_total:
        print(f'VERDICT: {color("✓ ALL CLEAN", "g")} ({score_pass}/{score_total}) — safe to use')
        return 0
    if score_pass > 0:
        print(f'VERDICT: {color("⚠ PARTIAL", "y")} ({score_pass}/{score_total}) — works for some operators/regions')
        return 1
    print(f'VERDICT: {color("✗ DIRTY", "r")} ({score_pass}/{score_total}) — likely blocked everywhere')
    return 1


if __name__ == '__main__':
    sys.exit(main())
