#!/usr/bin/env bash
# One-shot legacy AWS cleanup — deletes cruft classified with Rasmus (2026-06-05).
# DESTRUCTIVE. Run with your ADMIN SSO session (the read-only audit key can't do this):
#     aws sso login --profile rasmus
#     AWS_PROFILE=rasmus bash scripts/aws-cleanup-legacy.sh
# Prints the plan, then asks you to type 'delete' to proceed.
#
# DELETES:
#   S3 buckets    : dhx-adapter, dhx-adapter-teststuff, dhx-adapter-teststuff2  (old work; empty+remove)
#   Route53 zone  : local.  (Z1YU0W68W5C0SE — leftover, probably from old Fargate/containers)
#   Route53 record: _5cd120e50c8af0bd7c319d37ad82cebf.taranortaltest.net  (zone Z99ACHIHM30YC)
#   ACM (expired) : vis-csp.teststuff.net (eu-north-1), taranortaltest.net (eu-west-1)
# KEEPS (do NOT touch): eid-demo.com (on Cloudflare), allure-behavior-snippets-demo (S3, in use),
#   and ALL of teststuff.net — that zone is migrating to Cloudflare and gets decommissioned later.
set -euo pipefail

aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "Not authenticated to AWS. Log in first:" >&2
  echo "    aws sso login --profile rasmus" >&2
  echo "    AWS_PROFILE=rasmus bash $0" >&2
  exit 1; }
echo "Acting as: $(aws sts get-caller-identity --query Arn --output text)"
cat <<'PLAN'

Will DELETE:
  S3            : dhx-adapter, dhx-adapter-teststuff, dhx-adapter-teststuff2
  Route53 zone  : local. (Z1YU0W68W5C0SE)
  Route53 record: _5cd120e50c8af0bd7c319d37ad82cebf.taranortaltest.net
  ACM (expired) : vis-csp.teststuff.net (eu-north-1), taranortaltest.net (eu-west-1)
Will KEEP: eid-demo.com, allure-behavior-snippets-demo, all of teststuff.net.
PLAN
read -rp "Type 'delete' to proceed: " ans
[ "$ans" = "delete" ] || { echo "aborted"; exit 1; }

# ---------- S3 ----------
bucket_region() {
  local loc; loc=$(aws s3api get-bucket-location --bucket "$1" --query LocationConstraint --output text 2>/dev/null || echo None)
  [ "$loc" = "None" ] || [ -z "$loc" ] && echo us-east-1 || echo "$loc"
}
remove_bucket() {
  local b=$1
  aws s3api head-bucket --bucket "$b" 2>/dev/null || { echo "  bucket $b not found, skip"; return; }
  local r; r=$(bucket_region "$b")
  echo "emptying bucket $b ($r) ..."
  aws s3 rm "s3://$b" --recursive --only-show-errors --region "$r" || true
  while :; do                                  # purge versions + delete markers (if versioned)
    local j; j=$(aws s3api list-object-versions --bucket "$b" --region "$r" --max-items 500 \
      --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' \
      --output json 2>/dev/null || echo '{"Objects":[]}')
    [ "$(echo "$j" | jq '.Objects | length')" -eq 0 ] && break
    echo "$j" > /tmp/s3del.json
    aws s3api delete-objects --bucket "$b" --region "$r" --delete file:///tmp/s3del.json >/dev/null
  done
  aws s3api delete-bucket --bucket "$b" --region "$r"
  echo "  deleted bucket $b"
}
for b in dhx-adapter dhx-adapter-teststuff dhx-adapter-teststuff2; do remove_bucket "$b"; done

# ---------- Route53: delete a record set (fetch exact set, feed back as DELETE) ----------
del_record() {
  local zone=$1 name=$2
  local rrset; rrset=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" \
    --query "ResourceRecordSets[?Name=='$name']" --output json)
  if [ "$(echo "$rrset" | jq 'length')" -eq 0 ]; then echo "  record $name not found, skip"; return; fi
  echo "$rrset" | jq -c '.[]' | while read -r rs; do
    jq -n --argjson rs "$rs" '{Changes:[{Action:"DELETE",ResourceRecordSet:$rs}]}' > /tmp/rr.json
    aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch file:///tmp/rr.json >/dev/null
    echo "  deleted record $(echo "$rs" | jq -r '.Name+" "+.Type')"
  done
}

# delete the leftover `local.` hosted zone (strip any non-NS/SOA records first, then drop the zone)
LOCAL_ZONE=Z1YU0W68W5C0SE
if aws route53 get-hosted-zone --id "$LOCAL_ZONE" >/dev/null 2>&1; then
  aws route53 list-resource-record-sets --hosted-zone-id "$LOCAL_ZONE" \
    --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" --output json | jq -c '.[]' | while read -r rs; do
      jq -n --argjson rs "$rs" '{Changes:[{Action:"DELETE",ResourceRecordSet:$rs}]}' > /tmp/rr.json
      aws route53 change-resource-record-sets --hosted-zone-id "$LOCAL_ZONE" --change-batch file:///tmp/rr.json >/dev/null
    done
  aws route53 delete-hosted-zone --id "$LOCAL_ZONE" >/dev/null
  echo "deleted Route53 hosted zone local. ($LOCAL_ZONE)"
else
  echo "local. zone not found, skip"
fi

# delete the stale validation record in taranortaltest.net
del_record Z99ACHIHM30YC "_5cd120e50c8af0bd7c319d37ad82cebf.taranortaltest.net."

# ---------- ACM: delete expired certs by domain+region ----------
del_acm() {
  local domain=$1 region=$2
  local arn; arn=$(aws acm list-certificates --region "$region" \
    --query "CertificateSummaryList[?DomainName=='$domain'].CertificateArn | [0]" --output text)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    aws acm delete-certificate --region "$region" --certificate-arn "$arn"
    echo "deleted ACM cert $domain ($region)"
  else
    echo "ACM cert $domain not found in $region, skip"
  fi
}
del_acm vis-csp.teststuff.net eu-north-1
del_acm taranortaltest.net    eu-west-1

echo "Done."
