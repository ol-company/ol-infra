# State bootstrap của account staging nằm trong bucket ở account shared → dùng profile admin của shared
bucket       = "__STATE_BUCKET__"
key          = "bootstrap/staging/terraform.tfstate"
region       = "ap-southeast-1"
encrypt      = true
use_lockfile = true
profile      = "ol-shared-admin"
