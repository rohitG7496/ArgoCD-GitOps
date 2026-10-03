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

---

## Argo CD Enterprise SSO Integration with GitHub & External Secrets Operator (ESO)

Implements Enterprise Single Sign-On (SSO) and Role-Based Access Control (RBAC) in Argo CD using its bundled **Dex** OIDC identity broker, **GitHub Organizations & Teams**, and **External Secrets Operator (ESO)** backed by **AWS Secrets Manager**.

### Architecture Overview

```
[User Browser]
       │
       ▼ (1. Click "Log in via GitHub")
[Argo CD API Server] ──► [Dex Server (Port 5556)] ──► [GitHub OAuth]
                                                            │
                                             (2. User authorizes & validates org/team)
                                                            ▼
[Argo CD API Server] ◄── [Issues OIDC JWT] ◄── [Translates claims to groups]
       │
       ▼ (3. Evaluates groups against policy.csv)
[argocd-rbac-cm Engine] ──► [Grants role:admin or role:readonly]
```

- **Authentication (AuthN):** Delegated to GitHub via Dex.
- **Authorization (AuthZ):** Evaluated locally in Argo CD using team claims mapped in `argocd-rbac-cm`.
- **Secret Management:** Zero plaintext credentials stored in Git. ESO syncs OAuth Client ID and Secret dynamically from AWS Secrets Manager.

### Prerequisites

- Kubernetes cluster with Argo CD deployed in namespace `argocd`
- Domain with TLS configured (e.g., `https://<your-argocd-domain>`)
- External Secrets Operator installed with a functional `ClusterSecretStore` connected to AWS Secrets Manager (`<your-cluster-secret-store>`)
- A GitHub Organization (e.g., `<your-github-org>`)

### Step 1: Register GitHub OAuth Application

1. In GitHub, navigate to **Settings → Developer settings → OAuth Apps → New OAuth App**.
2. Configure the application:
   - **Application name:** `Argo CD`
   - **Homepage URL:** `https://<your-argocd-domain>`
   - **Authorization callback URL:** `https://<your-argocd-domain>/api/dex/callback` *(no trailing slash)*
3. Click **Register application**, note the **Client ID**, then generate and copy the **Client Secret** immediately.

### Step 2: Configure GitHub Organization & Teams

Dex evaluates group membership based on GitHub Teams, not organization ownership.

1. Navigate to your GitHub Organization (`https://github.com/<your-github-org>`).
2. Go to **Teams → New team**, set name to `<team-name>`, visibility `Visible`.
3. Add your user account as a member of the team.
4. Go to **Organization Settings → Third-party application access policy** and ensure your Argo CD OAuth app is granted access.

### Step 3: Store OAuth Credentials in AWS Secrets Manager

Create or update the secret:

- **Secret Name:** `argocd/in/github-sso`
- **Type:** Key/Value (JSON)

```json
{
  "dex.github.clientID": "<your-client-id>",
  "dex.github.clientSecret": "<your-client-secret>"
}
```

### Step 4: Deploy ExternalSecret in Kubernetes

The manifest is already in this repo at [`argocd-RBAC/argocd-oauth-extsecret.yml`](argocd-RBAC/argocd-oauth-extsecret.yml). Apply and label the synced secret:

```bash
kubectl apply -f argocd-RBAC/argocd-oauth-extsecret.yml

# Argo CD restricts Dex from reading secrets unless tagged with the tracking label
kubectl label secret argocd-oauth-secrets -n argocd \
  app.kubernetes.io/part-of=argocd --overwrite
```

Verify sync:

```bash
kubectl get externalsecret -n argocd argocd-github-oauth
# STATUS should be "SecretSynced" and READY "True"

kubectl get secret -n argocd argocd-oauth-secrets \
  -o jsonpath='{.data}' | jq
# Confirm dex.github.clientID and dex.github.clientSecret are present
```

### Step 5: Configure Dex Connector in argocd-cm

```bash
kubectl edit configmap argocd-cm -n argocd
```

Add under `data:`:

```yaml
data:
  url: https://<your-argocd-domain>
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $argocd-oauth-secrets:dex.github.clientID
          clientSecret: $argocd-oauth-secrets:dex.github.clientSecret
          orgs:
            - name: <your-github-org>
              teams:
                - <team-name>
```

### Step 6: Configure RBAC Policy in argocd-rbac-cm

```bash
kubectl edit configmap argocd-rbac-cm -n argocd
```

Set `data:` to:

```yaml
data:
  scopes: '[groups, email]'
  policy.default: role:readonly
  policy.csv: |
    # Map GitHub team '<team-name>' under org '<your-github-org>' to Argo CD admin
    g, <your-github-org>:<team-name>, role:admin
```

### Step 7: Restart Pods & Verify Login Flow

```bash
kubectl rollout restart deployment argocd-server argocd-dex-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
kubectl rollout status deployment argocd-dex-server -n argocd
```

Check Dex logs to confirm the connector loaded:

```bash
kubectl logs -n argocd deploy/argocd-dex-server --tail=50
# Look for:
# "config connector","connector_id":"github"
# "listening on","server":"https","address":"0.0.0.0:5556"
```

**Web UI Verification:**

1. Open an incognito window and navigate to `https://<your-argocd-domain>`.
2. Click **LOG IN VIA GITHUB** and authorize the application.
3. Click the **User Info** icon (bottom-left):
   - **Username:** your GitHub username/email
   - **Groups:** `<your-github-org>:<team-name>`
4. Confirm admin access by syncing or inspecting applications.

---
