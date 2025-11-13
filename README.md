# ArgoCD-GitOps
GitOps Argocd repo 

## Install Argo CD (manifests)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

## Install Argo CD CLI (Linux arm64)

```bash
VERSION=$(curl -L -s https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
curl -sSL -o argocd-linux-arm64 https://github.com/argoproj/argo-cd/releases/download/v$VERSION/argocd-linux-arm64
chmod +x argocd-linux-arm64
sudo mv argocd-linux-arm64 /usr/local/bin/argocd
argocd version
argocd version --client
```

## Argo CD CLI login

```bash
argocd login <url-of-argocd> --username <username> --password <password> --grpc-web --insecure
```

## Get Argo CD user info

```bash
argocd account get-user-info
```

## Connect kubeadm cluster to Argo CD

1. View available kubeconfig contexts and note the exact context name to use:

```bash
kubectl config get-contexts
```

2. Add the cluster to Argo CD using the correct context name. For kubeadm, this is often `kubernetes-admin@kubernetes`:

```bash
argocd cluster add "kubernetes-admin@kubernetes" --name argocd-cluster --insecure
```

When prompted about creating a ServiceAccount with cluster-level privileges, answer `y`.

3. Verify the cluster was added:

```bash
argocd cluster list
```

Notes:

- If you use a non-existent context (e.g., `kubernetes` instead of `kubernetes-admin@kubernetes`), Argo CD will report: `context <name> does not exist in kubeconfig`.
- Ensure you are logged in to the Argo CD API server with `argocd login` before running the commands above.