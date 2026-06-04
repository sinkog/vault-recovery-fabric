# vault-recovery-fabric — Claude kontextus

## Mi ez a rendszer?

**Nem** egy egyszerű Vault auto-unseal chart.

Ez egy **cross-cluster Vault recovery orchestration platform** — több Vault cluster recovery
viselkedését Helm/Kubernetes alapon deklarált, vendorfüggetlen infrastruktúra-állapotba emeli.

```
Vault-A → recovery fallback: Vault-B
Vault-B → recovery fallback: Vault-C
Vault-C → recovery fallback: Vault-A
```

Teljes outage esetén egy Vault manuális feloldása elegendő — a többi automatikusan visszaáll.

Részletes víziós dokumentum: `context.md`
Architektúra és két réteg szétválasztása: `ai/SYSTEM_CONTEXT.md`
Fejlesztési irányok és hardening lista: `ai/ROADMAP.md`

---

## Jelenlegi állapot vs. cél

| Dimenzió | Állapot |
|---|---|
| Scope | multi-cluster recovery mesh (implementált) |
| Storage backend | Integrated Raft |
| Auth | K8s SA JWT → rövid TTL token (vault/vault eltávolítva) |
| Recovery job | two-phase initContainer + main, per-pod targets |
| Root token | nem persistálódik, tmp fájlok törlődnek |
| Reviewer identity | vault-reviewer SA with system:auth-delegator; Vault 1.21+ uses vault SA projected token for TokenReview (no long-lived Secret needed) |
| Release name | kötelezően `vault` (release name guard a configmap.yaml-ban) |

---

## Repo struktúra

```
apps/        ArgoCD AppProject + Application manifest-ek
vault/       Vault Helm chart wrapper (HashiCorp upstream, v0.32.0 / Vault 1.21.2), Integrated Raft storage
  templates/
    configmap.yaml             vault-unseal policy HCL
    job.yaml                   bootstrap init job (idempotens, Helm post-install hook)
    rbac.yaml                  ClusterRoleBinding-ok (Release.Name alapú nevek, 3 binding)
    serviceaccount.yaml        vault-auth SA
    serviceaccount-secret.yaml vault-auth token secret
context.md   Teljes víziós leírás (fejlesztési háttér, threat model, pozicionálás)
install.sh   helm upgrade -i parancsok
delete.sh    helm uninstall + PVC cleanup
```

---

## Kulcs elvek (context.md alapján)

1. **Recovery-plane separation**: a recovery job SOHA nem függhet attól a Vaulttól, amit helyre akar állítani
2. **Ephemeral access**: nincs fix token, nincs fix jelszó — K8s SA JWT → rövid TTL Vault token
3. **Fallback compromise resistance**: egy fallback Vault kompromittálása önmagában nem elég, kell a célcluster recovery identitása is
4. **Idempotens viselkedés**: minden Job biztonságosan futtatható újra

---

## Mielőtt változtatsz

Olvasd el: `context.md`, `ai/SYSTEM_CONTEXT.md`, `ai/LLM_RULES.md`

```bash
helm template vault ./vault -n kube-vault
```
