# Onboarding (AI)

## 1 perc alatt

- **Mi ez:** Vault Recovery Fabric — cross-cluster, vendorfüggetlen Vault recovery orchestration platform
- **Kulcsgondolat:** recovery viselkedés = deployable infrastructure state (nem runbook)
- **Víziós dokumentum:** `context.md` — olvasd el először
- **Upstream dependency:** `hashicorp/vault@0.32.0` / Vault 1.21.2 (Integrated Raft storage, Consul eltávolítva)
- **Alapelv:** recovery-plane separation — a recovery komponens sosem függ azon a Vaulton, amit helyre akar állítani
- **Mérce:** `helm template` hiba nélkül fut, `helm lint` zöld

## Jelenlegi állapot: single-cluster baseline

A repo jelenleg egy single-cluster Vault HA deployment. Ez az M1–M2 mérföldkő szintje.
A multi-cluster recovery mesh (M4) még nincs implementálva.

### Komponens állapot

| Komponens | Állapot | Megjegyzés |
|---|---|---|
| `vault/templates/configmap.yaml` | ✓ működő | vault-unseal policy HCL |
| `vault/values.yaml` postStart | ✓ működő | auto-unseal logika, vault-0 alapú |
| `vault/templates/serviceaccount.yaml` | ✓ működő | |
| `vault/templates/serviceaccount-secret.yaml` | ✓ működő | K8s 1.24+ compat |
| `vault/templates/job.yaml` | ⚠ részleges | nem idempotens, hardkódolt volume, root token logban |
| `vault/templates/rbac.yaml` | ✗ hibás | duplikált ClusterRoleBinding név — P0 |
| `apps/templates/appproject.yaml` | ✗ hibás | hiányzó apiVersion + .Values. prefix — P0 |
| `apps/templates/vault.yaml` | ✗ hibás | hiányzó .Values. prefix — P0 |

## Javítási prioritások

| Prioritás | Feladat | Mérföldkő |
|---|---|---|
| P0 — deploy blocker | rbac duplikált név | M1.1 |
| P0 — ArgoCD blocker | appproject.yaml apiVersion | M1.2 |
| P0 — helm render | .Values. prefix hiánya | M1.3 |
| P1 — portability | hardkódolt volume a job-ban | M2.1 |
| P1 — robusztusság | idempotens init | M2.2 |
| P1 — paraméterezhető | namespace hardkódolás | M2.3 |
| P2 — hardening | vault/vault credential eltávolítása | M3.1 |
| P2 — hardening | root token lifecycle | M3.2 |

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
