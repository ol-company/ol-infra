# State bootstrap của account dev nằm trong bucket ở account shared → dùng profile admin của shared
bucket       = "__STATE_BUCKET__"
key          = "bootstrap/dev/terraform.tfstate"
region       = "ap-southeast-1"
encrypt      = true
use_lockfile = true
profile      = "ol-shared-admin"
