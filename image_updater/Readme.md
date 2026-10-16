# ArgoCD Image Updater Setup

This directory contains the configuration for **ArgoCD Image Updater v1.3.0** (CRD-based), which automatically detects new container images in AWS ECR and updates the ArgoCD Applications.

---

## Directory Structure

```
argocd/image-updater/
├── img-updater.yml           # ConfigMap + ImageUpdater CR combined
├── ecr-external-secret.yml   # ESO ExternalSecret — pulls SSH key from AWS Secrets Manager
└── README.md                 # This file
```

---

## Architecture

```
ECR (new image pushed e.g. frontend-v1.0.1)
        ↓
Image Updater polls ECR every 2 mins
EC2 Instance Profile provides AWS credentials via IMDS (169.254.169.254)
        ↓
Detects newer tag matching regexp pattern
        ↓
Updates ArgoCD Application object directly (argocd write-back method)
        ↓
ArgoCD syncs → new pod rolls out on kubeadm cluster
```

---

## Prerequisites

### 1. EC2 Instance Profile (IAM Role)

The kubeadm nodes must have an IAM Instance Profile attached with ECR read permissions.

**IAM Role:** `kubadm`
**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

**Required ECR Permissions** (via `ecr-push-policy`):
- `ecr:GetAuthorizationToken`
- `ecr:BatchGetImage`
- `ecr:GetDownloadUrlForLayer`
- `ecr:DescribeImages`
- `ecr:ListImages`

### 2. IMDS Hop Limit

Pods inside Kubernetes need hop limit set to **2** to reach the instance metadata service. Run this from your local machine for both nodes:

```bash
# Master node
aws ec2 modify-instance-metadata-options \
  --region ap-south-1 \
  --instance-id i-0678c382317d4ac23 \
  --http-put-response-hop-limit 2 \
  --http-endpoint enabled

# Worker node
aws ec2 modify-instance-metadata-options \
  --region ap-south-1 \
  --instance-id i-0ba42b40477dd798d \
  --http-put-response-hop-limit 2 \
  --http-endpoint enabled
```

**Why hop limit 2?**
- Default is 1 — only the EC2 instance itself can reach IMDS
- Kubernetes pods go through an extra network layer (pod → node → IMDS) = 2 hops
- Without this, pods get `Unable to locate credentials`

### 3. ECR Credential Script

Image Updater uses a shell script mounted from a Kubernetes Secret to get an ECR token:

```bash
kubectl create secret generic ecr-creds-script \
  --from-literal=ecr-creds.sh='#!/bin/sh
printf "AWS:$(aws ecr get-login-password --region ap-south-1)"' \
  -n argocd
```

This script is mounted at `/app/ecr-creds.sh` with `defaultMode: 493` (0755 executable).

### 4. SSH Key for Git Write-back

> **Note:** Git write-back requires Kustomize source type. For plain Directory apps, `argocd` write-back method is used instead (no SSH key needed).

If using git write-back, generate a deploy key and store in AWS Secrets Manager:

```bash
# Generate key
ssh-keygen -t ed25519 -C "argocd-image-updater" -f argocd-image-updater-key -N ""

# Add public key to GitHub repo → Settings → Deploy Keys (with write access)

# Store private key in AWS Secrets Manager under trade/in/prod
aws secretsmanager update-secret \
  --secret-id trade/in/prod \
  --region ap-south-1 \
  --secret-string "$(aws secretsmanager get-secret-value \
    --secret-id trade/in/prod --query SecretString --output text | \
    jq --rawfile key argocd-image-updater-key '.sshPrivateKey = $key')"
```

### 5. External Secrets Operator

ESO must be installed and `tradein-aws-store` ClusterSecretStore must exist. The `ecr-external-secret.yml` creates the `argocd-image-updater-ssh-key` secret from AWS Secrets Manager.

---

## Installation Steps

Run these in order on your kubeadm master node:

```bash
# Step 1 — Apply ESO ExternalSecret (creates argocd-image-updater-ssh-key)
kubectl apply -f argocd/image-updater/ecr-external-secret.yml
kubectl get secret argocd-image-updater-ssh-key -n argocd

# Step 2 — Install Image Updater (skip if already installed)
# Note: stable manifest URL may change — check https://github.com/argoproj-labs/argocd-image-updater
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

# Step 3 — Create ECR credential script secret
kubectl create secret generic ecr-creds-script \
  --from-literal=ecr-creds.sh='#!/bin/sh
printf "AWS:$(aws ecr get-login-password --region ap-south-1)"' \
  -n argocd

# Step 4 — Patch Deployment: mount SSH key volume with correct secret name
kubectl patch deployment argocd-image-updater-controller -n argocd --type=json \
  -p='[{"op": "replace", "path": "/spec/template/spec/volumes/0/secret/secretName",
        "value": "argocd-image-updater-ssh-key"}]'

# Step 5 — Patch Deployment: mount ECR script with executable permissions (493 = 0755)
kubectl patch deployment argocd-image-updater-controller -n argocd --type=strategic --patch '
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "argocd-image-updater-controller",
          "volumeMounts": [{
            "name": "ecr-script",
            "mountPath": "/app/ecr-creds.sh",
            "subPath": "ecr-creds.sh",
            "readOnly": true
          }]
        }],
        "volumes": [{
          "name": "ecr-script",
          "secret": {
            "secretName": "ecr-creds-script",
            "defaultMode": 493
          }
        }]
      }
    }
  }
}'

# Step 6 — Apply ConfigMap and ImageUpdater CR
kubectl apply -f argocd/image-updater/img-updater.yml

# Step 7 — Restart to pick up all changes
kubectl rollout restart deployment argocd-image-updater-controller -n argocd

# Step 8 — Verify
kubectl get pods -n argocd | grep image-updater
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater -f
```

---

## Configuration Reference

### img-updater.yml

| Resource | Purpose |
|---|---|
| `ConfigMap` | Sets polling interval (2m), log level, ECR registry URL |
| `ImageUpdater CR` | Defines which apps and images to watch, write-back method |

### Key CR Fields

```yaml
spec:
  commonUpdateSettings:
    updateStrategy: newest-build   # Picks newest tag matching allowTags
  writeBackConfig:
    method: argocd                 # Direct in-cluster update (no git commit)
  applicationRefs:
    - namePattern: tradein-frontend
      images:
        - alias: frontend
          imageName: <ecr-repo>:frontend-latest
          commonUpdateSettings:
            allowTags: "regexp:^frontend-"  # Only track frontend-* tags
```

### Tag Naming Convention

| Component | Latest tag | Versioned tag |
|---|---|---|
| Frontend | `frontend-latest` | `frontend-v1.0.0` |
| Backend | `backend-latest` | `backend-v1.0.0` |

The pipeline pushes **both tags** on every build. Image Updater tracks versioned tags and ignores `latest`.

---

## Troubleshooting

### `no basic auth credentials`
ECR auth not working. Verify instance profile is attached and test from inside the pod:
```bash
kubectl exec -n argocd \
  $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-image-updater \
    -o jsonpath='{.items[0].metadata.name}') \
  -- aws ecr get-login-password --region ap-south-1
```

### `skipping app of type Directory`
Image Updater v1.3.0 does not support plain Directory apps. Add `kustomization.yaml` to your app directory so ArgoCD detects it as Kustomize type.

### `could not find kustomization`
The `writeBackTarget` path is wrong. For git write-back, ensure the path points to the directory containing `kustomization.yaml`.

### `invalid script output, must be single line with syntax <username>:<password>`
The ECR script is not outputting `AWS:<token>` format. Recreate the secret:
```bash
kubectl delete secret ecr-creds-script -n argocd
kubectl create secret generic ecr-creds-script \
  --from-literal=ecr-creds.sh='#!/bin/sh
printf "AWS:$(aws ecr get-login-password --region ap-south-1)"' \
  -n argocd
kubectl rollout restart deployment argocd-image-updater-controller -n argocd
```

### `MountVolume.SetUp failed: secret not found`
The deployment patch is referencing the wrong secret name. Check:
```bash
kubectl get secrets -n argocd | grep -E "ecr|ssh|image-updater"
kubectl get deployment argocd-image-updater-controller -n argocd \
  -o jsonpath='{.spec.template.spec.volumes[*].name}'
```

---

## Verify End-to-End

After setup, push a new image and watch Image Updater detect and apply it:

```bash
# Watch logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater -f

# Expected success log:
# level=info msg="Setting new image to ...tradein:frontend-v1.0.1"
# level=info msg="Successfully updated image ...frontend-latest to ...frontend-v1.0.1"

# Check ArgoCD app sync status
argocd app get tradein-frontend --grpc-web
argocd app get tradein-backend --grpc-web

# Verify running pod image
kubectl get pods -n tradein -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```
