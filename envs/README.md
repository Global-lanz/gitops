# Active environments

Each `*.yaml` file here = one **enabled** environment. Every per-env ArgoCD
ApplicationSet uses a git `files` generator over `envs/*.yaml`
(`argocd-apps/blueprint.yaml`, `blueprint-auth.yaml`, `chat-n8n.yaml`, and
`apps/infrastructure/{postgres,kafka}/helm.yaml`).

So toggling is **one place for all apps**:

- **Enable an env** → add its `<env>.yaml` file.
- **Disable an env** → delete it, or rename so it no longer matches `*.yaml`
  (e.g. `qa.yaml` → `qa.yaml.disabled`).

Example — run only dev:

```sh
git mv envs/qa.yaml   envs/qa.yaml.disabled
git mv envs/prod.yaml envs/prod.yaml.disabled
git commit -am "run only dev" && git push
```

With `prune: true`, disabling an env **removes** its workloads across every app
(apps + Postgres + Kafka). Re-enabling re-creates them. Re-enable by reverting
the rename.

Each file carries all per-env params the templates read:

| key | used by |
|-----|---------|
| `env`, `namespace` | all |
| `database` | postgres (`auth.database`) |
| `postgresReplicas` | postgres (`primary.replicaCount`) |
| `kafkaReplicas` | kafka (`replicaCount`) |
