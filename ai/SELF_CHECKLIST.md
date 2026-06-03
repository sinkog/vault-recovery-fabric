# Self Checklist

## Alapkövetelmények

- [ ] `helm template vault ./vault -n kube-vault` — hiba nélkül lefut
- [ ] `helm template apps ./apps -n argocd -f apps/values.yaml` — hiba nélkül lefut
- [ ] `helm lint ./vault` — warning nélkül zöld
- [ ] Upstream dependency verzió (`Chart.lock`) nem változott véletlenül
- [ ] Titkot nem commit-oltam (token, cert, private key, root token, unseal key)

## Architektúra elvek

- [ ] Recovery-plane separation megőrzött: a recovery job nem függ azon a Vaulton, amit helyre akar állítani
- [ ] Ephemeral access: nem vezettünk be új fix credentialt / hosszú életű tokent
- [ ] Root token: nem marad tartósan elérhető logban vagy KV-ban (production scope esetén)

## Vault / unseal flow

- [ ] A postStart logika és az init job flow konzisztens — ha az egyiket módosítottam, a másikat is ellenőriztem
- [ ] `secret/vault/unseal-keys` path és `contents` mező neve változatlan
- [ ] `vault-unseal` auth path és policy neve változatlan
- [ ] `vault-0` initiator logika megőrzött

## Kubernetes / RBAC

- [ ] ClusterRoleBinding nevek egyediek a clusterben
- [ ] ServiceAccount és ClusterRoleBinding namespace-ek konzisztensek
- [ ] Job-on `backoffLimit` és `ttlSecondsAfterFinished` be van állítva

## ArgoCD

- [ ] Minden `apps/templates/*.yaml`-ban `apiVersion` jelen van
- [ ] Minden template hivatkozás `.Values.` prefix-szel kezdődik
- [ ] `apps/values.yaml`-ban a `preRepoURL` és `project` aktuális

## Helm chart minőség

- [ ] Új values mező → default értéke megvan a `values.yaml`-ban
- [ ] Ha `values.schema.json` létezik: ott is frissítve
- [ ] Upstream dependency verzió (`Chart.lock`) nem változott véletlenül

## Dokumentáció

- [ ] Ha az unseal/recovery flow-t érintette: `ai/SYSTEM_CONTEXT.md` frissítve
- [ ] Ha new fejlesztési irány indult vagy lezárult: `ai/ROADMAP.md` frissítve
- [ ] Ha security modellt érintette: `context.md` 7. fejezete megfontolandó
- [ ] Ha ismert hiba javítva: `ai/ONBOARDING.md` státusz-táblázata frissítve
