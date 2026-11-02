"""The validator: checks each AWS Backup restore test of the self-test
database, and writes the canary those checks look for (cp-9.1).

Two events:
- the daily schedule ({"action": "write-canary"}, 04:00 UTC, an hour
  before the 05:00 backup) writes a canary row to the source database;
- a restore test's COMPLETED event checks the restored copy and reports
  SUCCESSFUL or FAILED to AWS Backup, with what was checked.

A restored copy passes when it is available, encrypted with the source's
KMS key, on the source's engine and version, and holds the newest canary
written before its recovery point (no more than 26 hours before it: the
daily canary, with slack). Any failure is reported as FAILED with the
reason, or raised so the invocation fails into the dead-letter queue;
none is silent.

The prober (in the VPC, no AWS permissions) does the PostgreSQL work;
this function, outside the VPC, does the AWS calls.
"""

import datetime
import json
import os

MAX_CANARY_AGE = datetime.timedelta(hours=26)


class Invalid(Exception):
    """The restored copy failed a check."""


class Clients:
    """The AWS calls this function makes."""

    def __init__(self):
        import boto3

        self.rds = boto3.client("rds")
        self.backup = boto3.client("backup")
        self.secrets = boto3.client("secretsmanager")
        self.lambda_ = boto3.client("lambda")

    def db(self, identifier):
        return self.rds.describe_db_instances(DBInstanceIdentifier=identifier)["DBInstances"][0]

    def restore_job(self, job_id):
        return self.backup.describe_restore_job(RestoreJobId=job_id)

    def password(self, secret_arn):
        value = self.secrets.get_secret_value(SecretId=secret_arn)["SecretString"]
        try:
            parsed = json.loads(value)
        except ValueError:
            return value
        return parsed["password"] if isinstance(parsed, dict) else value

    def probe(self, function, payload):
        out = self.lambda_.invoke(FunctionName=function, Payload=json.dumps(payload).encode())
        body = json.loads(out["Payload"].read())
        if out.get("FunctionError"):
            raise RuntimeError("prober failed: %s: %s" % (body.get("errorType"), body.get("errorMessage")))
        return body

    def report(self, job_id, status, message):
        self.backup.put_restore_validation_result(RestoreJobId=job_id, ValidationStatus=status,
                                                  ValidationStatusMessage=message)


def _endpoint(db, password):
    return {"host": db["Endpoint"]["Address"], "port": db["Endpoint"]["Port"],
            "user": db["MasterUsername"], "password": password}


def _utc(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def write_canary(clients, env):
    source = clients.db(env["SOURCE_DB"])
    out = clients.probe(env["PROBER_FUNCTION"], dict(_endpoint(source, clients.password(env["DB_SECRET_ARN"])), action="write"))
    return {"canary_written": out["written_at"]}


def validate(clients, env, job_id):
    """Check the restore job's copy; return what passed, or raise Invalid."""
    job = clients.restore_job(job_id)
    restored = clients.db(job["CreatedResourceArn"])
    source = clients.db(env["SOURCE_DB"])
    name = restored["DBInstanceIdentifier"]
    checks = [
        (restored["DBInstanceStatus"] == "available", "status %s, not available" % restored["DBInstanceStatus"]),
        (restored.get("StorageEncrypted") is True, "storage not encrypted"),
        (restored.get("KmsKeyId") == source.get("KmsKeyId"), "KMS key %s, not the source's %s" % (restored.get("KmsKeyId"), source.get("KmsKeyId"))),
        ((restored["Engine"], restored["EngineVersion"]) == (source["Engine"], source["EngineVersion"]),
         "engine %s %s, not the source's %s %s" % (restored["Engine"], restored["EngineVersion"], source["Engine"], source["EngineVersion"])),
    ]
    failed = [why for ok, why in checks if not ok]
    if failed:
        raise Invalid("%s: %s" % (name, "; ".join(failed)))
    canary = clients.probe(env["PROBER_FUNCTION"], dict(_endpoint(restored, clients.password(env["DB_SECRET_ARN"])), action="read"))
    if not canary.get("newest"):
        raise Invalid("%s: no canary rows" % name)
    newest = _utc(canary["newest"])
    point = job["RecoveryPointCreationDate"].astimezone(datetime.timezone.utc)
    if newest > point:
        raise Invalid("%s: newest canary %s is after the recovery point %s" % (name, canary["newest"], point.isoformat()))
    if point - newest > MAX_CANARY_AGE:
        raise Invalid("%s: newest canary %s is more than 26 hours before the recovery point %s" % (name, canary["newest"], point.isoformat()))
    minutes = int((point - newest).total_seconds() // 60)
    return ("%s: available, encrypted with the source's key, %s %s; newest canary %s, %d minutes before the recovery point (%d rows)"
            % (name, restored["Engine"], restored["EngineVersion"], canary["newest"], minutes, canary["count"]))


def handler(event, context, clients=None, env=None):
    clients = clients or Clients()
    env = env or os.environ
    if event.get("action") == "write-canary":
        out = write_canary(clients, env)
        print(json.dumps(out))
        return out
    job_id = event["detail"]["restoreJobId"]
    try:
        status, message = "SUCCESSFUL", validate(clients, env, job_id)
    except Invalid as e:
        status, message = "FAILED", str(e)
    except Exception as e:  # a check that couldn't run is a failed validation, said aloud
        status, message = "FAILED", "validation couldn't run: %s: %s" % (type(e).__name__, e)
    clients.report(job_id, status, message[:1000])
    out = {"restore_job": job_id, "validation": status, "message": message}
    print(json.dumps(out))
    return out
