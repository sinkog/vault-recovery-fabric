# Architecture

## Two planes

The fundamental design principle is **recovery-plane separation**: the component
that recovers a Vault cluster must never depend on the cluster it is recovering.

```
Normal secret-plane:
  Applications ──────────────────────► Vault-A
                                         (sealed?)
Recovery-plane:
  vault-recovery-job ── K8s auth ──► Vault-B (fallback)
         │                                │
         │         unseal-keys-A ◄────────┘
         │
         └──── sys/unseal ──────────────► Vault-A
```

## Recovery mesh

Each cluster has exactly one fallback. The mesh forms a ring:

```
Vault-A ──fallback──► Vault-B
Vault-B ──fallback──► Vault-C
Vault-C ──fallback──► Vault-A
```

Partial failure: the sealed cluster's neighbour provides recovery material.
Full outage: operator manually unseals one cluster (manual seed), the mesh recovers the rest.

## Components

```
vault/
  server (StatefulSet, 3 replicas)
    Integrated Raft storage
    postStart: auto-unseal via K8s auth → local KV (requires bootstrap.storeUnsealKeys=true)
               if no local keys found: logs warning, pod starts sealed
    serviceAccount: vault

  vault-wait-job (init, runs once)
    serviceAccount: vault-recovery
    Initializes vault, configures K8s auth
    Stores unseal keys in KV only if bootstrap.storeUnsealKeys=true

  vault-recovery-job (on-demand, triggered by recovery.triggerId=<unique-event-id>)
    serviceAccount: vault-recovery
    initContainer: K8s auth against fallback vault → short-lived token (Memory emptyDir)
    main: fetch unseal keys → sys/unseal via curl → cleanup

  vault-rekey-job (on-demand, recovery.rekey.enabled=true + confirm=true + experimental=true)
    serviceAccount: vault-recovery
    Rotates unseal keys via vault operator rekey
    Optionally encrypts new keys (AES-256-CBC, openssl)
    Updates local KV and fallback vault

  vault-recovery-unseal (K8s auth role)
    Bound to: vault-recovery SA
    Policy vault-unseal: read secret/data/vault/unseal-keys (KV v2 API path)
    TTL: 5m, token_num_uses: 2

  vault-rekey (K8s auth role)
    Bound to: vault-recovery SA
    Policy vault-rekey: read+write secret/data/vault/unseal-keys + sys/rekey/*
    TTL: 10m, token_num_uses: 3

  vault-unseal (K8s auth role)
    Bound to: vault SA (postStart)
    Policy vault-unseal: read secret/data/vault/unseal-keys (KV v2 API path)
    TTL: 1h

  Note: KV v2 CLI path (secret/vault/...) differs from policy path (secret/data/vault/...)
  The Vault CLI handles this transparently; policies must use the API path.
```

## NetworkPolicy notes

When `recovery.triggerId` is set and `recovery.fallback.cidr` is empty, egress allows
port 8200/443 broadly. **Set `recovery.fallback.cidr` in production** to restrict egress
to the known fallback Vault CIDR range.

## Key invariants

1. **Recovery-plane separation**: vault-recovery-job never touches the local vault's K8s auth
2. **Ephemeral access**: no fixed passwords, K8s SA JWT → short TTL tokens
3. **Memory-only secrets**: emptyDir `medium: Memory` between init and main containers
4. **Idempotent operations**: init job and recovery job exit cleanly if already done
5. **postStart is best-effort**: fails gracefully if no local unseal keys — mesh recovery handles unsealing
