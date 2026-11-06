# Backend S3 cho state của môi trường staging. Bucket nằm ở account shared (tạo ở bootstrap/shared).
bucket       = "__STATE_BUCKET__"
key          = "envs/staging/terraform.tfstate"
region       = "ap-southeast-1"
encrypt      = true
use_lockfile = true # Khóa state bằng file .tflock trong S3 (Terraform >= 1.10), không cần DynamoDB
