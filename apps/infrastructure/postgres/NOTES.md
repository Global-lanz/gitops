# Postgres — per-app databases

Each app has its own schema (they all define a `User` table), so they get a
**dedicated database on the shared per-env Postgres instance** instead of
sharing `appdb`:

| App                | Database         |
|--------------------|------------------|
| blueprint-backend  | `appdb-<env>`    |
| blueprint-auth     | `blueprint_auth` |
| chat-n8n backend   | `chatdb`         |

`helm.yaml` creates `blueprint_auth` and `chatdb` via `primary.initdb.scripts`.

## ⚠️ initdb only runs on a fresh volume

The init script runs **only the first time** the data directory is created
(empty PVC). On a Postgres instance that is **already initialized**, the extra
databases will NOT be created automatically — create them once by hand:

```sh
# replace <env> with dev | qa | prod
PW=$(kubectl -n <env> get secret postgres-<env>-postgresql \
      -o jsonpath='{.data.postgres-password}' | base64 -d)

kubectl -n <env> exec -it postgres-<env>-postgresql-0 -- \
  env PGPASSWORD="$PW" psql -U postgres \
    -c "CREATE DATABASE blueprint_auth OWNER app;" \
    -c "CREATE DATABASE chatdb OWNER app;"
```

(Re-running `CREATE DATABASE` for one that already exists is a harmless error.)
