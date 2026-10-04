"""macOS interface discovery. Never use forwarded headers to approve pairing."""
import ipaddress
import re
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class Interfaces:
    ipv4: tuple = ()
    ipv6: tuple = ()
    networks: tuple = ()

    def local_peer(self, address):
        ip = ipaddress.ip_address(address)
        ip = getattr(ip, 'ipv4_mapped', None) or ip
        # Initial pairing is IPv4-only on a directly attached physical LAN.
        return isinstance(ip, ipaddress.IPv4Address) and any(ip in n for n in self.networks)


def parse_interfaces(output):
    ipv4, stable, temporary, networks = [], [], [], []
    for block in re.split(r'(?=^\S+: flags=)', output, flags=re.M):
        first = block.splitlines()[0] if block else ''
        if not re.match(r'(en\d+|bridge\d+): flags=.*\bUP\b', first):
            continue
        if 'status: inactive' in block:
            continue
        for line in block.splitlines()[1:]:
            p = line.split()
            try:
                if p[:1] == ['inet'] and 'netmask' in p:
                    ip = ipaddress.IPv4Address(p[1])
                    if not ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_unspecified:
                        continue
                    raw = p[p.index('netmask') + 1]
                    mask = str(ipaddress.IPv4Address(int(raw, 16))) if raw.startswith('0x') else raw
                    net = ipaddress.IPv4Network(f'{ip}/{mask}', strict=False)
                    ipv4.append(str(ip))
                    networks.append(net)
                elif p[:1] == ['inet6']:
                    ip = ipaddress.IPv6Address(p[1].split('%')[0])
                    if ip.is_global and not any(x in p for x in ('deprecated', 'tentative', 'duplicated')):
                        (temporary if 'temporary' in p else stable).append(str(ip))
            except (ValueError, IndexError):
                continue
    return Interfaces(tuple(dict.fromkeys(ipv4)), tuple(dict.fromkeys(stable + temporary)), tuple(networks))


def discover():
    output = subprocess.run(['/sbin/ifconfig'], capture_output=True, text=True, check=True, timeout=5).stdout
    return parse_interfaces(output)


def origin(ip, port):
    address = ipaddress.ip_address(ip)
    return f'https://[{address}]:{port}' if address.version == 6 else f'https://{address}:{port}'
