# Postgres — per-app databases

Each app has its own schema (they all define a `User` table), so they get a
**dedicated database on the shared per-env Postgres instance**:

| App                | Database                              |
|--------------------|----------------------------------------|
| blueprint-backend  | `blueprint-<env>` (`blueprint` in prod) |
| blueprint-auth     | `blueprint_auth`                       |
| norteia backend    | `norteiadb`                            |
| guia backend       | `guiadb`                               |
| n8n                | `n8ndb`                                |

`blueprint-<env>` is the chart's **primary** database (Bitnami `auth.database`
value in `envs-overlays/<env>/postgres-helmrelease.yaml`). `blueprint_auth`,
`norteiadb`, `guiadb` and `n8ndb` are **extra** databases created via
`primary.initdb.scripts` in that same file.

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
    -c "CREATE DATABASE norteiadb OWNER app;" \
    -c "CREATE DATABASE guiadb OWNER app;" \
    -c "CREATE DATABASE n8ndb OWNER app;"
```

(Re-running `CREATE DATABASE` for one that already exists is a harmless error.)
