# A clause that reads state this fixture never recorded — there is no world/ directory beside it.
# In a real fixture this is the mistake you make at 2am; here it is the assertion.
payload="$(gh pr view 99 --repo teststuffstash/demo --json headRefOid,reviewDecision)"
printf 'PAYLOAD %s\n' "$payload"
echo "REACHED: end"
