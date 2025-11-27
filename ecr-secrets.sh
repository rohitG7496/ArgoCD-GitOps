ECR_PASSWD=$(aws ecr get-login-password --region ap-south-1)

kubectl create secret docker-registry ecr-auth-updater \
    --docker-server=120496071282.dkr.ecr.ap-south-1.amazonaws.com \
    --docker-username=AWS \
    --docker-password="$ECR_PASSWD" \
    --namespace argocd-image-updater-system \
    --dry-run=client -o yaml | kubectl apply -f -