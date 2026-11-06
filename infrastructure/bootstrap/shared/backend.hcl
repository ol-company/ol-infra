# State của chính bootstrap/shared, nằm trong bucket do nó tạo (chuyển lên sau lần apply đầu — docs/06 mục 6.4)
bucket       = "__STATE_BUCKET__"
key          = "bootstrap/shared/terraform.tfstate"
region       = "ap-southeast-1"
encrypt      = true
use_lockfile = true
profile      = "ol-shared-admin"
