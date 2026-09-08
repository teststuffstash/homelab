# theme-complete — goal #29 is THEMED (`Base: master`, machine block) and carries an open level-2
# theme container #310 (`theme:` title, label-inert). Its two children (#311/#312) are CLOSED and
# live only in the row's issue-list.json (kidsall) — closed issues are not in `openall`.
map(if .number == 29 then .body = "---\nBase: master\n---\n" + .body else . end)
+ [
  { "number": 310, "title": "theme: coordinator belts", "labels": [], "body": "", "parent": { "number": 29 } }
]
