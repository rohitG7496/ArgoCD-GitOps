#!/bin/bash
# Ensure the namespace exists
kubectl create namespace db --dry-run=client -o yaml | kubectl apply -f -

# Create or update the secret
kubectl create secret docker-registry ecr-secret \
    --docker-server=120496071282.dkr.ecr.ap-south-1.amazonaws.com \
    --docker-username=AWS \
    --docker-password="$(aws ecr get-login-password --region ap-south-1)" \
    --namespace db \
    --dry-run=client -o yaml | kubectl apply -f -