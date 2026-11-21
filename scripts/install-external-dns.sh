#!/usr/bin/env bash
set -euo pipefail

: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${ROUTE53_ZONE_NAME:?Set ROUTE53_ZONE_NAME (e.g. example.com)}"
: "${ROUTE53_ZONE_ID:?Set ROUTE53_ZONE_ID}"
: "${EXTERNAL_DNS_ROLE_ARN:?Set EXTERNAL_DNS_ROLE_ARN from Terraform output}"

values_file="$(mktemp)"
trap 'rm -f "$values_file"' EXIT
cat > "$values_file" <<YAML
provider:
  name: aws
sources:
  - ingress
domainFilters:
  - ${ROUTE53_ZONE_NAME}
annotationFilter: preview-demo.example.com/managed=true
policy: sync
registry: txt
txtOwnerId: ${CLUSTER_NAME}-branch-preview
txtPrefix: external-dns-
serviceAccount:
  create: true
  name: external-dns
  annotations:
    eks.amazonaws.com/role-arn: ${EXTERNAL_DNS_ROLE_ARN}
env:
  - name: AWS_DEFAULT_REGION
    value: ${AWS_REGION}
extraArgs:
  - --zone-id-filter=/hostedzone/${ROUTE53_ZONE_ID}
  - --aws-zone-type=public
YAML

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update external-dns
helm upgrade --install external-dns external-dns/external-dns \
  --version 1.23.0 --namespace external-dns --create-namespace \
  --values "$values_file" --wait --timeout 5m

