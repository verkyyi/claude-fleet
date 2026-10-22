#!/usr/bin/env python3
"""Public page reader regressions; no external network or credentials."""
import importlib.util
import io
import pathlib
import socket
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('reader', pathlib.Path(__file__).with_name('fleet-svc-fetch.py'))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class Sock:
    def settimeout(self, value): pass
    def connect(self, address): self.address = address
    def close(self): pass


class Response(io.BytesIO):
    status = 200
    headers = {}

    def getheader(self, name, default=None):
        return self.headers.get(name, default)


class Connection:
    responses = []
    requests = []

    def __init__(self, *args, **kwargs): pass
    def request(self, *args, **kwargs): self.requests.append((args, kwargs))
    def getresponse(self): return self.responses.pop(0)
    def close(self): pass


def address(ip):
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, '', (ip, 80))]


class ReaderTests(unittest.TestCase):
    def test_internal_and_metadata_addresses(self):
        for ip in ('127.0.0.1', '10.0.0.1', '169.254.169.254', '100.100.100.200',
                   '192.168.1.1', '172.16.0.1', '::1', 'fc00::1', '::ffff:8.8.8.8', '224.0.0.1'):
            with self.subTest(ip=ip), patch.object(socket, 'getaddrinfo', return_value=address(ip)):
                with self.assertRaises(ValueError): reader.public_addresses('example.com', 80)

    def test_mixed_dns_refused(self):
        with patch.object(socket, 'getaddrinfo', return_value=address('8.8.8.8') + address('127.0.0.1')):
            with self.assertRaises(ValueError): reader.public_addresses('example.com', 80)

    def test_invalid_scheme_and_userinfo(self):
        for url in ('file:///etc/passwd', 'ftp://example.com/a', 'http://user:password@example.com'):
            with self.subTest(url=url), self.assertRaises(ValueError): reader.fetch(url)

    def perform(self, responses, dns):
        Connection.responses = responses
        Connection.requests = []
        sock = Sock()
        with patch.object(socket, 'getaddrinfo', side_effect=dns), \
                patch.object(socket, 'socket', return_value=sock), \
                patch.object(reader.http.client, 'HTTPConnection', Connection):
            result = reader.fetch('http://example.com/article?q=1')
        self.assertEqual(sock.address, ('8.8.8.8', 80))
        self.assertEqual(Connection.requests[0][0], ('GET', '/article?q=1'))
        return result

    def test_public_get_and_pinned_ip(self):
        self.assertEqual(self.perform([Response(b'page')], [address('8.8.8.8')]), b'page')

    def test_redirect_cannot_reach_private_address(self):
        redirect = Response()
        redirect.status, redirect.headers = 302, {'Location': 'http://internal.example/'}
        with self.assertRaises(ValueError):
            self.perform([redirect], [address('8.8.8.8'), address('127.0.0.1')])

    def test_size_limit(self):
        with self.assertRaises(ValueError):
            self.perform([Response(b'x' * (reader.MAX_BYTES + 1))], [address('8.8.8.8')])
        self.assertEqual(len(self.perform([Response(b'x' * reader.MAX_BYTES)], [address('8.8.8.8')])), reader.MAX_BYTES)

    def test_compression_refused(self):
        response = Response(b'compressed')
        response.headers = {'Content-Encoding': 'gzip'}
        with self.assertRaises(ValueError): self.perform([response], [address('8.8.8.8')])


if __name__ == '__main__':
    unittest.main()
