# ArgoCD-GitOps
GitOps Argocd repo 

# install argocd through kubectl command manifest

kubectl create namespace argocd

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# install argocd-cli 
VERSION=$(curl -L -s https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
curl -sSL -o argocd-linux-arm64 https://github.com/argoproj/argo-cd/releases/download/v$VERSION/argocd-linux-arm64
chmod +x argocd-linux-arm64
sudo mv argocd-linux-arm64 /usr/local/bin/argocd
argocd version
argocd version --client