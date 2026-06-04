# Onboarding (AI)

## 1 perc alatt

- **Mi ez:** Vault Recovery Fabric — cross-cluster, vendorfüggetlen Vault recovery orchestration platform
- **Kulcsgondolat:** recovery viselkedés = deployable infrastructure state (nem runbook)
- **Víziós dokumentum:** `context.md` — olvasd el először
- **Upstream dependency:** `hashicorp/vault@0.32.0` / Vault 1.21.2 (Integrated Raft storage, Consul eltávolítva)
- **Alapelv:** recovery-plane separation — a recovery komponens sosem függ azon a Vaulton, amit helyre akar állítani
- **Mérce:** `helm template` hiba nélkül fut, `helm lint` zöld

## Jelenlegi állapot (alpha)

Multi-cluster recovery mesh implementálva (M4). Helm release neve kötelezően `vault`.

### Komponens állapot

| Komponens | Állapot | Megjegyzés |
|---|---|---|
| `vault/templates/configmap.yaml` | ✓ | vault-unseal + vault-rekey policy, release name guard |
| `vault/templates/job.yaml` | ✓ | idempotens (HTTP 501 check), reviewer token, policy-before-role |
| `vault/templates/rbac.yaml` | ✓ | Release.Name alapú nevek, 4 binding (vault/auth/recovery/reviewer) |
| `vault/templates/recovery-job.yaml` | ✓ | two-phase, per-pod targets, unseal proof |
| `vault/templates/rekey-job.yaml` | ⚠ alpha | triple gate, külön role, syncFallback flag; nem atomi |
| `vault/templates/networkpolicy.yaml` | ✓ | from selectors, CIDR guard recovery esetén |
| `vault/templates/tests/` | ✓ | health, recovery-auth, mesh-auth tesztek |
| `apps/templates/` | ✓ | ArgoCD Application + AppProject |

## Nyitott kérdések (ismert adósság)

| Kérdés | Státusz |
|---|---|
| Rekey tranzakcionalitás | Nyitott — local/fallback write nem atomi |
| AES-CBC → AEAD (GCM/age) | Roadmap |
| Cross-cluster K8s auth külön mountok | Roadmap |
| bootstrap.autoInit=false production default | Nyitott |

## Ami kész és ne írj felül

- `vault/values.yaml` postStart logika — körültekintően van megírva, csak az egyértelmű hibákat javítsd
- `vault/templates/configmap.yaml` — a policy HCL pontosan a szükséges jogosultságokat adja
- A `context.md` tartalmát — ez a termék víziója és döntési háttere, nem módosítandó implementáció közben

## Hogyan ellenőrzöl

```bash
helm template vault ./vault -n kube-vault
helm template apps ./apps -n argocd -f apps/values.yaml
helm lint ./vault
```
