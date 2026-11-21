#!/usr/bin/env bash
# One-time bootstrap: installs External Secrets Operator and Argo CD, then
# registers the preview AppProject and ApplicationSet. After this, the cluster
# pulls preview state from GitHub; CI never talks to the Kubernetes API.
set -euo pipefail

: "${GITHUB_OWNER:?Set GITHUB_OWNER}"
: "${GITHUB_REPO:?Set GITHUB_REPO}"
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN (read-only: Pull requests + Contents)}"
: "${PREVIEW_DOMAIN:?Set PREVIEW_DOMAIN}"
: "${ACM_CERTIFICATE_ARN:?Set ACM_CERTIFICATE_ARN from Terraform output}"
: "${WEB_ECR_URL:?Set WEB_ECR_URL from Terraform output}"
: "${API_ECR_URL:?Set API_ECR_URL from Terraform output}"
export DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.11.6}"   # Argo CD v3.5.6
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.14.0}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
substitute='${GITHUB_OWNER} ${GITHUB_REPO} ${DEFAULT_BRANCH} ${PREVIEW_DOMAIN} ${ACM_CERTIFICATE_ARN} ${WEB_ECR_URL} ${API_ECR_URL}'
export GITHUB_OWNER GITHUB_REPO PREVIEW_DOMAIN ACM_CERTIFICATE_ARN WEB_ECR_URL API_ECR_URL

helm repo add external-secrets https://charts.external-secrets.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update external-secrets argo

# Generates each preview's database password inside the cluster.
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$ESO_CHART_VERSION" --namespace external-secrets --create-namespace \
  --wait --timeout 10m

helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" --namespace argocd --create-namespace \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --wait --timeout 10m

# Token used by the Pull Request generator and to clone a private repository.
kubectl -n argocd create secret generic github-token \
  --from-literal=token="$GITHUB_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd create secret generic preview-repo \
  --from-literal=type=git \
  --from-literal=url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" \
  --from-literal=username=git \
  --from-literal=password="$GITHUB_TOKEN" --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f -

for manifest in project.yaml previews-applicationset.yaml; do
  envsubst "$substitute" < "$repo_root/gitops/argocd/$manifest" | kubectl apply -f -
done

echo "Argo CD is watching ${GITHUB_OWNER}/${GITHUB_REPO} for PRs labelled 'preview'."
echo "UI: kubectl -n argocd port-forward svc/argocd-server 8443:443"
echo "Admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
