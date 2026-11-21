#!/usr/bin/env bash
# Destroys everything this demo created, in dependency order:
#
#   1. Preview environments (ApplicationSet -> Applications -> namespaces), so
#      the Load Balancer Controller deletes the ALB and ExternalDNS deletes the
#      Route 53 records while both are still running.
#   2. Argo CD, External Secrets Operator and ExternalDNS.
#   3. Leftover AWS objects created from inside the cluster: the preview
#      IngressGroup's ALB, target groups and security groups, and detached EBS
#      volumes of preview-* PVCs (only those tagged for this cluster).
#   4. ECR images, then `terraform destroy` in infra/terraform.
#   5. `terraform destroy` in infra/cluster (skipped if you brought your own
#      cluster, or with --keep-cluster).
#
# Usage: scripts/nuke.sh [--yes] [--keep-cluster]
#
# The cluster name and region come from infra/cluster's Terraform outputs, or
# from CLUSTER_NAME and AWS_REGION. Set PREVIEW_DOMAIN and ROUTE53_ZONE_ID to
# also check that no preview DNS records are left behind.
#
# Written for macOS's bash 3.2 as well as Linux.
set -euo pipefail

assume_yes=false
keep_cluster=false
for arg in "$@"; do
  case "$arg" in
    --yes) assume_yes=true ;;
    --keep-cluster) keep_cluster=true ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

for tool in aws terraform kubectl helm jq; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_tf="$repo_root/infra/cluster"
app_tf="$repo_root/infra/terraform"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }

tf_output() { # dir name -> value or empty
  terraform -chdir="$1" output -raw "$2" 2>/dev/null || true
}
has_state() { # dir -> true if Terraform state has resources
  terraform -chdir="$1" init -input=false >/dev/null 2>&1 || true
  [[ -n "$(terraform -chdir="$1" state list 2>/dev/null | head -1)" ]]
}

# --- Work out what exists ---------------------------------------------------
cluster_stack=false
app_stack=false
has_state "$cluster_tf" && cluster_stack=true
has_state "$app_tf" && app_stack=true

CLUSTER_NAME="${CLUSTER_NAME:-$(tf_output "$cluster_tf" cluster_name)}"
AWS_REGION="${AWS_REGION:-$(tf_output "$cluster_tf" aws_region)}"
: "${CLUSTER_NAME:?Could not read cluster_name from infra/cluster; set CLUSTER_NAME}"
: "${AWS_REGION:?Could not read aws_region from infra/cluster; set AWS_REGION}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
# ALB IngressGroup used by every preview (helm/preview/values.yaml).
ALB_GROUP="${ALB_GROUP:-branch-preview-demo}"

account="$(aws sts get-caller-identity --query Account --output text)"

destroy_cluster=false
if [[ "$cluster_stack" == true && "$keep_cluster" == false ]]; then
  destroy_cluster=true
fi

cat <<EOF

This will permanently delete, in AWS account $account ($AWS_REGION):
  - every preview environment, its database and its DNS record
  - Argo CD, External Secrets Operator and ExternalDNS on cluster '$CLUSTER_NAME'
  - leftover load balancer resources of the '$ALB_GROUP' IngressGroup and
    detached EBS volumes of preview-* PVCs, tagged for cluster '$CLUSTER_NAME'
EOF
[[ "$app_stack" == true ]] && echo "  - all images in the preview ECR repositories, then infra/terraform (ECR, ACM, IAM roles)"
if [[ "$destroy_cluster" == true ]]; then
  echo "  - infra/cluster: the EKS cluster, its nodes, the VPC and the NAT gateway"
else
  echo "  (the EKS cluster itself is kept)"
fi
echo

if [[ "$assume_yes" != true ]]; then
  read -r -p "Type the cluster name ($CLUSTER_NAME) to continue: " answer
  [[ "$answer" == "$CLUSTER_NAME" ]] || { echo "Aborted."; exit 1; }
fi

# --- 1. Preview environments --------------------------------------------------
cluster_reachable=false
if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 \
   && aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null \
   && kubectl get --raw /readyz >/dev/null 2>&1; then
  cluster_reachable=true
else
  warn "Cluster '$CLUSTER_NAME' is not reachable; skipping in-cluster cleanup."
fi

wait_until_empty() { # description timeout_seconds command...
  local what="$1" timeout="$2"; shift 2
  local waited=0
  while [[ -n "$("$@" 2>/dev/null || true)" ]]; do
    if (( waited >= timeout )); then return 1; fi
    sleep 10; waited=$((waited + 10))
    echo "  waiting for $what (${waited}s)"
  done
}

preview_apps()       { kubectl -n argocd get applications -l preview-demo.example.com/pr -o name; }
preview_namespaces() { kubectl get namespaces -l preview-demo.example.com/managed=true -o name; }
alb_ingresses() {
  kubectl get ingress -A -o json \
    | jq -r '.items[] | select(.spec.ingressClassName == "alb") | "\(.metadata.namespace)/\(.metadata.name)"'
}

if [[ "$cluster_reachable" == true ]]; then
  log "Deleting preview environments"
  if kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1; then
    # Deleting the ApplicationSet deletes its Applications; their finalizers
    # delete each preview's resources, including its namespace.
    kubectl -n argocd delete applicationset branch-previews --ignore-not-found --wait=false
    if ! wait_until_empty "Argo CD to delete preview Applications" 900 preview_apps; then
      warn "Applications still present; removing their finalizers and deleting namespaces directly."
      for app in $(preview_apps); do
        kubectl -n argocd patch "$app" --type merge -p '{"metadata":{"finalizers":null}}' || true
      done
    fi
  fi
  for ns in $(preview_namespaces); do
    kubectl delete "$ns" --wait=false || true
  done
  wait_until_empty "preview namespaces to terminate" 900 preview_namespaces \
    || warn "Some preview namespaces are still terminating: $(preview_namespaces | tr '\n' ' ')"

  log "Waiting for the Load Balancer Controller to remove ALB Ingresses"
  wait_until_empty "ALB Ingresses to be deleted" 600 alb_ingresses \
    || warn "ALB Ingresses remain: $(alb_ingresses | tr '\n' ' '). Step 3 deletes their AWS resources."

  # ExternalDNS deletes records on its next sync (default interval 1 minute).
  if [[ -n "${PREVIEW_DOMAIN:-}" && -n "${ROUTE53_ZONE_ID:-}" ]]; then
    preview_records() {
      aws route53 list-resource-record-sets --hosted-zone-id "$ROUTE53_ZONE_ID" --output json \
        | jq -r --arg d ".${PREVIEW_DOMAIN}." \
            '.ResourceRecordSets[] | select(.Name | endswith($d)) | select(.Name | test("(^|[.-])pr-[0-9]+[.]")) | "\(.Type) \(.Name)"'
    }
    wait_until_empty "ExternalDNS to remove preview DNS records" 300 preview_records \
      || warn "Route 53 records remain (delete them by hand): $(preview_records | tr '\n' ';')"
  else
    echo "  Giving ExternalDNS 90 seconds to remove DNS records (set PREVIEW_DOMAIN and ROUTE53_ZONE_ID to verify)."
    sleep 90
  fi

  # --- 2. Cluster add-ons -------------------------------------------------------
  log "Uninstalling Argo CD, External Secrets Operator and ExternalDNS"
  for release in "argocd argocd" "external-secrets external-secrets" "external-dns external-dns"; do
    set -- $release
    if helm status "$1" -n "$2" >/dev/null 2>&1; then
      helm uninstall "$1" -n "$2" --wait --timeout 5m || warn "helm uninstall $1 failed"
    fi
    kubectl delete namespace "$2" --ignore-not-found --wait=true --timeout=5m || warn "namespace $2 did not terminate"
  done

  retained_pvs="$(kubectl get pv -o json | jq -r '.items[] | select(.spec.claimRef.namespace // "" | startswith("preview-")) | .metadata.name')"
  if [[ -n "$retained_pvs" ]]; then
    warn "Released PersistentVolumes remain (Retain policy?): $retained_pvs. Deleting them."
    for pv in $retained_pvs; do kubectl delete pv "$pv" --wait=false || true; done
  fi
fi

# --- 3. Leftover AWS objects created from inside the cluster -----------------
log "Checking for leftover load balancer resources of IngressGroup $ALB_GROUP"
# Only the preview IngressGroup's resources: a bring-your-own cluster may run
# other ALBs that must survive.
tagged_arns() { # resource-type
  aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" "Key=ingress.k8s.aws/stack,Values=$ALB_GROUP" \
    --resource-type-filters "$1" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'
}

for lb in $(tagged_arns elasticloadbalancing:loadbalancer); do
  if aws elbv2 describe-load-balancers --load-balancer-arns "$lb" >/dev/null 2>&1; then
    echo "  deleting load balancer $lb"
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb"
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$lb" || true
  fi
done
for tg in $(tagged_arns elasticloadbalancing:targetgroup); do
  if aws elbv2 describe-target-groups --target-group-arns "$tg" >/dev/null 2>&1; then
    echo "  deleting target group $tg"
    aws elbv2 delete-target-group --target-group-arn "$tg" || warn "could not delete $tg"
  fi
done
# Security groups the controller created for ALBs. Their network interfaces can
# take a few minutes to go away after the ALB is deleted, so retry.
for sg_arn in $(tagged_arns ec2:security-group); do
  sg="${sg_arn##*/}"
  aws ec2 describe-security-groups --group-ids "$sg" >/dev/null 2>&1 || continue
  echo "  deleting security group $sg"
  deleted=false
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if aws ec2 delete-security-group --group-id "$sg" 2>/dev/null; then deleted=true; break; fi
    sleep 15
  done
  [[ "$deleted" == true ]] || warn "could not delete security group $sg (still in use?)"
done

log "Checking for detached EBS volumes from preview PVCs"
# Detached volumes whose PVC lived in a preview-* namespace AND that are tagged
# for this cluster. Untagged look-alikes are only reported.
pvc_filter="Name=tag:kubernetes.io/created-for/pvc/namespace,Values=preview-*"
volumes="$( {
  aws ec2 describe-volumes --filters "$pvc_filter" "Name=status,Values=available" \
    "Name=tag:KubernetesCluster,Values=$CLUSTER_NAME" --query 'Volumes[].VolumeId' --output text
  aws ec2 describe-volumes --filters "$pvc_filter" "Name=status,Values=available" \
    "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" --query 'Volumes[].VolumeId' --output text
} | tr '\t' '\n' | sed '/^$/d' | sort -u)"
for vol in $volumes; do
  echo "  deleting volume $vol"
  aws ec2 delete-volume --volume-id "$vol" || warn "could not delete volume $vol"
done
untagged="$(aws ec2 describe-volumes --filters "$pvc_filter" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text | tr '\t' '\n' | sed '/^$/d' | sort -u \
  | comm -23 - <(printf '%s\n' $volumes | sed '/^$/d' | sort -u))"
[[ -z "$untagged" ]] || warn "Detached preview-* volumes without a cluster tag (check, then delete by hand): $(echo $untagged)"

# --- 4. ECR images and infra/terraform -----------------------------------------
if [[ "$app_stack" == true ]]; then
  log "Emptying ECR repositories"
  for output in web_ecr_url api_ecr_url; do
    url="$(tf_output "$app_tf" "$output")"
    [[ -n "$url" ]] || continue
    repo="${url##*/}"
    aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 || continue
    while :; do
      ids="$(aws ecr list-images --repository-name "$repo" --max-items 100 --query 'imageIds' --output json)"
      [[ "$(jq 'length' <<< "$ids")" -gt 0 ]] || break
      echo "  deleting $(jq 'length' <<< "$ids") image(s) from $repo"
      aws ecr batch-delete-image --repository-name "$repo" --image-ids "$ids" >/dev/null
    done
  done

  log "terraform destroy: infra/terraform"
  terraform -chdir="$app_tf" destroy -auto-approve
else
  echo "infra/terraform has no state; skipping."
fi

# --- 5. infra/cluster ------------------------------------------------------------
if [[ "$destroy_cluster" == true ]]; then
  log "terraform destroy: infra/cluster (about 15 minutes)"
  terraform -chdir="$cluster_tf" destroy -auto-approve
elif [[ "$cluster_stack" == true ]]; then
  echo "Keeping the cluster (--keep-cluster)."
else
  echo "infra/cluster has no state (bring-your-own cluster); leaving the cluster alone."
fi

log "Done"
cat <<EOF
Not removed by this script (GitHub side):
  - the 'preview' label and preview-<N> deployment environments in the repository
  - the Actions variables and the fine-grained token used by Argo CD (revoke it)
EOF
