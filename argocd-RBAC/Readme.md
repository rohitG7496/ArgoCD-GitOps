# Argo CD Enterprise SSO Integration with GitHub & External Secrets Operator (ESO)

Implements Enterprise Single Sign-On (SSO) and Role-Based Access Control (RBAC) in Argo CD using its bundled **Dex** OIDC identity broker, **GitHub Organizations & Teams**, and **External Secrets Operator (ESO)** backed by **AWS Secrets Manager**.

---

## Architecture Overview

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

| Layer | Component | Responsibility |
|---|---|---|
| **AuthN** | GitHub via Dex | Delegates authentication to GitHub |
| **AuthZ** | `argocd-rbac-cm` | Evaluates team claims against `policy.csv` |
| **Secrets** | ESO + AWS Secrets Manager | Zero plaintext credentials stored in Git |

---

## Prerequisites

- Kubernetes cluster with Argo CD deployed in namespace `argocd`
- Domain with TLS configured (e.g., `https://<your-argocd-domain>`)
- External Secrets Operator installed with a functional `ClusterSecretStore` connected to AWS Secrets Manager (`<your-cluster-secret-store>`)
- A GitHub Organization (e.g., `<your-github-org>`)

---

## Step 1: Register GitHub OAuth Application

1. In GitHub, navigate to **Settings → Developer settings → OAuth Apps → New OAuth App**.
2. Configure the application:
   - **Application name:** `Argo CD`
   - **Homepage URL:** `https://<your-argocd-domain>`
   - **Authorization callback URL:** `https://<your-argocd-domain>/api/dex/callback` *(no trailing slash)*
3. Click **Register application**, note the **Client ID**, then generate and copy the **Client Secret** immediately.

---

## Step 2: Configure GitHub Organization & Teams

> Dex evaluates group membership based on GitHub Teams, not organization ownership.

1. Navigate to your GitHub Organization (`https://github.com/<your-github-org>`).
2. Go to **Teams → New team**, set name to `<team-name>`, visibility `Visible`.
3. Add your user account as a member of the team.
4. Go to **Organization Settings → Third-party application access policy** and ensure your Argo CD OAuth app is granted access.

---

## Step 3: Store OAuth Credentials in AWS Secrets Manager

Create or update the secret:

- **Secret Name:** `argocd/in/github-sso`
- **Type:** Key/Value (JSON)

```json
{
  "dex.github.clientID": "<your-client-id>",
  "dex.github.clientSecret": "<your-client-secret>"
}
```

---

## Step 4: Deploy ExternalSecret in Kubernetes

The manifest is already in this repo at [`argocd-RBAC/argocd-oauth-extsecret.yml`](argocd-oauth-extsecret.yml). Apply and label the synced secret:

```bash
kubectl apply -f argocd-RBAC/argocd-oauth-extsecret.yml

# Argo CD restricts Dex from reading secrets unless tagged with the tracking label
kubectl label secret argocd-oauth-secrets -n argocd \
  app.kubernetes.io/part-of=argocd --overwrite
```

**Verify sync:**

```bash
kubectl get externalsecret -n argocd argocd-github-oauth
# STATUS should be "SecretSynced" and READY "True"

kubectl get secret -n argocd argocd-oauth-secrets \
  -o jsonpath='{.data}' | jq
# Confirm dex.github.clientID and dex.github.clientSecret are present
```

---

## Step 5: Configure Dex Connector in argocd-cm

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

> The `$argocd-oauth-secrets:` prefix tells Dex to resolve the value from the Kubernetes secret named `argocd-oauth-secrets` — no plaintext credentials in the ConfigMap.

---

## Step 6: Configure RBAC Policy in argocd-rbac-cm

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

| Field | Value | Purpose |
|---|---|---|
| `scopes` | `[groups, email]` | Pulls team membership into the JWT claims |
| `policy.default` | `role:readonly` | Fallback for any authenticated user not in a mapped team |
| `policy.csv` | `g, org:team, role:admin` | Grants admin to members of the specified GitHub team |

---

## Step 7: Restart Pods & Verify Login Flow

```bash
kubectl rollout restart deployment argocd-server argocd-dex-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
kubectl rollout status deployment argocd-dex-server -n argocd
```

**Check Dex logs to confirm the connector loaded:**

```bash
kubectl logs -n argocd deploy/argocd-dex-server --tail=50
# Look for:
# "config connector","connector_id":"github"
# "listening on","server":"https","address":"0.0.0.0:5556"
```

**Web UI Verification:**

1. Open an incognito window and navigate to `https://<your-argocd-domain>`.
2. Click **LOG IN VIA GITHUB** and authorize the application.
3. Click the **User Info** icon (bottom-left) and confirm:
   - **Username:** your GitHub username/email
   - **Groups:** `<your-github-org>:<team-name>`
4. Confirm admin access by syncing or inspecting applications.

---

## Key Concepts Summary

| Concept | Detail |
|---|---|
| **Dex** | Bundled OIDC broker in Argo CD; acts as the middleman between Argo CD and GitHub |
| **GitHub OAuth App** | Registered per-org; callback URL must end with `/api/dex/callback` |
| **ESO ExternalSecret** | Syncs credentials from AWS Secrets Manager into a Kubernetes Secret |
| **`part-of=argocd` label** | Required for Dex to be allowed to read the synced secret |
| **`policy.csv` group format** | Always `<org>:<team>` — colon-separated, case-sensitive |
| **`policy.default`** | Safety net; set to `role:readonly` to avoid open access |
