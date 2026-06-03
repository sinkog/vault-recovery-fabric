# Threat Model

## Scope

This threat model covers the vault-recovery-fabric chart in multi-cluster recovery mesh mode.

---

## Assets

| Asset | Location | Sensitivity |
|---|---|---|
| Vault unseal keys | `secret/vault/unseal-keys` (local + fallback KV) | Critical |
| K8s SA token (vault-recovery) | Auto-mounted by K8s | High |
| AES passphrase | K8s Secret `vault-recovery-passphrase` | High |
| Vault root token | generated during bootstrap, not persisted by default | Critical — operator must handle out-of-band |

---

## Threat scenarios

### T1 — Fallback Vault fully compromised

**Scenario**: attacker has full read access to Vault-B, including all KV secrets.

**Without encryption (`recovery.encryption.enabled=false`)**:
- Attacker reads Vault-A's unseal keys from Vault-B's KV
- Attacker can unseal Vault-A
- **Mitigation**: none beyond Vault-B's own auth controls

**With encryption (`recovery.encryption.enabled=true`)**:
- Attacker reads encrypted blob from Vault-B's KV
- Decryption requires the AES passphrase, stored in a K8s Secret in Vault-A's cluster
- Compromise of Vault-B alone is **not sufficient** to unseal Vault-A
- **Residual risk**: if attacker also compromises the Kubernetes API of Vault-A's cluster,
  they can read the passphrase Secret

**Conclusion**: encryption meaningfully raises the bar — two independent compromises
(Vault-B KV + Vault-A K8s API) are required.

### T2 — vault-recovery SA token stolen from Vault-A cluster

**Scenario**: attacker obtains the `vault-recovery` K8s SA token.

- Token can be used to authenticate to Vault-B via K8s auth
- Vault-B returns a short-lived token (TTL=5m, num_uses=2) with read-only access to recovery material
- Attacker reads Vault-A's unseal keys from Vault-B (or encrypted blob)
- **With encryption**: attacker still needs the AES passphrase to decrypt
- **Without encryption**: attacker can unseal Vault-A

**Mitigation**: enable encryption. Monitor `auth/kubernetes/login` events on Vault-B.

### T3 — Kubernetes API server compromised (Vault-A cluster)

**Scenario**: attacker controls Vault-A's K8s API.

- Can read all Secrets, including `vault-recovery-passphrase`
- Can impersonate `vault-recovery` SA
- Full chain to unseal Vault-A is available
- **This is assumed out of scope** — if the K8s API is compromised, all workloads are at risk

### T4 — Network interception (recovery job ↔ fallback vault)

**Scenario**: attacker intercepts traffic between recovery job and Vault-B.

- Recovery job connects to Vault-B over HTTPS (8200)
- Set `recovery.fallback.tlsSkipVerify: false` (default) to enforce TLS validation
- **Do not set `tlsSkipVerify: true` in production**

### T5 — Unseal keys logged

**Scenario**: unseal keys appear in pod logs.

- **Mitigated in M3.3**: `set -x` removed from all job scripts
- Root token echo removed
- Residual risk: `vault operator unseal $key` — the key argument may appear in process list

---

## Recommendations

| Priority | Action |
|---|---|
| Must | Enable `recovery.encryption.enabled=true` in production |
| Must | Delete `secret/vault/init-token` after initial bootstrap |
| Must | Set `recovery.fallback.tlsSkipVerify: false` |
| Should | Enable Vault audit log on all clusters |
| Should | Monitor `auth/kubernetes/login` events on all fallback vaults |
| Should | Rotate passphrase Secret after any suspected exposure |
| Consider | Restrict `vault-recovery-passphrase` Secret with K8s RBAC |
