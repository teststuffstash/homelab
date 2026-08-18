# add-aside — overlay a standing-aside comment from our identity whose machine marker's head=
# field is the newest non-merge commit's sha8 (`abc1234d`). The aside assert matches the marker's
# `head=<sha8>` substring; pre= may vary. This is the machine-marker shape STEP-0 posts (ADR-103
# channel-separation precedent — the fixture pins on the marker, never on prose).
.comments = [{author: {login: "homelab-reviewer"}, body: "STANDING ASIDE: checks-pending at abc1234d — no verdict; the level-triggered review path re-dispatches when this settles. <!-- standing-aside head=abc1234d pre=checks-pending -->"}]
