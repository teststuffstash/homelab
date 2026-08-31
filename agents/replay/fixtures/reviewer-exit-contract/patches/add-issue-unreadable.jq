# add-issue-unreadable — overlay a standing-aside comment from our identity with
# pre=issue-unreadable, posted at the content head (homelab#1055). The exit-contract
# assert_review_terminal function recognizes any standing-aside comment from our
# identity at this head as a terminal (TERMINAL 2). The marker head= field matches
# the newest non-merge commit's oid (abc1234d), and pre=issue-unreadable is the new
# precondition slug for an unreadable linked issue.
.comments = [{author: {login: "homelab-reviewer"}, body: "STANDING ASIDE: issue-unreadable at abc1234d — no verdict; the level-triggered review path re-dispatches when this settles. <!-- standing-aside head=abc1234d pre=issue-unreadable -->"}]