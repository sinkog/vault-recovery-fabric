# LLM Rules

## A legfontosabb elv

A recovery-plane separation invariáns: **a recovery komponens soha nem függhet attól a Vaulttól,
amit éppen helyre akar állítani.** Ha egy változtatás ezt megsérti, az visszautasítandó.

## Architektúra invariánsok — ne változtasd meg

- KV v2 policy path: `secret/data/vault/unseal-keys` (nem `secret/vault/...`) — ez a Vault API path
- KV CLI path: `vault kv get secret/vault/unseal-keys` — a CLI elfedi a v2 prefix-et
- `vault-0` hostname-alapú feltétel a postStart-ban: ő az egyetlen initiator
- A két sík szétválasztása (normal secret-plane vs. recovery-plane) minden új funkciónál betartandó
- **Helm release neve kötelezően `vault`** — a subchart service nevei ebből képződnek

## Jelenlegi auth modell (nem stale)

- `vault/vault` userpass: **eltávolítva** M3-ban — ne hozd vissza
- Minden auth K8s SA JWT alapú: `vault write auth/kubernetes/login role=<role>`
- Roleok: `vault-unseal` (read, postStart), `vault-recovery-unseal` (read, 5m TTL), `vault-rekey` (read+write+sys/rekey, 10m TTL)
- Root token: nem persistálódik KV-ban, tmp fájlok törlődnek init végén

## KV v2 szabályok

- Policy: mindig `secret/data/...` és `secret/metadata/...`
- CLI: `vault kv get secret/...` (a CLI automatikusan kezeli a v2 prefix-et)
- Schema valide policy írásakor a configmap.yaml-t nézd, ne a CLI path-ot

## Helm szabályok

- Release name: **`vault`** — más release névvel a health check és recovery service nevek eltörnek
- Minden template változtatás után: `helm template vault ./vault -n kube-vault`
- `helm lint` hibát ne hagyj bent
- Upstream chart dependency-t (`.tgz`) ne csomagold ki

## Biztonsági szabályok

- Unseal key-ek és root token: ne jelenjenek meg logban, tmp fájlok törlendők
- Recovery job végén: HTTP health check bizonyítja az unseal sikerét (ne csak "lefutott a parancs")
- `curl -f` tilos HTTP code lekérésnél — `curl -s -o /dev/null -w "%{http_code}"` a helyes minta

## Változtatás előtt

1. Olvasd el: `context.md`, `ai/SYSTEM_CONTEXT.md`
2. KV v2 policy path-nál ellenőrizd a configmap.yaml-t
3. Futtasd: `helm template vault ./vault -n kube-vault`
4. Recovery-plane separation: a változtatás megtöri-e az elvet?
