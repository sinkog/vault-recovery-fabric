# Roadmap

A teljes fejlesztési kontextus: `context.md`

---

## M1 — Deploy-képes baseline (blocker javítások) ✓ KÉSZ

### ~~M1.1~~ ✓ rbac.yaml duplikált ClusterRoleBinding név
- `vault-auth` binding → `role-tokenreview-binding-auth`, namespace `{{ .Release.Namespace }}`

### ~~M1.2~~ ✓ ArgoCD AppProject hiányzó apiVersion
- `apiVersion: argoproj.io/v1alpha1` hozzáadva

### ~~M1.3~~ ✓ Helm template .Values. prefix hiánya
- Minden `{{ spec.* }}` → `{{ .Values.spec.* }}` az `apps/templates/*.yaml`-ban

---

## M2 — Robusztus single-cluster alapréteg ✓ KÉSZ

### ~~M2.0~~ ✓ Consul eltávolítása
- Consul chart és ArgoCD Application eltávolítva

### ~~M2.1~~ ✓ Hardkódolt volume eltávolítása a job-ból
- `kube-api-access-spl6s` projected volume eltávolítva, K8s 1.24+ automatikus SA mount elegendő

### ~~M2.2~~ ✓ Init job idempotencia
- `vault status | grep 'Initialized.*true'` pre-check → már init esetén clean exit
- `ttlSecondsAfterFinished: 600` hozzáadva
- `vault operator init` retry loop egyszerűsítve

### ~~M2.3~~ ✓ Namespace paraméterezhető
- `rbac.yaml` ClusterRoleBinding subject namespace → `{{ .Release.Namespace }}`

---

## M3 — Hardening ✓ KÉSZ

**Referencia:** `context.md` 11. fejezet

### ~~M3.1~~ ✓ Dedikált recovery ServiceAccount
- Külön SA a recovery job-hoz (ne a `vault` SA-t használja, amely az alkalmazásokhoz is kötve van)
- A recovery SA csak a recovery path-hoz szükséges Vault policy-hoz legyen kötve
- Előfeltétele M3.3-nak (policy frissítés az új SA-ra)

### ~~M3.2~~ ✓ Ephemeral credential modell
- userpass (`vault/vault`) eltávolítva postStart-ból és init job-ból
- K8s SA JWT → `auth/kubernetes/login role=vault-unseal` → rövid TTL token
- `vault-recovery-unseal` role: `token_num_uses=2`, `ttl=5m`

### ~~M3.3~~ ✓ Log-tisztítás
- `set -x` eltávolítva — unseal key-ek nem kerülnek podlogba
- `tail -f /dev/null` eltávolítva
- Debug echo-k (`env`, `$VAULT_ADDR`, stb.) eltávolítva
- root token / init-token: KV-ban marad (operátor döntése a törlés), podlogba nem kerül

### ~~M3.4~~ ✓ Minimális Vault policy
- `vault-unseal` policy: csak `secret/vault/unseal-keys` read — megőrizve
- `vault-recovery-unseal` K8s role: `vault-recovery` SA-ra szűkítve
- `vault-unseal` K8s role: `vault` SA-ra szűkítve, `ttl=1h`

### ~~M3.5~~ ✓ values.schema.json
- `vault/values.schema.json` létrehozva

### ~~M3.6~~ ✓ Helm tests
- `vault/templates/tests/vault-test.yaml`: elérhetőség, init, unseal, recovery material

### ~~M3.7~~ ✓ NetworkPolicy baseline (single-cluster)
- `vault-recovery-job`: csak 8200/8201 egress
- `vault-server`: 8200/8201 ingress
- M4-ben kibővítendő cross-cluster forgalommal

---

## M4 — Multi-cluster recovery mesh ✓ KÉSZ

**Referencia:** `context.md` 1–8. fejezet

### ~~M4.1~~ ✓ Recovery mesh topológia chart
- `values.yaml`-ban deklarálható fallback lánc:
  ```yaml
  recovery:
    mesh:
      - name: vault-a
        fallback: vault-b
      - name: vault-b
        fallback: vault-c
      - name: vault-c
        fallback: vault-a
  ```

### ~~M4.2~~ ✓ Cross-cluster Kubernetes auth setup
- Operátori lépések `vault-mesh-setup` ConfigMap-ban dokumentálva
- Nem automatizálható chartból (más cluster K8s API-ja kell)
- Séma: fallback Vault-on policy + K8s auth role a source cluster recovery SA-jához

### ~~M4.3~~ ✓ Two-phase recovery Job
- `initContainer`: K8s SA JWT → fallback Vault K8s auth → token → `emptyDir medium: Memory`
- `main container`: unseal keys fetch → token törlés → `sys/unseal` → keys törlés → idempotens exit
- `recovery.enabled=false` alapból — operátor kapcsolja be helm upgrade-del

### M4.4 — Recovery material védelem (nyitott)
- Jelenlegi állapot: Vault auth chain adja a védelmet (K8s SA + policy), nem kriptográfiai titkosítás
- Vault Transit encrypt körkörös függőséget hoz be (transit = sealed ha vault sealed)
- **`age` encryption** az ajánlott irány — nem igényel futó infrastruktúrát
- Blokkoló: `age` binary nincs a vault image-ben → custom image vagy init container szükséges
- M5 előtt döntés szükséges

### ~~M4.5~~ ✓ Cascade recovery teljes outage esetén
- Manual seed: egy cluster manuális feloldása után a mesh automatikusan helyreáll
- `vault-mesh-setup` ConfigMap tartalmazza a trigger parancsot

---

## M5 — Rekey és rotáció ✓ KÉSZ

**Referencia:** `context.md` 9. fejezet

### ~~M5.1~~ ✓ Rekey workflow
- `vault operator rekey` job template (`recovery.rekey.enabled=true`)
- Konfig: `keyShares`, `keyThreshold`
- Új kulcsok → local KV + fallback vault (ha `recovery.enabled=true`)
- AES-256-CBC encryption opcionálisan (`recovery.encryption.enabled=true`, openssl)
- M4.4 lezárva: passphrase-alapú symmetric encryption (K8s Secret-ből), openssl a vault image-ben

### ~~M5.2~~ ✓ Rotation dokumentáció és drill
- `vault-recovery-drill` ConfigMap: rekey-procedure, recovery-drill, full-outage-recovery, audit-requirements
- Ajánlott rekey frekvencia: 90 naponta
- Audit log elvárások: auth/kubernetes/login, kv read/write, sys/rekey/* események

---

## M6 — Public chart release ✓ KÉSZ

**Referencia:** `context.md` 10–12. fejezet

### ~~M6.1~~ ✓ Pozicionálás és README
- README teljes újraírás: "Declarative recovery-plane for Vault OSS deployments"
- Disclaimer, architecture diagram, quick start, mesh setup, encryption guide, values reference

### ~~M6.2~~ ✓ Helm tests (végső integráció)
- `vault-test-health`: elérhetőség, init, unseal
- `vault-test-recovery-auth`: K8s auth role, token TTL limit ellenőrzés
- `vault-test-mesh-auth`: fallback vault elérhetőség + auth (recovery.enabled esetén)

### ~~M6.3~~ ✓ Lab / mesh / production módok
- `values-lab.yaml`: NetworkPolicy kikapcsolva, 1-of-1 key shares
- `values-mesh.yaml`: cross-cluster template, encryption enabled
- `values-production.yaml`: pod anti-affinity, teljes hardening
- `networkPolicy.enabled` value (lab módban kikapcsolható)

### ~~M6.4~~ ✓ Dokumentáció csomag
- `docs/architecture.md`: ASCII diagram, komponensek, invariánsok
- `docs/threat-model.md`: T1–T5 threat scenarios, prioritált mitigációk
