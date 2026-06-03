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
  Vault-A  ──(fallback)──►  Vault-B
     ▲                          │
     │                    (fallback)
     │                          ▼
  Vault-C  ◄──(fallback)──  Vault-C
```

Partial failure: the sealed cluster's neighbour provides recovery material.
Full outage: operator manually unseals one cluster (manual seed), the mesh recovers the rest.

## Components

```
vault/
  server (StatefulSet, 3 replicas)
    Integrated Raft storage
    postStart: auto-unseal via K8s auth → vault-active
    serviceAccount: vault

  vault-wait-job (init, runs once)
    serviceAccount: vault-recovery
    Initializes vault, configures K8s auth, stores unseal keys in KV

  vault-recovery-job (on-demand, recovery.enabled=true)
    serviceAccount: vault-recovery
    initContainer: K8s auth against fallback vault → short-lived token (Memory emptyDir)
    main: fetch unseal keys → sys/unseal → cleanup

  vault-rekey-job (on-demand, recovery.rekey.enabled=true)
    serviceAccount: vault-recovery
    Rotates unseal keys via vault operator rekey
    Optionally encrypts new keys (AES-256-CBC, openssl)
    Updates local KV and fallback vault

  vault-recovery-unseal (K8s auth role)
    Bound to: vault-recovery SA
    Policy: read secret/vault/unseal-keys
    TTL: 5m, token_num_uses: 2

  vault-unseal (K8s auth role)
    Bound to: vault SA
    Policy: read secret/vault/unseal-keys
    TTL: 1h
```

## Key invariants

1. **Recovery-plane separation**: vault-recovery-job never touches the local vault's K8s auth
2. **Ephemeral access**: no fixed passwords, K8s SA JWT → short TTL tokens
3. **Memory-only secrets**: emptyDir `medium: Memory` between init and main containers
4. **Idempotent operations**: init job and recovery job exit cleanly if already done
