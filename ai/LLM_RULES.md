# LLM Rules

## A legfontosabb elv

A recovery-plane separation invariáns: **a recovery komponens soha nem függhet attól a Vaulttól,
amit éppen helyre akar állítani.** Ha egy változtatás ezt megsérti, az visszautasítandó.

## Architektúra invariánsok — ne változtasd meg

- `secret/vault/unseal-keys` KV path és `contents` mező neve más komponensek hivatkozzák
- `vault-unseal` userpass auth path és policy neve az unseal flow-ban rögzített
- `vault-0` hostname-alapú feltétel a postStart-ban: ő az egyetlen initiator, a többi raft join-ol
- A két sík szétválasztása (normal secret-plane vs. recovery-plane) minden új funkciónál betartandó

## Credential kezelés

- A `vault/vault` hardkódolt bootstrap credential egy ismert adósság — ne vezess be új hardkódolt credentialt
- Ha új auth-t adsz hozzá, az K8s ServiceAccount JWT alapú legyen, nem jelszó alapú
- Root token: soha ne logolj, production module esetén törlendő a KV-ból a bootstrap után
- `ttlSecondsAfterFinished` és `backoffLimit` minden Job-on kötelező

## Helm szabályok

- Minden template változtatás után: `helm template <name> ./<chart> -n kube-vault`
- `helm lint` hibát ne hagyj bent
- Upstream chart dependency-t (`.tgz`) ne csomagold ki — a `charts/` tgz maradjon
- Új values mező → default a `values.yaml`-ban kötelező; ha `values.schema.json` már létezik, ott is

## Kubernetes szabályok

- ClusterRoleBinding nevek egyediek kell legyenek a clusterben
- ServiceAccount token secret K8s 1.24+ alatt nem jön létre automatikusan — explicit secret kell
- NetworkPolicy változtatásnál a recovery-plane → fallback Vault kommunikáció ne kerüljön tiltásra

## Biztonsági szabályok

- Unseal key-ek és root token soha ne jelenjenek meg logban (`set -x` a job scriptben kockázatos)
- Recovery material tárolásánál a célcluster identity-kötés elve betartandó (context.md 7. fejezet)
- `tail -f /dev/null` csak lab módban elfogadható

## Változtatás előtt

1. Olvasd el: `context.md` (víziós háttér), `ai/SYSTEM_CONTEXT.md` (kétfázisú architektúra)
2. Azonosítsd az érintett réteget: init job / postStart / ArgoCD / recovery mesh — különböző életciklus
3. Futtasd: `helm template`
4. Recovery-plane separation: a változtatás megtöri-e az elvet?
