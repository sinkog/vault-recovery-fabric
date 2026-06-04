# Vault Recovery Fabric – összefoglaló

## 1. Alapgondolat

A cél nem egyszerű Vault auto-unseal kiváltása, hanem egy **több Vault clusterből álló, deklaratív recovery rendszer** kialakítása Kubernetes / Helm alapon.

A rendszer lényege:

```text
Vault-A
  -> saját recovery mechanizmus
  -> fallback: Vault-B

Vault-B
  -> saját recovery mechanizmus
  -> fallback: Vault-C

Vault-C
  -> saját recovery mechanizmus
  -> fallback: Vault-A
```

Ha részleges hiba van, akkor egy másik Vault cluster képes segíteni a sérült / sealed Vault feloldásában.

Ha teljes körkörös halál történik, azaz minden Vault sealed állapotban van, akkor manuálisan elég **egy kijelölt Vaultot** feloldani. Ezután a többi Vault a recovery mesh alapján kaszkádszerűen vissza tud állni.

---

## 2. Miért nem sima auto-unseal?

A klasszikus Vault auto-unseal jellemzően külső KMS / HSM / cloud provider szolgáltatásra épül:

```text
Vault
  -> AWS KMS / Azure Key Vault / GCP KMS / HSM
```

Ez működő és támogatott minta, de vendorfüggőséget hozhat be:

```text
cloud IAM
cloud API
cloud region
cloud pricing
cloud availability
vendor SLA
```

A Vault Recovery Fabric ezzel szemben:

```text
Vault clusterek
  -> egymás recovery forrásai
  -> Kubernetes ServiceAccount alapú azonosítás
  -> Helm chartban deklarált recovery topológia
  -> minimális emberi beavatkozás
```

Ez nem feltétlenül kriptográfiai garanciában magasabb szint, hanem **recovery-orchestration, vendorfüggetlenség és multi-cluster DR szintjén**.

---

## 3. Mi a fő értéke?

A legfontosabb gondolat:

```text
A Vault recovery viselkedése nem emberi runbookban van,
hanem telepíthető infrastruktúra-állapotként van deklarálva.
```

Ez azt jelenti, hogy az operatori fegyelem nagy része kikerül a képletből.

Nem ez történik:

```text
operator tudja, mit kell csinálni
operator jó sorrendben futtat parancsokat
operator nem hibázik stresszhelyzetben
```

Hanem ez:

```text
Helm chart / Job / initContainer / RBAC / policy
  -> eldönti a recovery sorrendet
  -> fallback Vaultból kér recovery anyagot
  -> unsealeli a cél Vaultot
  -> ellenőrzi az állapotot
  -> idempotensen kilép
```

Ez gyakorlatilag **recovery-as-code**.

---

## 4. Recovery-plane és normal secret-plane szétválasztása

Fontos felismerés volt, hogy a recovery komponens **nem függhet attól a Vaulttól, amit éppen helyre akar állítani**.

Rossz minta:

```text
Vault-A sealed
  -> A-ból kellene secret
  -> pod nem indul
  -> nem tud B-ből kulcsot kérni
  -> recovery megakad
```

Jó minta:

```text
Vault-A sealed
  -> recovery Job elindul A clusterben
  -> nem kér semmit Vault-A-ból
  -> Kubernetes ServiceAccount JWT-vel loginol Vault-B-be
  -> Vault-B-ből lekéri A recovery anyagát
  -> meghívja Vault-A sys/unseal API-ját
```

Tehát két külön sík van:

```text
Normal secret-plane:
  alkalmazások -> Vault-A

Recovery-plane:
  recovery Job -> Vault-B -> Vault-A unseal
```

---

## 5. Recovery Job + initContainer modell

A jelenlegi chartban már van külön Job-alapú bootstrap logika. Ezt érdemes továbbfejleszteni úgy, hogy a recovery Job két fázisú legyen:

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

Fontos: az initContainer nem közvetlenül unsealel, hanem előkészíti a recovery művelethez szükséges rövid életű hozzáférést.

A main container már futás közben használja ezt az anyagot, megvárja a cél Vault API-t, majd végrehajtja az unseal műveletet.

---

## 6. Egyszer használatos / rövid életű credential

A recovery pod nem használhat tartós tokent, fix jelszót vagy root tokent.

Javasolt minta:

```text
Kubernetes ServiceAccount JWT
  -> fallback Vault Kubernetes auth
  -> rövid TTL Vault token
  -> token_num_uses alacsony / 1
  -> policy csak adott recovery pathra
```

Alternatív vagy kiegészítő lehetőség:

```text
AppRole SecretID num_uses=1
response wrapping
rövid wrap TTL
rövid token TTL
```

A cél:

```text
nincs fix vault/vault user
nincs hosszú életű token
nincs root token
nincs újrahasználható recovery credential
```

---

## 7. Fallback Vault kompromittálása

Fontos security kérdés:

```text
Mi történik, ha Vault-B kompromittálódik?
```

Ha Vault-B-ben nyersen ott van Vault-A recovery materialja, akkor ez komoly kockázat.

Erősebb modell:

```text
Vault-B kompromittálása önmagában ne legyen elég Vault-A feloldásához.
```

Ehhez a recovery material ne nyersen legyen tárolva, hanem kötődjön a célcluster recovery identitásához.

Elvi minta (célarchitektúra):

```text
Vault-B-ben tárolt A recovery material
  -> A-cluster recovery identity / public key alapján védve  [CÉLARCHITEKTÚRA]
  -> Vault-B csak tárolja
  -> A recovery pod tudja felhasználni
```

Jelenlegi implementáció:

```text
Vault-B-ben tárolt A recovery material
  -> AES-256-CBC titkosítás, passphrase a target cluster K8s Secret-jében
  -> Fallback Vault compromise + target K8s passphrase Secret szükséges
```

Security narratíva (jelenlegi, encryption.enabled=true esetén):

```text
Fallback Vault compromise alone is not sufficient.
The attacker also needs the AES passphrase Secret from the target cluster.
```

Célarchitektúra (roadmap):

```text
age / SOPS / Vault Transit envelope encryption
per-cluster public-key based recovery identity
```

Magyarul:

```text
Egy fallback Vault kompromittálása önmagában nem elég.
Kell hozzá a célcluster recovery identitása is.
```

Ez nagyon fontos különbség.

---

## 8. Full outage recovery

Ha minden Vault sealed állapotba kerül:

```text
Vault-A sealed
Vault-B sealed
Vault-C sealed
```

akkor nincs aktív recovery forrás.

Ebben az esetben nincs varázslás:

```text
1. operátor manuálisan unsealel egy kijelölt Vaultot
2. ez lesz a manual seed
3. a többi Vault a recovery fabric alapján automatikusan visszaáll
```

Ez azt jelenti, hogy teljes összeomlás esetén sem kell minden Vault clustert kézzel feloldani. Elég egyet, utána a mesh dolgozik.

---

## 9. Rekey / rotáció

Az unseal kulcsok nem feltétlenül örökké változatlanok. Vaultban van `operator rekey`, amellyel új unseal key share-ek generálhatók.

Recovery mesh esetén a rotáció kontrollált folyamat:

```text
1. Vault-A rekey
2. új recovery material előáll
3. új material védése / titkosítása A recovery identityhez
4. feltöltés fallback Vaultokba
5. régi material törlése
6. recovery drill
```

Ez nem napi rotációs folyamat, hanem ritka, auditált, kontrollált lifecycle esemény.

---

## 10. Public chart pozicionálás

Nem így kell pozicionálni:

```text
Vault auto-unseal replacement
```

Hanem így:

```text
Vault Recovery Fabric
Vendor-neutral cross-cluster recovery orchestration for Vault on Kubernetes
```

Vagy:

```text
Declarative recovery-plane for Vault OSS deployments
```

Fontos README mondat:

```text
This chart does not replace Vault Enterprise DR replication or KMS/HSM auto-unseal.
It adds a declarative cross-cluster recovery orchestration layer for Vault OSS deployments.
```

Magyarul:

```text
Ez nem a Vault Enterprise DR replication és nem a KMS/HSM auto-unseal 1:1 kiváltása.
Ez egy deklarált, több clusteres recovery orchestration réteg Vault OSS köré.
```

---

## 11. Amit public release előtt rendbe kell tenni

Kötelező hardening pontok:

```text
- root token logolás teljes tiltása
- unseal key logolás teljes tiltása
- fix vault/vault user eltávolítása
- hardcoded namespace megszüntetése
- root token tartós KV tárolásának tiltása
- idempotens init/recovery logika
- dedikált recovery ServiceAccount
- minimális Vault policy
- NetworkPolicy minták
- values.schema.json
- Helm tests
- audit log dokumentáció
- rekey / rotation flow dokumentáció
- full-outage drill dokumentáció
- lab / mesh / production-like módok szétválasztása
```

---

## 12. Várható közösségi reakció

Első reakció security oldalról valószínűleg kritikus lesz:

```text
Unseal material Vaultban?
Ez anti-pattern?
Mi a threat model?
Mi történik fallback Vault kompromittálásnál?
Miért nem KMS/HSM?
```

Ez várható és normális.

Ha viszont a modell jól van dokumentálva, akkor a komolyabb infra/security emberek látni fogják, hogy ez nem egyszerű self-unseal hack, hanem:

```text
cross-cluster recovery orchestration
recovery-plane separation
least privilege
ephemeral access
manual seed + cascade recovery
vendor-neutral design
```

A legerősebb üzenet:

```text
Vault recovery behavior can be modeled as deployable infrastructure state,
not as a human-operated emergency procedure.
```

---

## 13. Szakmai szint

Ez nem sima Helm chart wrapper.

Szint szerint:

```text
HashiCorp Vault chart values módosítás:
  medior DevOps

Vault HA + bootstrap Job:
  erős medior / senior

Cross-Vault Recovery Mesh:
  senior / staff engineer szint

Public, dokumentált, tesztelt, hardenelt Recovery Fabric chart:
  staff / principal irány
```

A koncepció szintje kb.:

```text
8.5 / 10
```

Ha jól implementált, dokumentált, tesztelt és publikálható chart lesz belőle:

```text
9 / 10 környéke
```

Nem azért, mert mindenre kész válasz, hanem mert a problémafelvetés és a rendszertervezési szint magas.

---

## 14. Rövid végső megfogalmazás

A Vault Recovery Fabric célja:

```text
Több Vault cluster recovery viselkedését Helm/Kubernetes alapon deklarált,
vendorfüggetlen infrastruktúra-állapottá emelni.
```

A fő érték:

```text
- kevesebb emberi recovery hiba
- kevesebb vendor lock-in
- több clusteres DR-gondolkodás
- recovery-plane és normal secret-plane szétválasztása
- egyszer használatos / rövid életű hozzáférés
- manual seed után automatikus cascade recovery
```

Ez nem “egy Vault chart”.

Ez egy:

```text
secret infrastructure recovery control plane
```
