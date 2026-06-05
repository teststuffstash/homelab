#!/usr/bin/env bash
# One-shot legacy AWS cleanup — deletes cruft classified with Rasmus (2026-06-05). Idempotent
# (safe to re-run; already-deleted items are skipped). DESTRUCTIVE — needs your admin SSO session:
#     aws sso login --profile rasmus
#     AWS_PROFILE=rasmus bash scripts/aws-cleanup-legacy.sh --yes
#
# DELETES:
#   S3 buckets    : dhx-adapter, dhx-adapter-teststuff, dhx-adapter-teststuff2  (empty+remove)
#   Route53 record: _5cd120e50c8af0bd7c319d37ad82cebf.taranortaltest.net  (zone Z99ACHIHM30YC)
#   ACM (expired) : vis-csp.teststuff.net (eu-north-1), taranortaltest.net (eu-west-1)
#   Cloud Map     : namespace `local.` (ns-cc2np6o4m32ivit4, eu-west-1) — it owns Route53 zone
#                   Z1YU0W68W5C0SE, which gets deleted with it. (NOT a plain Route53 zone.)
# KEEPS: eid-demo.com, allure-behavior-snippets-demo, all of teststuff.net (migrating to CF).
set -euo pipefail

[ "${1:-}" = "--yes" ] || { echo "DESTRUCTIVE. Re-run with --yes:  AWS_PROFILE=rasmus bash $0 --yes"; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "Not authenticated. Run: aws sso login --profile rasmus" >&2; exit 1; }
echo "Acting as: $(aws sts get-caller-identity --query Arn --output text)"

# ---------- S3 ----------
bucket_region() {
  local loc; loc=$(aws s3api get-bucket-location --bucket "$1" --query LocationConstraint --output text 2>/dev/null || echo None)
  { [ "$loc" = "None" ] || [ -z "$loc" ]; } && echo us-east-1 || echo "$loc"
}
remove_bucket() {
  local b=$1
  aws s3api head-bucket --bucket "$b" 2>/dev/null || { echo "S3 $b: gone, skip"; return; }
  local r; r=$(bucket_region "$b"); echo "S3 $b ($r): emptying + removing ..."
  aws s3 rm "s3://$b" --recursive --only-show-errors --region "$r" || true
  while :; do
    local j; j=$(aws s3api list-object-versions --bucket "$b" --region "$r" --max-items 500 \
      --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' \
      --output json 2>/dev/null || echo '{"Objects":[]}')
    [ "$(echo "$j" | jq '.Objects | length')" -eq 0 ] && break
    echo "$j" > /tmp/s3del.json
    aws s3api delete-objects --bucket "$b" --region "$r" --delete file:///tmp/s3del.json >/dev/null
  done
  aws s3api delete-bucket --bucket "$b" --region "$r"; echo "  deleted bucket $b"
}
for b in dhx-adapter dhx-adapter-teststuff dhx-adapter-teststuff2; do remove_bucket "$b"; done

# ---------- Route53 record in taranortaltest.net ----------
del_record() {
  local zone=$1 name=$2
  local rrset; rrset=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" \
    --query "ResourceRecordSets[?Name=='$name']" --output json)
  if [ "$(echo "$rrset" | jq 'length')" -eq 0 ]; then echo "R53 $name: gone, skip"; return; fi
  echo "$rrset" | jq -c '.[]' | while read -r rs; do
    jq -n --argjson rs "$rs" '{Changes:[{Action:"DELETE",ResourceRecordSet:$rs}]}' > /tmp/rr.json
    aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch file:///tmp/rr.json >/dev/null
    echo "R53 deleted $(echo "$rs" | jq -r '.Name+" "+.Type')"
  done
}
del_record Z99ACHIHM30YC "_5cd120e50c8af0bd7c319d37ad82cebf.taranortaltest.net."

# ---------- ACM expired certs ----------
del_acm() {
  local domain=$1 region=$2 arn
  arn=$(aws acm list-certificates --region "$region" \
    --query "CertificateSummaryList[?DomainName=='$domain'].CertificateArn | [0]" --output text)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    aws acm delete-certificate --region "$region" --certificate-arn "$arn"; echo "ACM deleted $domain ($region)"
  else echo "ACM $domain ($region): gone, skip"; fi
}
del_acm vis-csp.teststuff.net eu-north-1
del_acm taranortaltest.net    eu-west-1

# ---------- Cloud Map namespace `local.` (owns the Route53 zone; delete via Cloud Map) ----------
delete_cloudmap_namespace() {
  local ns=$1 region=$2
  aws servicediscovery get-namespace --id "$ns" --region "$region" >/dev/null 2>&1 || { echo "CloudMap $ns: gone, skip"; return; }
  echo "CloudMap $ns: deleting (clearing services first) ..."
  for sid in $(aws servicediscovery list-services --region "$region" \
        --filters "Name=NAMESPACE_ID,Values=$ns,Condition=EQ" --query 'Services[].Id' --output text); do
    for iid in $(aws servicediscovery list-instances --service-id "$sid" --region "$region" --query 'Instances[].Id' --output text 2>/dev/null || true); do
      aws servicediscovery deregister-instance --service-id "$sid" --instance-id "$iid" --region "$region" >/dev/null 2>&1 || true
    done
    for _ in 1 2 3 4 5; do
      aws servicediscovery delete-service --id "$sid" --region "$region" >/dev/null 2>&1 && { echo "  deleted service $sid"; break; }; sleep 5
    done
  done
  for _ in 1 2 3 4 5 6; do
    aws servicediscovery delete-namespace --id "$ns" --region "$region" >/dev/null 2>&1 && { echo "  deleted namespace $ns (+ its Route53 zone)"; return; }; sleep 5
  done
  echo "  namespace $ns still draining — re-run this script shortly to finish it" >&2
}
delete_cloudmap_namespace ns-cc2np6o4m32ivit4 eu-west-1

echo "Done."
