# vault-recovery-fabric

> **Status: alpha / technical preview**
> Do not use in production without a security review and a successful recovery drill.

**Declarative recovery-plane for Vault OSS deployments on Kubernetes.**

> This chart does not replace Vault Enterprise DR replication or KMS/HSM auto-unseal.
> It adds a declarative cross-cluster recovery orchestration layer for Vault OSS deployments.

## What is this?

Vault clusters seal themselves on restart. The standard response is either:
- A cloud KMS (vendor lock-in), or
- An operator following a runbook under pressure

`vault-recovery-fabric` takes a third path: **recovery-as-code**.
The recovery behaviour is declared in the Helm values and deployed as Kubernetes resources.
No cloud KMS dependency. Reduced runbook: one manually recovered seed cluster
can restore the rest through declared recovery jobs.

```
Vault-A sealed  →  recovery job  →  Vault-B (fallback)
                       │                   │
                  K8s auth (JWT)     reads unseal-keys-A
                       │
                  sys/unseal  →  Vault-A unsealed
```

In a full mesh, manually unsealing one cluster is enough — the rest recover automatically.

## Architecture

```
Vault-A ──fallback──► Vault-B
Vault-B ──fallback──► Vault-C
Vault-C ──fallback──► Vault-A
```

See `docs/architecture.md` for component details and invariants.
See `docs/threat-model.md` for security analysis.

## Requirements

- Kubernetes 1.24+
- Helm 3.x
- HashiCorp Vault Helm chart (bundled as dependency)
- **Helm release name must be `vault`** — the Vault subchart generates service names
  (`vault-active`, `vault-0.vault-internal`) from the release name. The recovery scripts
  depend on these names. Other release names are not supported in this version.

## Quick Start — Single Cluster

```bash
helm upgrade -i vault ./vault -n kube-vault --create-namespace
```

After install, the init job runs once and:
- Initializes Vault
- Configures Kubernetes auth
- Configures the `vault-recovery-unseal` K8s auth role
- Does **not** store unseal keys locally by default (`bootstrap.storeUnsealKeys: false`)

> **postStart auto-unseal**: the postStart hook attempts to read unseal keys from
> `secret/vault/unseal-keys` on the local Vault. This only works when
> `bootstrap.storeUnsealKeys=true`. Without local keys, the pod starts and logs
> a warning — unseal is then handled via the recovery Job or manual intervention.

**Lab install** (local auto-unseal enabled):

```bash
helm upgrade -i vault ./vault -n kube-vault \
  --create-namespace -f values-lab.yaml
```

Run smoke tests:
```bash
helm test vault -n kube-vault
```

## Recovery Mesh Setup

### 1. Deploy vault on each cluster with its name

```bash
helm upgrade -i vault ./vault -n kube-vault \
  -f values-mesh.yaml \
  --set recovery.selfName=vault-a
```

### 2. Configure cross-cluster K8s auth on each fallback Vault

See `vault-mesh-setup` ConfigMap after install:
```bash
kubectl get configmap vault-mesh-setup -n kube-vault -o jsonpath='{.data.README}'
```

### 3. Store recovery material on fallback Vault

**Production (encrypted — recommended):**

```bash
# Create passphrase secret on THIS cluster
kubectl create secret generic vault-recovery-passphrase \
  -n kube-vault \
  --from-literal=passphrase="$(openssl rand -base64 32)"

PASSPHRASE=$(kubectl get secret vault-recovery-passphrase \
  -n kube-vault -o jsonpath='{.data.passphrase}' | base64 -d)

# Source: your secure out-of-band bootstrap custody (do not use local KV in production)
# The unseal keys were obtained during vault operator init — store them securely
ENCRYPTED=$(cat /secure/bootstrap/vault-a-unseal-keys.txt \
  | openssl enc -aes-256-cbc -pbkdf2 -pass "pass:$PASSPHRASE" | openssl base64 -A)
# Mesh path (recovery.selfName=vault-a):
VAULT_ADDR=<vault-b-addr> vault kv put secret/recovery/vault-a/unseal-keys contents="$ENCRYPTED"
# Legacy/lab path (no selfName):
# VAULT_ADDR=<vault-b-addr> vault kv put secret/vault/unseal-keys contents="$ENCRYPTED"
```

> **Note**: Production setups must source recovery material from secure out-of-band
> bootstrap custody — not from local KV. The chart does not persist unseal keys by
> default (`bootstrap.storeUnsealKeys: false`).

> **Lab only (raw — not suitable for production):**
> ```bash
> # Requires bootstrap.storeUnsealKeys=true
> KEYS=$(vault kv get -field=contents secret/vault/unseal-keys)
> VAULT_ADDR=<vault-b-addr> vault kv put secret/vault/unseal-keys contents="$KEYS"
> ```

### 4. Trigger recovery when needed

Each recovery is an explicit event identified by a unique `triggerId`:

```bash
helm upgrade vault ./vault -n kube-vault \
  --set recovery.manualJob.triggerId=$(date +%Y%m%d%H%M%S) \
  --set recovery.fallback.addr=https://vault-b.example.com:8200 \
  --set recovery.fallback.cidr=10.10.20.0/24
```

> `recovery.fallback.cidr` is required when `networkPolicy.enabled=true` (default).
> Set it to the CIDR of your fallback Vault cluster.

After recovery completes, reset:

```bash
helm upgrade vault ./vault -n kube-vault \
  --set recovery.manualJob.triggerId=""
```

## Key Rotation (Rekey)

Rekey is a destructive, high-impact operation and requires explicit triple confirmation.

> **Prerequisites**: the Rekey Job reads current unseal keys from `secret/vault/unseal-keys`
> on the local Vault. This requires either `bootstrap.storeUnsealKeys=true` (lab) or
> the recovery material to have been loaded into the local KV via the mesh setup process.
> If neither applies, provide the material out-of-band before triggering rekey.

```bash
helm upgrade vault ./vault -n kube-vault \
  --set recovery.rekey.enabled=true \
  --set recovery.rekey.confirm=true \
  --set recovery.rekey.experimental=true

# After completion, reset all flags:
helm upgrade vault ./vault -n kube-vault \
  --set recovery.rekey.enabled=false \
  --set recovery.rekey.confirm=false
```

See drill procedures: `kubectl get configmap vault-recovery-drill -n kube-vault`

## Modes

| File | Use case |
|---|---|
| `values-lab.yaml` | Local testing, no NetworkPolicy, 1-of-1 key shares |
| `values-mesh.yaml` | Multi-cluster template, encryption enabled |
| `values-production.yaml` | Full hardening, pod anti-affinity |

```bash
# Lab
helm upgrade -i vault ./vault -n kube-vault -f values-lab.yaml

# Production mesh
helm upgrade -i vault ./vault -n kube-vault \
  -f values-production.yaml \
  -f values-mesh.yaml \
  --set recovery.selfName=vault-a \
  --set recovery.fallback.addr=https://vault-b.example.com:8200
```

## Encryption

When `recovery.encryption.enabled=true`, unseal keys stored in the fallback Vault
are AES-256-CBC encrypted. The passphrase lives in a K8s Secret on the local cluster.

```bash
kubectl create secret generic vault-recovery-passphrase \
  -n kube-vault \
  --from-literal=passphrase="$(openssl rand -base64 32)"
```

Fallback Vault compromise alone is insufficient to decrypt — the attacker also needs
access to the K8s API of the target cluster.

> **Note**: This mode assumes the target cluster Kubernetes Secret store is trusted
> and protected. Ensure Kubernetes Secret encryption-at-rest is enabled and RBAC
> restricts access to `vault-recovery-passphrase`.

## Values reference

| Key | Default | Description |
|---|---|---|
| `bootstrap.storeUnsealKeys` | `false` | Store unseal keys in local KV (lab only — see note) |
| `networkPolicy.enabled` | `true` | Deploy NetworkPolicy resources |
| `recovery.manualJob.triggerId` | `""` | Non-empty triggers the operator recovery Job (must be string, not number) |
| `recovery.podUnseal.enabled` | `true` | Enable pod lifecycle assisted-unseal via initContainer |
| `recovery.selfName` | `""` | This cluster's name in the mesh |
| `recovery.fallback.addr` | `""` | Fallback Vault API address (required when triggerId set) |
| `recovery.fallback.tlsSkipVerify` | `false` | Skip TLS verification (**never use in production**) |
| `recovery.fallback.cidr` | `""` | Fallback Vault CIDR for NetworkPolicy egress; **required** when `recovery.manualJob.triggerId` is set with `networkPolicy.enabled=true` (chart fails without it) |
| `recovery.rekey.experimental` | `true` | Acknowledge rekey is experimental |
| `recovery.rekey.confirm` | `false` | Must be `true` to trigger rekey job |
| `recovery.rekey.keyShares` | `5` | Number of new key shares |
| `recovery.rekey.keyThreshold` | `3` | Unseal threshold |
| `recovery.encryption.enabled` | `false` | Encrypt recovery material with AES-256 (**required in production**) |
| `recovery.encryption.passphraseSecret` | `""` | K8s Secret name containing `passphrase` key |

> **Lab vs production**: `bootstrap.storeUnsealKeys=true` and `recovery.encryption.enabled=false`
> are acceptable for local testing only. Raw recovery material storage and unencrypted
> fallback transfer are not suitable for production-like deployments.
> Use `values-mesh.yaml` or `values-production.yaml` as a starting point.

## Recovery material path model

The path where unseal keys are stored depends on `recovery.selfName`:

| Mode | `recovery.selfName` | Local path | Fallback path |
|---|---|---|---|
| Lab / legacy | `""` (empty) | `secret/vault/unseal-keys` | explicit `fallback.secretPath` |
| Mesh | `vault-a` | `secret/recovery/vault-a/unseal-keys` | `secret/recovery/vault-a/unseal-keys` |

> **Note**: the postStart auto-unseal hook always reads from the legacy path
> (`secret/vault/unseal-keys`). In mesh mode (`selfName` set), set
> `bootstrap.storeUnsealKeys=false` — postStart will log a warning and the
> recovery Job handles unsealing from the fallback Vault instead.

## Bootstrap root token

The bootstrap root token is generated by `vault operator init` and is **not persisted**
by this chart. Operators must handle root token custody out-of-band:

- Store securely (e.g. encrypted offline storage)
- Rotate or revoke after completing the initial configuration
- Never commit to version control or leave in pod logs

See `docs/threat-model.md` for full analysis including:
- Fallback Vault compromise scenarios
- Stolen SA token scenarios
- Encryption recommendations
