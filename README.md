# vault-recovery-fabric

**Declarative recovery-plane for Vault OSS deployments on Kubernetes.**

> This chart does not replace Vault Enterprise DR replication or KMS/HSM auto-unseal.
> It adds a declarative cross-cluster recovery orchestration layer for Vault OSS deployments.

## What is this?

Vault clusters seal themselves on restart. The standard response is either:
- A cloud KMS (vendor lock-in), or
- An operator following a runbook under pressure

`vault-recovery-fabric` takes a third path: **recovery-as-code**.
The recovery behaviour is declared in the Helm values and deployed as Kubernetes resources.
No cloud dependency. No runbook.

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
  Vault-A  ──(fallback)──►  Vault-B
     ▲                          │
  (fallback)              (fallback)
     │                          ▼
  Vault-C  ◄──(fallback)──  Vault-B
```

See `docs/architecture.md` for component details and invariants.
See `docs/threat-model.md` for security analysis.

## Requirements

- Kubernetes 1.24+
- Helm 3.x
- HashiCorp Vault Helm chart (bundled as dependency)

## Quick Start — Single Cluster

```bash
helm upgrade -i vault ./vault -n kube-vault --create-namespace
```

After install, the init job runs once and:
- Initializes Vault
- Configures Kubernetes auth
- Stores unseal keys in `secret/vault/unseal-keys`
- Configures the `vault-recovery-unseal` K8s auth role

Subsequent pod restarts auto-unseal via the postStart hook using K8s auth.

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

```bash
# On vault-a cluster, copy unseal keys to vault-b
KEYS=$(vault kv get -field=contents secret/vault/unseal-keys)
VAULT_ADDR=<vault-b-addr> vault kv put secret/vault/unseal-keys contents="$KEYS"
```

### 4. Trigger recovery when needed

```bash
helm upgrade vault ./vault -n kube-vault \
  --set recovery.enabled=true \
  --set recovery.fallback.addr=https://vault-b.example.com:8200
```

## Key Rotation (Rekey)

```bash
helm upgrade vault ./vault -n kube-vault \
  --set recovery.rekey.enabled=true

# After completion, reset:
helm upgrade vault ./vault -n kube-vault \
  --set recovery.rekey.enabled=false
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
| `networkPolicy.enabled` | `true` | Deploy NetworkPolicy resources |
| `recovery.enabled` | `false` | Trigger recovery job |
| `recovery.selfName` | `""` | This cluster's name in the mesh |
| `recovery.fallback.addr` | `""` | Fallback Vault API address |
| `recovery.fallback.tlsSkipVerify` | `false` | Skip TLS verification (not for production) |
| `recovery.fallback.cidr` | `""` | Fallback vault CIDR for NetworkPolicy egress |
| `recovery.rekey.enabled` | `false` | Trigger rekey job |
| `recovery.rekey.keyShares` | `5` | Number of new key shares |
| `recovery.rekey.keyThreshold` | `3` | Unseal threshold |
| `recovery.encryption.enabled` | `false` | Encrypt recovery material with AES-256 |
| `recovery.encryption.passphraseSecret` | `""` | K8s Secret name containing `passphrase` key |

## Security

See `docs/threat-model.md` for a full analysis including:
- Fallback Vault compromise scenarios
- Stolen SA token scenarios
- Encryption recommendations
