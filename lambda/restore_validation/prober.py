"""The prober: runs in the database's VPC with no AWS permissions, and
only speaks PostgreSQL. The validator invokes it with an endpoint and
credentials; it never logs its event, which holds the password.

- write: add a canary row (the time it was written) to the source
  database, and drop rows older than 30 days.
- read: return the newest canary in a restored copy.
"""

import os

import pgwire

CA_BUNDLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rds-global-bundle.pem")
UTC_TEXT = "to_char(%s AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"


def handler(event, context, cafile=CA_BUNDLE):
    conn = pgwire.Connection(event["host"], int(event["port"]), event["user"], event["password"],
                             event.get("dbname", "postgres"), cafile)
    try:
        if event["action"] == "write":
            conn.query("CREATE TABLE IF NOT EXISTS substrate_canary (written_at timestamptz PRIMARY KEY DEFAULT now())")
            written = conn.query("INSERT INTO substrate_canary DEFAULT VALUES RETURNING " + UTC_TEXT % "written_at")[0][0]
            conn.query("DELETE FROM substrate_canary WHERE written_at < now() - interval '30 days'")
            return {"written_at": written}
        if event["action"] == "read":
            newest, count = conn.query("SELECT " + UTC_TEXT % "max(written_at)" + ", count(*) FROM substrate_canary")[0]
            return {"newest": newest, "count": int(count)}
        raise ValueError("unknown action %r" % event["action"])
    finally:
        conn.close()
