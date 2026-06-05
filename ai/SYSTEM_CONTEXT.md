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

### 1. fázis — Bootstrap job (post-install/upgrade, mindig fut)

`vault/templates/job.yaml` (`vault-wait-job`, Helm post-install/post-upgrade hook):

Két logikai fázis egy jobon belül:

**Phase 1 — Init (csak ha Vault még nem initialized):**
```
vault operator init → vault-0 unseal (wget /v1/sys/unseal) → root token /tmp-be
```

**Phase 2 — Post-config (minden install/upgrade-on fut):**
```
vault-active nc wait
→ ha FRESH_INIT=false: K8s auth login role=vault-bootstrap → token
→ secret/ KV v2 enable (idempotens)
→ Kubernetes auth enable + config (token_reviewer_jwt: vault-reviewer secret)
→ policy write (vault-unseal, vault-rekey, vault-bootstrap) — fail-fast
→ K8s auth role write (vault-unseal, vault-recovery-unseal, vault-rekey, vault-bootstrap) — fail-fast
→ ha FRESH_INIT=true: secret/vault/unseal-keys KV store (opcionális, encryption-aware)
→ tmp fájlok törlése
```

**Jelenlegi állapot:** idempotens post-config, root token nem persistálódik, upgrade-en vault-bootstrap role-lal re-autentikál

### 2. fázis — Auto-unseal (postStart, minden újrainduláskor)

`vault/values.yaml` `postStart` + `extraInitContainers`:

```
initContainer (recovery-prep):
  vault-0: ha vault-active nem él → exit 0 (bootstrap job kezeli)
  vault-1/2: nc-z wait vault-active TCP-re
  → vault-recovery-token secret JWT → auth/kubernetes/login role=vault-recovery-unseal
  → token + vault-url + secret-path → emptyDir (Memory)

postStart (configmap-poststart.yaml):
  → emptyDir olvasás (vault-url, token, secret-path)
  → nc-z wait vault-active TCP
  → vault-1/2: raft join vault-active-hoz
  → vault kv get (encrypted esetén: base64 -d | openssl dec) → unseal keys
  → wget PUT /v1/sys/unseal soronként
  → status retry 10s → unsealed successfully vagy log + exit 0
```

**Auth:** vault-recovery SA long-lived token Secret (`vault-recovery-token`) — szükséges workaround, mert a pod SA (`vault`) ≠ vault-recovery SA. Lásd nyitott adósság.

---

## Recovery Job modell (implementált, two-phase)

```
Recovery Job Pod (triggerId-alapú név, Helm post-upgrade hook)
  → initContainer:
       fallback Vault HTTP health check
       K8s SA JWT → auth/kubernetes/login role=vault-recovery-unseal
       rövid TTL token (5m, num_uses=2) → memory emptyDir

  → main container:
       recovery material fetch fallback Vaultból
       per-pod unseal: recovery.targets listán végigmegy
         (vault-0..N.vault-internal:8200, nem vault-active!)
         sealed (503) → unseal; unsealed (200/429) → skip; unreachable → log
       végső proof: legalább 1 target unsealed, különben exit 1
       fallback Vaultból recovery material lekérés
       target Vault sys/unseal
       ephemeral token/config törlése
       idempotens exit
```

---

## Security modell (threat model)

### Fallback Vault kompromittálása

**Jelenlegi implementáció (passphrase-alapú, encryption.enabled=true esetén):**

Ha Vault-B kompromittálódik, önmagában nem elég Vault-A feloldásához — de csak akkor,
ha a recovery passphrase egy külön compromise domainben van tárolva.

```
Attacker kell:
  1. Vault-B kompromittálása (titkosított blob elérése)
  2. Vault-A cluster K8s Secretje (vault-recovery-passphrase)
```

**Célarchitektúra (roadmap, még nem implementált):**

Per-cluster public-key alapú védelem, ahol a fallback Vault csak a cél cluster
public key-ével titkosított anyagot tárolja. Ehhez age / SOPS / Vault Transit envelope
encryption szükséges — a jelenlegi AES-256-CBC passphrase modell ezt nem nyújtja.

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

## Jelenlegi nyitott kérdések (ismert adósság)

| Dimenzió | Állapot |
|---|---|
| Rekey transactional safety | Nyitott — local/fallback write nem atomi; split-brain runbook szükséges |
| AES-CBC → authenticated encryption (GCM/age/SOPS) | Roadmap |
| bootstrap.autoInit=false production default | Nyitott |
| Recovery successPolicy (any / quorum / all) | Nyitott — jelenleg: legalább 1 siker |
| vault-recovery long-lived SA token | Tudatos workaround (pod SA ≠ recovery SA); rotáció/projected token jövőbeli hardening |
| vault-bootstrap role migration (pre-bootstrap verzióról upgrade) | Manuális egyszeri lépés szükséges; NOTES.txt dokumentálja |

## Lezárt / régi adósság (ne hozd vissza)

A következők már **nem érvényesek** a jelenlegi chartra:

| Régi probléma | Lezárás |
|---|---|
| vault/vault hardkódolt userpass | M3-ban eltávolítva |
| nem idempotens init job | Phase 1/2 szétválasztás; post-config upgrade-en is fut |
| `tail -f /dev/null` root token | eltávolítva M3-ban |
| hardkódolt kube-api-access volume | eltávolítva M2-ben |
| root token KV-ban marad | nem persistálódik, tmp fájlok törlődnek |
| duplikált ClusterRoleBinding | M1-ben javítva, Release.Name alapú nevek |
| shared auth/kubernetes mount mesh-ben | javítva — cluster-specifikus path (k8sAuthPath) |
| tlsSkipVerify precheck előtt | javítva — script elején exportálódik |
| recovery-job token path hiányzott | javítva — vault-recovery-token explicit mount |
| encrypted rekey current keys nem decryptált | javítva — base64 -d + openssl dec |
| vault-unseal policy preflight hiányzott | javítva — sys/internal/ui/mounts/secret/* |
| sleep 3600 Helm hook timeout | eltávolítva |
