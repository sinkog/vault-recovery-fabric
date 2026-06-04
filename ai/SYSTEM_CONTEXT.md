# System Context

## Mi ez a rendszer?

A `vault-recovery-fabric` egy **deklaratív Vault recovery control plane**.
Célja, hogy Vault cluster(ek) recovery viselkedése ne emberi runbookokban legyen rögzítve,
hanem telepíthető infrastruktúra-állapotként legyen deklarálva.

```
Vault recovery behavior = deployable infrastructure state
                          (not a human-operated emergency procedure)
```

Bővebb háttér: `context.md`

---

## A két sík — recovery-plane separation

Ez az egész architektúra legfontosabb invariánsa:

```
Normal secret-plane:
  alkalmazások → Vault-A secrets

Recovery-plane:
  recovery Job → Vault-B → Vault-A unseal
```

**A recovery komponens SOHA nem függhet attól a Vaulttól, amit éppen helyre akar állítani.**

Ha Vault-A sealed, a recovery Job Vault-B-ből kér recovery materialt,
és Vault-A `sys/unseal` API-ját hívja — Vault-A-t közben egyáltalán nem kell tudni elérni secretekhez.

---

## Recovery mesh topológia

```
Vault-A  ─(fallback)→  Vault-B  ─(fallback)→  Vault-C  ─(fallback)→  Vault-A
```

- Részleges hiba: az érintett Vault szomszédja recovery forrásként szolgál
- Teljes outage (minden cluster sealed): operátor manuálisan unsealel EGY kijelölt clustert → cascade recovery

---

## Jelenlegi implementáció (single-cluster, baseline)

A repo jelenlegi állapota egy single-cluster Vault HA deployment, Integrated Raft storage-gal,
kétfázisú bootstrap-pel. Consul eltávolítva — `ha.raft.enabled: true` esetén a Vault
Integrated Raft Storage-t használ, service registration-t a `service_registration "kubernetes" {}`
blokk adja, Consul semmilyen szerepet nem tölt be.

### 1. fázis — Init job (első telepítésnél)

`vault/templates/job.yaml` (`vault-wait-job`):

```
vault-0 elérhető → vault operator init → unseal keys + root token
→ vault-0 unseal
→ KV v2 engine enable
→ Kubernetes auth enable + config
→ vault-unseal userpass auth enable
→ vault-unseal policy (configmap-ból)
→ unseal keys → secret/vault/unseal-keys
→ root token → secret/vault/init-token
→ tail -f /dev/null  ← root token kézi kiolvashatósághoz (HARDENING SZÜKSÉGES)
```

**Jelenlegi problémák:**
- nem idempotens (`vault operator init` hibázik ha már init)
- hardkódolt volume név (`kube-api-access-spl6s` — live cluster exportból maradt)
- root token tartósan a KV-ban marad (hardening lista: törlendő)
- `tail -f /dev/null` a végén: szándékos debugolhatóság, de production-ban nem kívánatos

### 2. fázis — Auto-unseal (postStart, minden újrainduláskor)

`vault/values.yaml` `postStart`:

```
Ha vault-0 ÉS vault-active még nem él → skip
Egyébként:
  → HTTP health check vault-active:8200/v1/sys/health (sealed=503 is OK)
  → raft join vault-active-hoz
  → K8s SA JWT → auth/kubernetes/login role=vault-unseal → rövid TTL token
  → kv get secret/vault/unseal-keys → curl PUT /v1/sys/unseal (soronként)
  → ha nincs local unseal key (storeUnsealKeys=false): warning, pod elindul sealed
```

---

## Tervezett recovery Job modell (two-phase)

```
Recovery Job Pod
  → initContainer:
       K8s ServiceAccount JWT
       login fallback Vaultba (Kubernetes auth)
       rövid TTL token (token_num_uses=1 vagy 2)
       bootstrap config → memory emptyDir

  → main container:
       target Vault health/seal check (várakozás)
       fallback Vaultból recovery material lekérés
       target Vault sys/unseal
       ephemeral token/config törlése
       idempotens exit
```

---

## Security modell (threat model)

### Fallback Vault kompromittálása

Ha Vault-B kompromittálódik, önmagában **nem elegendő** Vault-A feloldásához.
A recovery material Vault-A cluster recovery identity-hez (public key) kötött:

```
Vault-B-ben: A recovery material = A-cluster public keyvel védve
Az attacker kell:
  1. Vault-B kompromittálása (tárolt anyag elérése)
  2. Vault-A cluster recovery identity (private key)
```

### Credential lifecycle

```
Implementált védelem (jelenlegi):
  K8s SA JWT → auth/kubernetes/login → TTL=5m, num_uses=2
  passphrase K8s Secret-ben (encryption.enabled=true esetén)

Nem kívánatos (eltávolítva):
  fix vault/vault userpass (M3-ban eltávolítva)
  hosszú életű token
  root token tárolása
  újrahasználható recovery credential

Cél:
  K8s SA JWT → K8s auth → rövid TTL Vault token → egyszeri használat
```

---

## ArgoCD integráció

Az `apps/` chart ArgoCD AppProject + Application manifest-eket tartalmaz.
A `values.yaml` `preRepoURL`-ból és `project` értékből épít fel minden template hivatkozást.

**Ismert bug:** minden `{{ spec.* }}` hivatkozásból hiányzik a `.Values.` prefix — helm render hibát okoz. *(M1-ben javítva)*

---

## Jelenlegi nyitott kérdések

| Dimenzió | Állapot |
|---|---|
| `vault status` exit code handling | ✓ Javítva — HTTP health API |
| userpass/vault/vault credential | ✓ Eltávolítva M3-ban |
| Bootstrap job idempotencia | ✓ HTTP 501 check |
| Recovery Job vault status | ✓ HTTP 503 = sealed OK |
| Cross-cluster K8s auth (külön mountok) | Nyitott — jelenleg egy shared auth/kubernetes mount |
| Reviewer token lifecycle (K8s 1.24+ projected) | Nyitott — production blocker |
| AES-CBC → authenticated encryption | Nyitott — roadmap item |
| Rekey transactional safety | Nyitott — local/fallback nem atomi |
| `vault/templates/job.yaml:28` | nem idempotens init | P1 |
| `vault/values.yaml` postStart | hardkódolt vault/vault credential | P2 — hardening |
| `vault/templates/job.yaml:66` | `tail -f /dev/null` root token | P2 — hardening |
