[.outbounds[]? | select(.type == "block") | .tag] as $block_tags |
[.outbounds[]? | select(.type == "dns") | .tag] as $dns_tags |
if .route.rules? then
  .route.rules |= map(
    (.outbound? // "") as $outbound |
    if ($block_tags | index($outbound)) != null then
      del(.outbound) | .action = "reject"
    elif ($dns_tags | index($outbound)) != null then
      del(.outbound) | .action = "hijack-dns"
    else
      .
    end
  )
else
  .
end |
.outbounds |= map(select(.type != "block" and .type != "dns")) |
if (.outbounds | length) == 0 then del(.outbounds) else . end
