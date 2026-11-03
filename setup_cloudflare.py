#!/usr/bin/env python3
"""Validate Cloudflare ranges, configure trusted proxy headers and optional UFW rules."""
import argparse
import ipaddress
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ssh-port', type=int, default=22)
    parser.add_argument('--firewall', choices=['True', 'False'], default='True')
    parser.add_argument('--check', action='store_true', help='Fetch and validate only; change nothing')
    args = parser.parse_args()
    if not 1 <= args.ssh_port <= 65535:
        parser.error('SSH port must be between 1 and 65535')
    networks = []
    for family in (4, 6):
        lines = subprocess.check_output(
            ['curl', '-fsS', '--retry', '3', '--max-time', '30',
             f'https://www.cloudflare.com/ips-v{family}'], text=True
        ).splitlines()
        parsed = [ipaddress.ip_network(line.strip(), strict=True) for line in lines if line.strip()]
        if not parsed or any(n.version != family or n.prefixlen == 0 for n in parsed):
            raise SystemExit(f'Invalid Cloudflare IPv{family} response')
        networks.extend(parsed)
    if args.check:
        print(f'Validated {len(networks)} Cloudflare networks; no changes made.')
        return
    if os.geteuid() != 0:
        raise SystemExit('Run as root')
    if args.firewall == 'True':
        # Adding narrow allows does not override an existing broad allow.
        # Refuse to silently preserve those or reset an administrator\'s firewall.
        rules = subprocess.check_output(['ufw', 'show', 'added'], text=True)
        if any(line.startswith('ufw ') for line in rules.splitlines()):
            raise SystemExit('Existing UFW rules found. Review them manually, or disable CLOUDFLARE_FIREWALL and manage equivalent restrictions yourself.')
        if 'IPV6=yes' not in Path('/etc/default/ufw').read_text():
            raise SystemExit('Enable IPV6=yes in /etc/default/ufw before continuing')
    directives = ''.join(f'set_real_ip_from {n};\n' for n in networks)
    directives += 'real_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n'
    target = Path('/etc/nginx/conf.d/cloudflare-realip.conf')
    target.write_text('# Cloudflare official ranges; regenerate when they change.\n' + directives)
    target.chmod(0o644)
    if args.firewall == 'True':
        commands = [
            ['allow', f'{args.ssh_port}/tcp', 'comment', 'SSH administration'],
            ['default', 'deny', 'incoming'],
            ['default', 'allow', 'outgoing'],
        ]
        commands += [['allow', 'proto', 'tcp', 'from', str(n), 'to', 'any', 'port', '80,443', 'comment', 'Cloudflare web'] for n in networks]
        commands += [['--force', 'enable']]
        for command in commands:
            subprocess.run(['ufw', *command], check=True)
    print('Cloudflare proxy configuration prepared.')


if __name__ == '__main__':
    main()
