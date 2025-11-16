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

## Declarative Argo CD Application (GitOps)

This repository also contains a fully declarative Argo CD Application that points Argo CD to the manifests in this repo.

### Prerequisites

- Argo CD installed and accessible (see sections above)
- Cluster added to Argo CD via `argocd cluster add ...`
- Ingress controller (e.g., NGINX) and cert-manager installed if using Ingress/TLS
- DNS for your host pointing to the ingress controller (e.g., `<your-domain>`)

### Repository layout

```
declarative_node-pro/
  argo_deploy.yml        # Argo CD Application (declarative)
  frontend.yaml          # Frontend Deployment/Service/Ingress
  backend.yaml           # Backend Deployment/Service (update as needed)
```

### Apply the Argo CD Application

Apply the Application manifest to bootstrap syncing from this repo:

```bash
kubectl apply -n argocd -f declarative_node-pro/argo_deploy.yml
```

### What the Application does

- name: `3-tier-app`, namespace: `argocd`
- source:
  - repoURL: `https://github.com/rohitG7496/ArgoCD-GitOps.git`
  - targetRevision: `main`
  - path: `declarative_node-pro`
- destination:
  - server: `<in-cluster Kubernetes API>` (e.g., `https://kubernetes.default.svc`)
  - namespace: `db`
- syncPolicy:
  - automated: prune + selfHeal
  - syncOptions: `CreateNamespace=true` (Argo CD will create `db` if missing)

### Verify and sync

```bash
argocd app get 3-tier-app -n argocd
argocd app sync 3-tier-app -n argocd   # optional; automated sync is enabled
```

### Notes specific to the included manifests

- Frontend:
  - Deployment replicas: 2, nodeSelector: `node=app`
  - Service: ClusterIP `frontend-svc` on port 80
  - Ingress host: `<your-domain>`, TLS via `letsencrypt-prod` (requires cert-manager and issuer)
  - Image: `rohit7496/frontend:latest` — update tags as needed for your release process
- Backend: adjust images, ports, and resources as required in `backend.yaml`.
- If your nodes need labeling for scheduling:
  ```bash
  kubectl label node <node-name> node=app
  ```
- Ensure your DNS for `<your-domain>` points to the ingress controller and that the issuer `letsencrypt-prod` exists.

### Clean up

To remove the Argo CD Application and its managed resources (if prune applies):

```bash
argocd app delete 3-tier-app -n argocd
```

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.

## Attribution

Based on work by Aditya Jaiswal (DevOpsShack). Attribution retained per the MIT License.