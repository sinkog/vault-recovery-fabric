helm uninstall vault -n kube-vault
kubectl -n kube-vault get pvc --no-headers | grep '^data-vault' | awk '{ print $1}' | xargs kubectl delete -n kube-vault pvc
while kubectl get pv | grep "kube-vault/data-vault"; do sleep 1; done > /dev/null
