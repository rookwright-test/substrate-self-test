"""Unit tests (standard library only): python3 -m unittest discover lambda/restore_validation"""

import base64
import datetime
import json
import os
import tempfile
import unittest

import pgwire
import validator

UTC = datetime.timezone.utc
POINT = datetime.datetime(2026, 11, 7, 5, 3, tzinfo=UTC)
ENV = {"SOURCE_DB": "substrate-self-test", "DB_SECRET_ARN": "arn:secret", "PROBER_FUNCTION": "prober"}


class ScramTest(unittest.TestCase):
    def test_rfc7677_vector(self):
        # RFC 7677 section 3's example exchange.
        client_first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO"
        server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        final = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
        proof, server = pgwire.scram_proof("pencil", base64.b64decode("W22ZaJ0SNY7soEsUEjb6gQ=="), 4096,
                                           ",".join((client_first_bare, server_first, final)).encode())
        self.assertEqual(base64.b64encode(proof).decode(), "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        self.assertEqual(base64.b64encode(server).decode(), "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")


def instance(identifier, **overrides):
    db = {"DBInstanceIdentifier": identifier, "DBInstanceStatus": "available", "StorageEncrypted": True,
          "KmsKeyId": "arn:key", "Engine": "postgres", "EngineVersion": "16.10", "MasterUsername": "substrate",
          "Endpoint": {"Address": identifier + ".example", "Port": 5432}}
    db.update(overrides)
    return db


class FakeClients:
    def __init__(self, restored=None, canary=None, probe_error=None):
        self.dbs = {"substrate-self-test": instance("substrate-self-test"),
                    "arn:aws:rds:us-east-2:1:db:restored": restored or instance("restored")}
        self.canary = canary if canary is not None else {"newest": "2026-11-07T04:00:01Z", "count": 30}
        self.probe_error = probe_error
        self.probes, self.reports = [], []

    def db(self, identifier):
        return self.dbs[identifier]

    def restore_job(self, job_id):
        return {"CreatedResourceArn": "arn:aws:rds:us-east-2:1:db:restored", "RecoveryPointCreationDate": POINT}

    def password(self, arn):
        return "secret"

    def probe(self, function, payload):
        self.probes.append(payload)
        if self.probe_error:
            raise self.probe_error
        return {"written_at": "2026-11-07T04:00:01Z"} if payload["action"] == "write" else self.canary

    def report(self, job_id, status, message):
        self.reports.append((job_id, status, message))


def run(clients):
    return validator.handler({"detail": {"restoreJobId": "job-1"}}, None, clients=clients, env=ENV)


class ValidatorTest(unittest.TestCase):
    def test_passes(self):
        c = FakeClients()
        out = run(c)
        self.assertEqual(out["validation"], "SUCCESSFUL", out)
        self.assertEqual(c.reports[0][:2], ("job-1", "SUCCESSFUL"))
        self.assertIn("newest canary 2026-11-07T04:00:01Z, 62 minutes before the recovery point (30 rows)", out["message"])
        self.assertEqual(c.probes[0], {"host": "restored.example", "port": 5432, "user": "substrate", "password": "secret", "action": "read"})

    def test_failures_are_reported(self):
        for name, clients, want in [
            ("not available", FakeClients(restored=instance("restored", DBInstanceStatus="creating")), "status creating"),
            ("unencrypted", FakeClients(restored=instance("restored", StorageEncrypted=False)), "storage not encrypted"),
            ("other key", FakeClients(restored=instance("restored", KmsKeyId="arn:other")), "KMS key arn:other"),
            ("other version", FakeClients(restored=instance("restored", EngineVersion="15.4")), "engine postgres 15.4"),
            ("no canary", FakeClients(canary={"newest": None, "count": 0}), "no canary rows"),
            ("canary too old", FakeClients(canary={"newest": "2026-11-06T03:00:00Z", "count": 1}), "more than 26 hours"),
            ("canary after point", FakeClients(canary={"newest": "2026-11-07T06:00:00Z", "count": 1}), "after the recovery point"),
            ("prober failed", FakeClients(probe_error=RuntimeError("prober failed: Error: relation does not exist")), "validation couldn't run: RuntimeError"),
        ]:
            with self.subTest(name):
                out = run(clients)
                self.assertEqual(out["validation"], "FAILED")
                self.assertIn(want, clients.reports[0][2])

    def test_unchecked_metadata_skips_the_probe(self):
        c = FakeClients(restored=instance("restored", StorageEncrypted=False))
        run(c)
        self.assertEqual(c.probes, [])

    def test_write_canary(self):
        c = FakeClients()
        out = validator.handler({"action": "write-canary"}, None, clients=c, env=ENV)
        self.assertEqual(out, {"canary_written": "2026-11-07T04:00:01Z"})
        self.assertEqual(c.probes[0]["host"], "substrate-self-test.example")
        self.assertEqual(c.probes[0]["action"], "write")
        self.assertEqual(c.reports, [])

    def test_report_failure_is_not_swallowed(self):
        c = FakeClients()

        def broken(*args):
            raise RuntimeError("AccessDenied")
        c.report = broken
        with self.assertRaises(RuntimeError):
            run(c)


class ConfigTest(unittest.TestCase):
    def write(self, config):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(config, f)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_loads(self):
        self.assertEqual(validator.load_config(self.write(ENV)), ENV)

    def test_missing_setting_fails(self):
        with self.assertRaisesRegex(ValueError, "lacks PROBER_FUNCTION"):
            validator.load_config(self.write(dict(ENV, PROBER_FUNCTION="")))


if __name__ == "__main__":
    unittest.main()
