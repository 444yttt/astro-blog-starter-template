"""Offline checks for profile isolation, JWT signatures and idempotent CI setup."""

import base64
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import uuid


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "prepare-ci-profile.py"
SPEC = importlib.util.spec_from_file_location("prepare_ci_profile", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SigningBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temp.name)
        cls.key = cls.directory / "test-key.p8"
        cls.cert = cls.directory / "test-cert.pem"
        cls.team = "TESTTEAM01"
        cls.expiration = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(days=1)
        cls.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(cls.key))
        cls.key.chmod(0o600)
        cls.openssl("req", "-x509", "-new", "-key", str(cls.key), "-subj", "/CN=Local signing test/OU=" + cls.team, "-days", "2", "-out", str(cls.cert))
        cls.cert_der = cls.openssl("x509", "-in", str(cls.cert), "-outform", "DER")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @staticmethod
    def openssl(*args, data=None):
        return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout

    @classmethod
    def profile(cls, bundle_id=MODULE.CLIENT_BUNDLE_ID, name=MODULE.DEFAULT_PROFILE_NAME):
        profile_uuid = str(uuid.uuid4()).upper()
        payload = {
            "Name": name,
            "UUID": profile_uuid,
            "TeamIdentifier": [cls.team],
            "ApplicationIdentifierPrefix": [cls.team],
            "ExpirationDate": cls.expiration,
            "DeveloperCertificates": [cls.cert_der],
            "Entitlements": {
                "application-identifier": cls.team + "." + bundle_id,
                "com.apple.developer.team-identifier": cls.team,
                "get-task-allow": False,
            },
        }
        cms = cls.openssl("cms", "-sign", "-signer", str(cls.cert), "-inkey", str(cls.key), "-outform", "DER", "-nodetach", "-binary", data=plistlib.dumps(payload))
        return {
            "type": "profiles", "id": "PROFILE-TEST",
            "attributes": {"name": name, "uuid": profile_uuid, "profileType": "IOS_APP_STORE", "profileState": "ACTIVE", "expirationDate": cls.expiration.isoformat() + "Z", "profileContent": base64.b64encode(cms).decode()},
        }

    def test_jwt_signature_verifies_with_public_key(self):
        token = MODULE.make_jwt("TESTKEY001", "12345678-1234-1234-1234-123456789abc", self.key)
        header, claims, signature = token.split(".")
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        self.assertEqual(json.loads(decode(header))["alg"], "ES256")
        body = json.loads(decode(claims))
        self.assertEqual(body["aud"], "appstoreconnect-v1")
        self.assertEqual(body["exp"] - body["iat"], 600)
        raw = decode(signature)
        self.assertEqual(len(raw), 64)
        integers = []
        for value in (raw[:32], raw[32:]):
            value = value.lstrip(b"\x00") or b"\x00"
            if value[0] & 0x80:
                value = b"\x00" + value
            integers.append(b"\x02" + bytes([len(value)]) + value)
        contents = b"".join(integers)
        signature_path = self.directory / "signature.der"
        signature_path.write_bytes(b"\x30" + bytes([len(contents)]) + contents)
        public_path = self.directory / "public.pem"
        public_path.write_bytes(self.openssl("pkey", "-in", str(self.key), "-pubout"))
        self.openssl("dgst", "-sha256", "-verify", str(public_path), "-signature", str(signature_path), data=(header + "." + claims).encode())

    def test_real_cms_profile_is_isolated_to_client(self):
        _, metadata = MODULE.validate_profile(self.profile(), self.cert_der, MODULE.CLIENT_BUNDLE_ID, self.team)
        self.assertEqual(metadata["profile_type"], "IOS_APP_STORE")
        with self.assertRaisesRegex(MODULE.SigningError, "different app"):
            MODULE.validate_profile(self.profile(bundle_id="com.example.otherapp"), self.cert_der, MODULE.CLIENT_BUNDLE_ID, self.team)
        with self.assertRaisesRegex(MODULE.SigningError, "different Apple team"):
            MODULE.validate_profile(self.profile(), self.cert_der, MODULE.CLIENT_BUNDLE_ID, "OTHERTEAM1")

    def test_rerun_reuses_profile_without_another_apple_write(self):
        fixture = self

        class FakeApple:
            def __init__(self):
                self.bundles, self.profiles, self.writes = [], [], []

            def collection(self, path, filters=None):
                if path == "/v1/certificates":
                    return [{"id": "CERT-TEST", "attributes": {"certificateType": "IOS_DISTRIBUTION", "expirationDate": fixture.expiration.isoformat() + "Z", "certificateContent": base64.b64encode(fixture.cert_der).decode()}}]
                if path == "/v1/bundleIds":
                    return self.bundles
                if path == "/v1/bundleIds/BUNDLE-TEST/profiles":
                    self.profile_collection_path = path
                    return self.profiles
                raise AssertionError(path)

            def request(self, method, path, body=None):
                self.writes.append((method, path))
                if path == "/v1/bundleIds":
                    resource = {"id": "BUNDLE-TEST", "attributes": body["data"]["attributes"]}
                    self.bundles.append(resource)
                elif path == "/v1/profiles":
                    fixture.assertEqual(body["data"]["relationships"]["certificates"]["data"][0]["id"], "CERT-TEST")
                    resource = fixture.profile()
                    self.profiles.append(resource)
                else:
                    raise AssertionError(path)
                return {"data": resource}

        api = FakeApple()
        _, first = MODULE.prepare_profile(api, self.cert_der, MODULE.CLIENT_BUNDLE_ID, self.team, MODULE.DEFAULT_PROFILE_NAME)
        _, second = MODULE.prepare_profile(api, self.cert_der, MODULE.CLIENT_BUNDLE_ID, self.team, MODULE.DEFAULT_PROFILE_NAME)
        self.assertFalse(first["reused"])
        self.assertTrue(second["reused"])
        self.assertEqual(first["profile_uuid"], second["profile_uuid"])
        self.assertEqual(api.writes, [("POST", "/v1/bundleIds"), ("POST", "/v1/profiles")])
        self.assertEqual(api.profile_collection_path, "/v1/bundleIds/BUNDLE-TEST/profiles")
        with self.assertRaisesRegex(MODULE.SigningError, "may only provision"):
            MODULE.prepare_profile(api, self.cert_der, "com.example.otherapp", self.team, MODULE.DEFAULT_PROFILE_NAME)
        with self.assertRaisesRegex(MODULE.SigningError, "certificate belongs to a different Apple team"):
            MODULE.prepare_profile(api, self.cert_der, MODULE.CLIENT_BUNDLE_ID, "OTHERTEAM1", MODULE.DEFAULT_PROFILE_NAME)
        self.assertEqual(len(api.writes), 2)

    def test_incomplete_existing_profile_read_does_not_create_a_duplicate(self):
        fixture = self
        incomplete = self.profile()
        del incomplete["attributes"]["profileContent"]

        class ReadFailureApple:
            def collection(self, path, filters=None):
                if path == "/v1/certificates":
                    return [{"id": "CERT-TEST", "attributes": {"certificateType": "IOS_DISTRIBUTION", "expirationDate": fixture.expiration.isoformat() + "Z", "certificateContent": base64.b64encode(fixture.cert_der).decode()}}]
                if path == "/v1/bundleIds":
                    return [{"id": "BUNDLE-TEST", "attributes": {"identifier": MODULE.CLIENT_BUNDLE_ID, "platform": "IOS"}}]
                if path == "/v1/bundleIds/BUNDLE-TEST/profiles":
                    return [incomplete]
                raise AssertionError(path)

            def request(self, method, path, body=None):
                fixture.assertEqual(method, "GET")
                fixture.assertEqual(path, "/v1/profiles/PROFILE-TEST")
                raise MODULE.SigningError("Apple profile read permission denied.")

        with self.assertRaisesRegex(MODULE.SigningError, "read permission denied"):
            MODULE.prepare_profile(ReadFailureApple(), self.cert_der, MODULE.CLIENT_BUNDLE_ID, self.team, MODULE.DEFAULT_PROFILE_NAME)

    def test_credentials_are_never_sent_to_pagination_redirect_host(self):
        api = MODULE.AppleAPI("local-test-token")
        with self.assertRaisesRegex(MODULE.SigningError, "outside Apple's API"):
            api.request("GET", "https://example.com/v1/certificates")


if __name__ == "__main__":
    unittest.main()
