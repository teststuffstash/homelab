# Exercise the production call site (coordinator-scan.sh line 792): iterate over
# stacks_json and call fanout_graduated_stack for each graduated stack.
for name in $(stacks_json | jq -r '.stacks[].name'); do