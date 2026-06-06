> **ARCHIVED / HISTORICAL — DO NOT USE AS CURRENT IMPLEMENTATION CONTEXT**
> Ez a fájl az eredeti tervezési dokumentum. A jelenlegi chart állapotát az `ai/SYSTEM_CONTEXT.md`,
> `ai/ONBOARDING.md` és `ai/ROADMAP.md` írja le. Ez a fájl csak fejlesztéstörténeti referencia.

# Vault Recovery Fabric – megvalósítási terv a jelenlegi chart átalakításához

## 1. Kiindulási állapot

A jelenlegi chart egy saját wrapper chart a HashiCorp Vault Helm chart körül.

A chart fő elemei:

```text
vault-0.1.0
  -> dependency: hashicorp/vault 0.28.0
  -> templates:
     - job.yaml
     - configmap.yaml
     - rbac.yaml
     - serviceaccount.yaml
     - serviceaccount-secret.yaml
  -> values.yaml:
     - Vault HA Raft bekapcsolva
     - postStart script follower node-okhoz
```

A jelenlegi működés lényege:

```text
vault-wait-job
  -> megvárja vault-0 API-t
  -> vault operator init
  -> unsealeli vault-0-t
  -> engedélyezi KV-t
  -> engedélyezi Kubernetes auth-ot
  -> engedélyezi userpass auth-ot
  -> létrehoz vault/vault usert
  -> eltárolja az unseal kulcsokat Vault KV-ben
  -> eltárolja az init root tokent Vault KV-ben

postStart script
  -> vault-1 / vault-2 joinol vault-active-hoz
  -> vault/vault userrel loginol
  -> kiolvassa az unseal kulcsokat
  -> lokálisan unsealeli magát
```

Ez PoC szinten működőképes, de public / production-like irányhoz hardening és architekturális tisztítás kell.

---

## 2. Célállapot

A cél nem sima auto-unseal kiváltás, hanem egy **Vault Recovery Fabric** kialakítása.

A végső cél:

```text
Vault-A
  -> saját bootstrap/recovery
  -> fallback Vault-B

Vault-B
  -> saját bootstrap/recovery
  -> fallback Vault-C

Vault-C
  -> saját bootstrap/recovery
  -> fallback Vault-A
```

Részleges hiba esetén:

```text
Vault-A sealed
  -> Vault-A recovery Job elindul
  -> Kubernetes ServiceAccount JWT-vel loginol Vault-B-be
  -> Vault-B-ből lekéri Vault-A recovery materialját
  -> unsealeli Vault-A-t
```

Teljes outage esetén:

```text
Vault-A sealed
Vault-B sealed
Vault-C sealed

operator manuálisan unsealel egy kijelölt Vaultot
  -> ez lesz a seed
  -> a többi Vault a recovery fabric alapján kaszkádosan visszaáll
```

A rendszer fő állítása:

```text
Vault recovery behavior is deployable infrastructure state,
not a human-operated emergency runbook.
```

---

## 3. Fő architekturális változás

A jelenlegi chartban a recovery és bootstrap logika egyetlen `vault-wait-job` scriptbe van sűrítve.

Ezt szét kell bontani több külön szerepre:

```text
1. bootstrapJob
   -> első inicializálás
   -> első unseal
   -> alap policy/auth bootstrap

2. recoveryJob
   -> sealed állapotból recovery
   -> cross-vault fallback
   -> egyszer használatos/rövid TTL credential
   -> target Vault unseal

3. followerJoin
   -> raft join
   -> follower node-ok feloldása
   -> lehetőleg ne postStart userpass hackkel

4. policyBootstrap
   -> Vault policy-k telepítése
   -> Kubernetes auth role-ok létrehozása

5. recoveryProvider
   -> más Vault clusterek számára recovery material szolgáltatása
```

---

## 4. Jelenlegi problémák, amelyeket javítani kell

### 4.1 Root token és unseal kulcs logolása

Jelenleg a job scriptben szerepel:

```sh
cat /tmp/keys.txt
cat /tmp/vault-unseal.txt
cat /tmp/vault-token.txt
```

Ez public chartban nem maradhat.

Javítás:

```text
- sem root token
- sem unseal key
- sem raw Vault response
nem kerülhet stdout/stderr logba
```

Helyette:

```sh
echo "Vault init completed"
echo "Unseal material extracted"
echo "Bootstrap policy applied"
```

---

### 4.2 Fix vault/vault user

Jelenleg:

```sh
vault write auth/vault-unseal/users/vault \
  password=vault \
  policies=vault-unseal
```

Ez public / production-like chartban nem vállalható.

Javítás:

```text
- userpass alapú vault/vault eltávolítása
- helyette Kubernetes auth / AppRole / recovery token flow
- alapértelmezésben nincs fix credential
```

---

### 4.3 Root token KV-ben tárolása

Jelenleg:

```sh
vault kv put secret/vault/init-token contents=@/tmp/vault-token.txt
```

Ez public chartban alapból tiltott legyen.

Javítás:

```yaml
bootstrap:
  storeRootToken: false
```

Ha lab módban mégis engedélyezhető, akkor explicit veszélyes flag alatt:

```yaml
dangerousLabMode:
  enabled: true
  storeRootToken: true
```

Alapértelmezés:

```text
root token nem kerül KV-be
root token nem kerül logba
root token init után revoke-olható / csak bootstrap ideig használható
```

---

### 4.4 Hardcoded namespace

Jelenlegi `rbac.yaml`:

```yaml
subjects:
  - kind: ServiceAccount
    name: vault
    namespace: kube-vault
```

Ez hibás public chartban.

Javítás:

```yaml
namespace: {{ .Release.Namespace }}
```

Vagy values-ból:

```yaml
rbac:
  namespaceOverride: ""
```

---

### 4.5 Duplikált ClusterRoleBinding név

Jelenleg két `ClusterRoleBinding` azonos névvel szerepel:

```yaml
metadata:
  name: role-tokenreview-binding
```

Ez ütközés.

Javítás:

```yaml
metadata:
  name: {{ include "vault.fullname" . }}-tokenreview-vault
```

és:

```yaml
metadata:
  name: {{ include "vault.fullname" . }}-tokenreview-vault-auth
```

Továbbá YAML dokumentum szeparátor kell:

```yaml
---
```

---

### 4.6 Nem idempotens init logika

Jelenleg:

```sh
while ! vault operator init && echo "init finish"; do sleep 1; done > /tmp/keys.txt
```

Ha a Vault már inicializált, ez hibás / beragadhat.

Javítás:

```sh
if vault status -format=json | jq -e '.initialized == true'; then
  echo "Vault already initialized"
  exit 0
fi
```

A job legyen idempotens:

```text
ha initialized=true:
  -> ne fusson operator init

ha sealed=false:
  -> ne fusson unseal

ha policy már létezik:
  -> frissítse vagy hagyja változatlanul

ha auth mount már létezik:
  -> ne hibázzon
```

---

### 4.7 `tail -f /dev/null` eltávolítása

Jelenleg a job végén:

```sh
tail -f /dev/null
```

Ez nem valódi Job viselkedés.

Javítás:

```text
Job sikeres bootstrap után exit 0-val kilép.
```

---

## 5. Új values.yaml struktúra

Javasolt új struktúra:

```yaml
vault:
  server:
    ha:
      enabled: true
      raft:
        enabled: true

bootstrap:
  enabled: true
  mode: init-primary
  storeRootToken: false
  store:
    k8sSecret:
      enabled: false
  debugOutput: false

recoveryFabric:
  enabled: false

  localVault:
    name: vault-a
    address: http://vault-active:8200
    internalAddress: http://vault-0.vault-internal:8200

  recoveryJob:
    enabled: true
    serviceAccount:
      create: true
      name: vault-recovery
    useVaultSecrets: false
    tokenTtl: 120s
    tokenNumUses: 1

  fallbackVaults:
    - name: vault-b
      address: https://vault-b.example.internal:8200
      auth:
        method: kubernetes
        mount: kubernetes-a
        role: vault-a-recovery
      recoveryPath: secret/data/recovery/vault-a/unseal
      priority: 10

  fullOutage:
    manualSeedRequired: true
    seedVaultHint: vault-a

dangerousLabMode:
  enabled: false
  fixedUserpass: false
  logSensitiveMaterial: false
  storeRootToken: false
  storeRawUnsealKeys: false
```

Alapelv:

```text
veszélyes működés csak explicit lab módban kapcsolható
production-like default biztonságosabb
```

---

## 6. Recovery Job új modellje

A recovery Job legyen kétfázisú:

```text
Recovery Job Pod
  -> initContainer:
       Kubernetes ServiceAccount JWT
       login fallback Vaultba
       egyszer használatos / rövid TTL credential
       bootstrap config átadása memory emptyDir-en

  -> main container:
       target Vault health/seal check
       fallback Vaultból recovery material lekérés
       target Vault sys/unseal
       token/config törlés
       exit
```

### 6.1 InitContainer feladata

Az initContainer nem unsealel közvetlenül.

Feladata:

```text
- ServiceAccount JWT beolvasása
- fallback Vault kiválasztása
- login fallback Vaultba Kubernetes auth-tal
- rövid TTL / egyszer használatos token lekérése
- token és fallback URL átadása memory emptyDir-en
```

Példa elvi flow:

```sh
SA_JWT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

B_TOKEN="$(
  vault write -field=token auth/kubernetes-a/login \
    role=vault-a-recovery \
    jwt="$SA_JWT"
)"

printf "%s" "$B_TOKEN" > /bootstrap/fallback-token
printf "%s" "$FALLBACK_VAULT_ADDR" > /bootstrap/fallback-url
printf "%s" "$TARGET_VAULT_ADDR" > /bootstrap/target-url

chmod 0400 /bootstrap/*
```

Fontos:

```yaml
volumes:
  - name: recovery-bootstrap
    emptyDir:
      medium: Memory
```

---

### 6.2 Main container feladata

A main container végzi az unseal műveletet:

```text
- beolvassa az initContainer által átadott tokent/configot
- megnézi, hogy a cél Vault sealed-e
- ha nem sealed, exit 0
- ha sealed, fallback Vaultból recovery materialt kér
- meghívja a target Vault /v1/sys/unseal API-t
- ellenőrzi az állapotot
- törli a bootstrap fájlokat
- exit 0
```

Fontos idempotencia:

```text
ha Vault már unsealed:
  -> ne kérjen recovery materialt
  -> exit 0

ha fallback Vault nem elérhető:
  -> próbálja a következőt
  -> ha nincs több fallback, exit 1

ha részleges unseal történt:
  -> seal-status alapján folytassa vagy hibázzon kontrolláltan
```

---

## 7. Recovery ServiceAccount modell

Ne a normál Vault pod ServiceAccount legyen a recovery identitás.

Javasolt szétválasztás:

```text
vault-server
  -> Vault server futtatás

vault-bootstrap
  -> első init/bootstrap

vault-recovery
  -> fallback Vault recovery hozzáférés
```

Public chart default:

```yaml
recoveryFabric:
  recoveryJob:
    serviceAccount:
      create: true
      name: vault-recovery
```

Fallback Vault oldalon a Kubernetes auth role:

```text
bound_service_account_names = vault-recovery
bound_service_account_namespaces = <release namespace>
policy = vault-a-recovery
token_ttl = 120s
token_max_ttl = 300s
token_num_uses = 1 vagy alacsony
```

---

## 8. Vault policy modell

A recovery policy minimális legyen.

Példa:

```hcl
path "secret/data/recovery/vault-a/unseal" {
  capabilities = ["read"]
}
```

Nem engedhető:

```text
secret/*
sys/*
auth/*
root token
policy write
token create általánosan
```

A cél:

```text
Vault-A recovery Job csak Vault-A recovery materialját tudja kérni.
Vault-B recovery Job csak Vault-B recovery materialját tudja kérni.
```

---

## 9. Fallback Vault kompromittálás elleni védelem

A következő szintű cél:

```text
Fallback Vault compromise alone must not be sufficient to recover another Vault.
```

Magyarul:

```text
Egy fallback Vault kompromittálása önmagában ne legyen elég egy másik Vault feloldásához.
```

Ehhez a recovery material ne nyersen legyen tárolva.

Lehetséges minta:

```text
Vault-B-ben tárolt Vault-A recovery material
  -> A-cluster recovery identityhez kötve
  -> A recovery pod tudja felhasználni
  -> Vault-B önmagában csak tároló
```

Implementációs lehetőségek:

```text
1. target cluster public key alapú titkosítás
2. age/sops jellegű envelope encryption
3. Vault transit alapú becsomagolás
4. response wrapping + rövid TTL + target identity ellenőrzés
```

Első public verzióban lehet két mód:

```yaml
recoveryMaterial:
  storageMode: raw-lab | encrypted
```

Default:

```yaml
recoveryMaterial:
  storageMode: encrypted
```

Lab módban explicit engedélyezhető a nyers tárolás.

---

## 10. Rekey / rotációs flow

A recovery material életciklusát dokumentálni kell.

Flow:

```text
1. Vault-A operator rekey
2. új unseal share-ek előállnak
3. új recovery material becsomagolása / titkosítása
4. feltöltés fallback Vault-B / Vault-C pathokra
5. régi recovery material törlése
6. recovery test
7. audit ellenőrzés
```

Chart szinten későbbi cél lehet:

```yaml
rekeyJob:
  enabled: false
```

Első verzióban elég dokumentált manuális rekey flow.

---

## 11. Follower node-ok kezelése

Jelenleg follower node-ok `postStart` scriptből joinolnak és unsealelnek:

```text
postStart
  -> raft join
  -> userpass login
  -> kulcs lekérés
  -> local unseal
```

Ezt tisztítani kell.

Javasolt irány:

```text
1. userpass eltávolítása
2. follower join külön scriptbe / ConfigMapbe
3. follower unseal recovery Job vagy watcher alapján
4. ha marad postStart, ne használjon fix credentialt
```

Középtávon:

```text
followerJoinJob
  -> megvárja primary active állapotát
  -> joinoltatja a follower node-okat
  -> recovery mechanizmus alapján unsealeli őket
```

Vagy:

```text
recoveryJob targetként képes legyen:
  - vault-0
  - vault-1
  - vault-2
kezelésére is
```

---

## 12. NetworkPolicy

A recovery komponens hálózati elérését szűkíteni kell.

Recovery Job csak ezeket érje el:

```text
- target Vault service
- fallback Vault service/address
- Kubernetes API, ha szükséges
```

Nem kell általános egress.

Javasolt values:

```yaml
networkPolicy:
  enabled: true
  recoveryJob:
    allowFallbackVaults: true
    allowTargetVault: true
    allowKubernetesApi: true
    denyOtherEgress: true
```

---

## 13. Audit

Dokumentálni kell, hogy a fallback Vaultban auditálható legyen:

```text
- Kubernetes auth login
- recovery path read
- token create
- token revoke / expiry
- sikertelen recovery próbálkozás
```

A chart adhat audit enable mintát, de óvatosan:

```yaml
audit:
  enabled: false
  example:
    file: true
    socket: false
```

Public chartban inkább dokumentációként legyen, ne automatikus kötelező audit backendként.

---

## 14. Helm tests

Legalább alap Helm testek legyenek:

```text
helm test:
  - Vault podok futnak
  - Vault initialized
  - Vault unsealed
  - Raft peers egészségesek
  - recovery ServiceAccount létezik
  - recovery Job dry-run config valid
  - fallback Vault config jelen van
```

Későbbi haladó tesztek:

```text
- sealed állapot szimuláció
- recovery Job futtatása
- idempotencia teszt
- already-unsealed exit 0
- fallback unavailable eset
```

---

## 15. values.schema.json

Public chartban kell `values.schema.json`.

Ezzel megfogható:

```text
- dangerousLabMode csak boolean
- token TTL formátum
- fallbackVaults kötelező mezők
- recoveryPath nem lehet üres
- serviceAccount név valid
- storageMode csak enum
- production-like módban tilos logSensitiveMaterial=true
```

Példa szabály:

```text
ha recoveryFabric.enabled=true:
  fallbackVaults legalább 1 elem

ha dangerousLabMode.enabled=false:
  storeRootToken=false
  logSensitiveMaterial=false
  fixedUserpass=false
```

---

## 16. Public módok

A chart több üzemmódot kapjon.

### 16.1 lab

```yaml
mode: lab
```

Cél:

```text
gyors PoC
egy cluster
önbootstrap
nem production
explicit warning
```

### 16.2 mesh

```yaml
mode: mesh
```

Cél:

```text
több Vault cluster
cross-vault fallback
recovery Job
dedikált SA
rövid TTL token
```

### 16.3 production-like

```yaml
mode: production-like
```

Cél:

```text
nincs root token tárolás
nincs raw unseal logging
nincs fix credential
NetworkPolicy ajánlott
values.schema szigorú
audit dokumentált
```

---

## 17. README kötelező részei

A public README elején legyen világos disclaimer:

```text
This chart does not replace Vault Enterprise DR replication or KMS/HSM auto-unseal.
It implements a vendor-neutral, declarative, cross-cluster recovery orchestration pattern for Vault OSS deployments.
```

Legyen külön:

```text
- Threat model
- Non-goals
- Architecture diagram
- Recovery flow
- Full outage flow
- Fallback Vault compromise analysis
- Rekey / rotation flow
- Security hardening checklist
- Lab mode warning
```

---

## 18. Implementációs lépések

### Phase 1 – Chart cleanup

```text
- root token / unseal key logolás eltávolítása
- fixed vault/vault user eltávolítása vagy lab flag alá tétele
- hardcoded namespace javítása
- duplikált ClusterRoleBinding javítása
- tail -f /dev/null eltávolítása
- init idempotenssé tétele
```

### Phase 2 – Role separation

```text
- vault-server SA
- vault-bootstrap SA
- vault-recovery SA
- külön RBAC template-ek
- külön Vault policy-k
```

### Phase 3 – Recovery Job v1

```text
- recoveryJob template hozzáadása
- initContainer + memory emptyDir
- fallback Vault Kubernetes auth login
- main container target Vault unseal
- already-unsealed exit 0
- fallback unavailable handling
```

### Phase 4 – Recovery Fabric values

```text
- recoveryFabric.enabled
- localVault
- fallbackVaults
- token TTL/numUses
- recoveryPath
- serviceAccount config
```

### Phase 5 – Security hardening

```text
- raw recovery material tiltása production-like módban
- encrypted recovery material mód
- NetworkPolicy
- values.schema.json
- no-sensitive-log enforcement
```

### Phase 6 – Tests and docs

```text
- Helm tests
- README
- threat model
- full outage drill
- rekey flow
- public release notes
```

---

## 19. Javasolt végső chart szerkezet

```text
templates/
  _helpers.tpl

  rbac/
    server-serviceaccount.yaml
    bootstrap-serviceaccount.yaml
    recovery-serviceaccount.yaml
    tokenreview-bindings.yaml

  bootstrap/
    bootstrap-job.yaml
    bootstrap-configmap.yaml

  recovery/
    recovery-job.yaml
    recovery-configmap.yaml
    recovery-policy-configmap.yaml
    networkpolicy.yaml

  provider/
    recovery-provider-policy.yaml
    recovery-provider-authrole.yaml

  tests/
    test-vault-status.yaml
    test-recovery-config.yaml
```

---

## 20. Végső célmondat

A chart végső értéke:

```text
A Vault recovery viselkedését nem emberi runbookként,
hanem Kubernetes/Helm által telepíthető deklarált infrastruktúra-állapotként kezeli.
```

Rövid név:

```text
Vault Recovery Fabric
```

Pozicionálás:

```text
Vendor-neutral cross-cluster recovery orchestration for Vault on Kubernetes.
```

Ez nem egyszerű Vault Helm wrapper, hanem egy recovery-plane kezdemény Vault OSS köré.
