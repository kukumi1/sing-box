((.inbounds? // []) | length == 0) and
((.outbounds? // []) | length > 0) and
all(.outbounds[]?; .type == "direct" or .type == "block" or .type == "dns")
